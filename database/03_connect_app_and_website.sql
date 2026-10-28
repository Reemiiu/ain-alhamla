-- =====================================================================
-- عين الحملة — ملف ربط قاعدة البيانات بالتطبيق والموقع (يُشغَّل مرة واحدة)
-- Supabase → SQL Editor → New query → الصقي المحتوى كاملاً → Run
-- آمن لإعادة التشغيل (idempotent).
-- =====================================================================
-- المشكلة التي يحلها: كل الجداول مفعّل عليها RLS بدون أي سياسات، لذلك
-- المفتاح العام (publishable) يرى 0 صفوف، ودالتا verify_login و
-- create_pilgrim غير موجودتين في القاعدة، وكلمات مرور seed وهمية.
-- ⚠️ هذه صلاحيات مستوى "عرض تجريبي/مشروع تخرج": المشروع لا يستخدم Supabase
-- Auth، فالسياسات مفتوحة لدور anon. للإنتاج: Supabase Auth + سياسات حسب الدور.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ---------------------------------------------------------------------
-- 1) دالة تسجيل الدخول (التطبيق + لوحة التحكم)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.verify_login(p_national_id TEXT, p_password TEXT)
RETURNS TABLE (id BIGINT, full_name VARCHAR, national_id VARCHAR, phone VARCHAR,
               role user_role, is_active BOOLEAN)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
BEGIN
    RETURN QUERY
    SELECT u.id, u.full_name, u.national_id, u.phone, u.role, u.is_active
    FROM users u
    WHERE u.national_id = p_national_id
      AND u.is_active = TRUE
      AND u.password_hash = crypt(p_password, u.password_hash);
END;
$$;
REVOKE ALL ON FUNCTION public.verify_login(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.verify_login(TEXT, TEXT) TO anon, authenticated;

-- ---------------------------------------------------------------------
-- 2) دالة إضافة حاج (زر "إضافة حاج" في لوحة التحكم)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_pilgrim(
    p_full_name VARCHAR, p_national_id VARCHAR, p_phone VARCHAR, p_password TEXT,
    p_campaign_id BIGINT, p_group_id BIGINT DEFAULT NULL, p_passport_no VARCHAR DEFAULT NULL,
    p_blood_type VARCHAR DEFAULT NULL, p_medical_notes TEXT DEFAULT NULL)
RETURNS TABLE (pilgrim_id BIGINT, user_id BIGINT)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE v_user_id BIGINT; v_pilgrim_id BIGINT;
BEGIN
    INSERT INTO users (full_name, national_id, phone, password_hash, role, is_active)
    VALUES (p_full_name, p_national_id, p_phone, crypt(p_password, gen_salt('bf')), 'PILGRIM', TRUE)
    RETURNING id INTO v_user_id;
    INSERT INTO pilgrims (user_id, campaign_id, group_id, passport_no, blood_type, medical_notes)
    VALUES (v_user_id, p_campaign_id, p_group_id, p_passport_no, p_blood_type, p_medical_notes)
    RETURNING id INTO v_pilgrim_id;
    RETURN QUERY SELECT v_pilgrim_id, v_user_id;
EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'رقم الهوية مُسجَّل مسبقاً لمستخدم آخر';
END;
$$;
REVOKE ALL ON FUNCTION public.create_pilgrim(VARCHAR,VARCHAR,VARCHAR,TEXT,BIGINT,BIGINT,VARCHAR,VARCHAR,TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.create_pilgrim(VARCHAR,VARCHAR,VARCHAR,TEXT,BIGINT,BIGINT,VARCHAR,VARCHAR,TEXT) TO anon, authenticated;

-- ---------------------------------------------------------------------
-- 3) كلمة مرور تجريبية لحسابات seed فقط (الهاشات الوهمية dummyhash)
--    كلمة المرور لكل الحسابات التجريبية: Demo@1234
-- ---------------------------------------------------------------------
UPDATE users SET password_hash = crypt('Demo@1234', gen_salt('bf'))
WHERE password_hash LIKE '$2b$12$dummyhash%';

-- ---------------------------------------------------------------------
-- 4) حماية جدول users: لا يُقرأ عمود password_hash أبداً من الخارج
-- ---------------------------------------------------------------------
REVOKE ALL ON TABLE users FROM anon, authenticated;
GRANT SELECT (id, full_name, national_id, phone, role, is_active, created_at)
    ON TABLE users TO anon, authenticated;

-- ---------------------------------------------------------------------
-- 5) سياسات RLS (قراءة للكل + الكتابة التي يحتاجها التطبيق/الموقع فقط)
-- ---------------------------------------------------------------------
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['users','campaigns','supervisors','groups','pilgrims','locations',
                           'attendance','trips','trip_groups','alerts','sos_requests',
                           'emergency_contacts','notifications'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS app_read ON public.%I', t);
    EXECUTE format('CREATE POLICY app_read ON public.%I FOR SELECT TO anon, authenticated USING (true)', t);
  END LOOP;
END $$;

-- إضافة (التطبيق: تسجيل حضور، SOS، تنبيه، جهة طوارئ)
DROP POLICY IF EXISTS app_insert ON attendance;
CREATE POLICY app_insert ON attendance FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS app_insert ON alerts;
CREATE POLICY app_insert ON alerts FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS app_insert ON sos_requests;
CREATE POLICY app_insert ON sos_requests FOR INSERT TO anon, authenticated WITH CHECK (true);
DROP POLICY IF EXISTS app_insert ON emergency_contacts;
CREATE POLICY app_insert ON emergency_contacts FOR INSERT TO anon, authenticated WITH CHECK (true);

-- تعديل (لوحة التحكم: معالجة حالات SOS وإغلاق التنبيهات)
DROP POLICY IF EXISTS app_update ON sos_requests;
CREATE POLICY app_update ON sos_requests FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);
DROP POLICY IF EXISTS app_update ON alerts;
CREATE POLICY app_update ON alerts FOR UPDATE TO anon, authenticated USING (true) WITH CHECK (true);

-- حذف (التطبيق: حذف جهة طوارئ)
DROP POLICY IF EXISTS app_delete ON emergency_contacts;
CREATE POLICY app_delete ON emergency_contacts FOR DELETE TO anon, authenticated USING (true);

-- ---------------------------------------------------------------------
-- 6) تحقق سريع — يجب أن تظهر 13 جدولاً ولكل جدول سياسة واحدة على الأقل
-- ---------------------------------------------------------------------
SELECT tablename, count(*) AS policies
FROM pg_policies WHERE schemaname = 'public'
GROUP BY tablename ORDER BY tablename;
