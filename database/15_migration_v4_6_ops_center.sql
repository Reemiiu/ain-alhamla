-- =====================================================================
-- عين الحملة — v4.6: فصل صلاحيات مركز العمليات عن الإدارة
-- يُشغَّل بعد 14_migration_v4_5_circles.sql. آمن لإعادة التشغيل. لا يضيف جداول.
-- Supabase → SQL Editor → الصقي الملف كاملاً → Run.
-- =====================================================================
-- مركز العمليات (OPERATIONS_CENTER) صار له واجهة خاصة في لوحة التحكم: المتابعة اللحظية
-- والاستجابة للطوارئ على مستوى الحملة كلها (لوحة العمليات، التنبيهات، الخريطة، المتابعة الذكية،
-- حدود المشاعر، الصحة، ملفات الحجاج، الرسائل الجماعية، المفقودات).
-- وما يخص الإدارة والمشرفين فقط يُمنع عنه من الخادم نفسه، وليس من الواجهة فقط:
--   • التعليقات وردود التقييم          app_add_comment
--   • روابط الأهل                      app_family_links
--   • رسائل المشرف المترجمة            app_send_voice · app_voice_list · app_voice_status
--   • تغيير حالة رحلات الحافلات        app_set_trip_status
-- الطريقة: نقرأ تعريف كل دالة من القاعدة نفسها ونحذف 'OPERATIONS_CENTER' من قائمة الأدوار في _auth،
-- فلا يتغيّر أي شيء آخر في الدالة.
-- =====================================================================
DO $$
DECLARE f RECORD; v_def TEXT; v_new TEXT; v_n INT := 0;
BEGIN
  FOR f IN SELECT p.oid, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public'
              AND p.proname IN ('app_add_comment', 'app_family_links', 'app_send_voice', 'app_voice_list',
                                'app_voice_status', 'app_set_trip_status') LOOP
    v_def := pg_get_functiondef(f.oid);
    v_new := replace(v_def, ',''OPERATIONS_CENTER'']::user_role[]', ']::user_role[]');
    IF v_new <> v_def THEN
      EXECUTE v_new;
      v_n := v_n + 1;
    END IF;
  END LOOP;
  RAISE NOTICE 'عدد الدوال التي حُدّثت: %', v_n;
END $$;

-- تحقق: يجب ألا تظهر أي دالة من الست في هذه القائمة
SELECT p.proname AS still_open_to_ops_center
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
 WHERE n.nspname = 'public'
   AND p.proname IN ('app_add_comment', 'app_family_links', 'app_send_voice', 'app_voice_list', 'app_voice_status', 'app_set_trip_status')
   AND p.prosrc LIKE '%''OPERATIONS_CENTER''%';
