-- =====================================================================
-- دالة تسجيل الدخول الآمنة لتطبيق عين الحملة
-- شغّلي هذا الملف مرة واحدة على قاعدة بياناتك في Supabase
-- (SQL Editor → New query → الصق المحتوى → Run)
-- =====================================================================
--
-- جدول users الحالي يخزّن كلمة المرور في عمود password_hash كنص، وهذا
-- الحقل يجب ألا يُقارَن أبداً من داخل تطبيق الجوال مباشرة (يتطلب ذلك جلب
-- الهاش وإرساله للجهاز، وهذا غير آمن). الحل: دالة PostgreSQL تعمل داخل
-- الخادم فقط، تستخدم pgcrypto للتحقق من كلمة المرور وتُعيد بيانات
-- المستخدم عند التطابق، دون كشف الهاش خارج القاعدة أبداً.
--
-- ملاحظة: إذا كانت القيم الحالية في password_hash نصاً عادياً (كما في
-- seed.sql التجريبي)، حدّثيها أولاً إلى هاش حقيقي، مثال:
--   UPDATE users SET password_hash = crypt('كلمة_المرور', gen_salt('bf'));

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE OR REPLACE FUNCTION verify_login(p_national_id TEXT, p_password TEXT)
RETURNS TABLE (
    id BIGINT,
    full_name VARCHAR,
    national_id VARCHAR,
    phone VARCHAR,
    role user_role,
    is_active BOOLEAN
) AS $$
BEGIN
    RETURN QUERY
    SELECT u.id, u.full_name, u.national_id, u.phone, u.role, u.is_active
    FROM users u
    WHERE u.national_id = p_national_id
      AND u.is_active = TRUE
      AND u.password_hash = crypt(p_password, u.password_hash);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- تسمح فقط بالتنفيذ عبر الدالة نفسها (لا قراءة مباشرة لجدول users بكلمات المرور)
REVOKE ALL ON FUNCTION verify_login(TEXT, TEXT) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION verify_login(TEXT, TEXT) TO anon, authenticated;
