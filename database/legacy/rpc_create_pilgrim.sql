-- =====================================================================
-- دالة إضافة حاج جديد (تُستخدم من زر "إضافة حاج" في لوحة تحكم المشرف)
-- شغّلي هذا الملف مرة واحدة على نفس قاعدة بياناتك في Supabase، بعد
-- تنفيذ supabase/rpc_verify_login.sql الخاص بتطبيق الجوال (يعتمد عليه
-- في تفعيل امتداد pgcrypto).
-- (SQL Editor → New query → الصق المحتوى → Run)
-- =====================================================================
--
-- لماذا دالة RPC بدل إدراج مباشر في جدولي users وpilgrims من الموقع؟
-- 1) إنشاء حاج يتطلب إنشاء صفّين مترابطين (users ثم pilgrims) بشكل ذرّي.
-- 2) كلمة المرور يجب أن تُشفَّر بـ crypt()/pgcrypto قبل التخزين، ولا يصح
--    إرسال هاش جاهز من المتصفح ولا تخزينها كنص عادي.
-- 3) تمنع الدالة أي طرف من التحكم بحقول حسّاسة مثل role أو password_hash
--    مباشرة عبر REST API.
--
-- ⚠️ ملاحظة أمنية: هذه الدالة قابلة للاستدعاء بواسطة أي طرف يملك مفتاح
-- anon العام (وهو مفتاح مخصَّص للنشر العام أصلاً)، لأن المشروع الحالي لا
-- يستخدم نظام Supabase Auth ولا صفوف RLS مرتبطة بجلسة مصادقة حقيقية —
-- التحقق من تسجيل الدخول في هذا المشروع يجري داخل المتصفح فقط (انظر
-- dashboard/js/session.js). لنشر إنتاجي حقيقي، يُنصح بربط الدالة بنظام
-- Supabase Auth وبسياسات RLS تتحقق من دور المستخدم المتصل فعلياً قبل
-- تنفيذ أي إدراج.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION create_pilgrim(
    p_full_name     VARCHAR,
    p_national_id   VARCHAR,
    p_phone         VARCHAR,
    p_password      TEXT,
    p_campaign_id   BIGINT,
    p_group_id      BIGINT DEFAULT NULL,
    p_passport_no   VARCHAR DEFAULT NULL,
    p_blood_type    VARCHAR DEFAULT NULL,
    p_medical_notes TEXT DEFAULT NULL
)
RETURNS TABLE (pilgrim_id BIGINT, user_id BIGINT) AS $$
DECLARE
    v_user_id    BIGINT;
    v_pilgrim_id BIGINT;
BEGIN
    INSERT INTO users (full_name, national_id, phone, password_hash, role, is_active)
    VALUES (p_full_name, p_national_id, p_phone, crypt(p_password, gen_salt('bf')), 'PILGRIM', TRUE)
    RETURNING id INTO v_user_id;

    INSERT INTO pilgrims (user_id, campaign_id, group_id, passport_no, blood_type, medical_notes)
    VALUES (v_user_id, p_campaign_id, p_group_id, p_passport_no, p_blood_type, p_medical_notes)
    RETURNING id INTO v_pilgrim_id;

    RETURN QUERY SELECT v_pilgrim_id, v_user_id;
EXCEPTION
    WHEN unique_violation THEN
        RAISE EXCEPTION 'رقم الهوية مُسجَّل مسبقاً لمستخدم آخر';
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

REVOKE ALL ON FUNCTION create_pilgrim(VARCHAR, VARCHAR, VARCHAR, TEXT, BIGINT, BIGINT, VARCHAR, VARCHAR, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION create_pilgrim(VARCHAR, VARCHAR, VARCHAR, TEXT, BIGINT, BIGINT, VARCHAR, VARCHAR, TEXT) TO anon, authenticated;
