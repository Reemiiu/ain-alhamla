-- =====================================================================
-- عين الحملة — 06: الخريطة بدون إنترنت + تصحيح التسلسل الزمني للمناسك
-- Supabase → SQL Editor → New query → الصقي المحتوى كاملاً → Run
-- يُشغَّل بعد 04_migration_v2.sql و 05_seed_v2.sql. آمن لإعادة التشغيل.
-- لا يضيف جداول جديدة (يبقى المجموع 21 جدولاً).
-- =====================================================================
-- ما يضيفه:
--  1) الدالة app_map_data: كل ما تحتاجه خريطة التطبيق في طلب واحد
--     (المواقع والنطاقات، التجمعات، آخر موقع للمشرف، مركز المجموعة، ومواقع الحجاج للمشرف).
--     التطبيق يحفظ نتيجتها على الجوال، فتعمل الخريطة والسهم والمسافة بدون إنترنت.
--  2) تصحيح أوقات المناسك والتجمعات في البيانات التجريبية لتطابق ترتيب الحج الفعلي
--     بالساعة (ملاحظة المشرفة: تثقيف المجموعات المرتبطة بالنسك).
-- =====================================================================

-- =====================================================================
-- 1) بيانات الخريطة (للحفظ على الجوال)
-- =====================================================================
CREATE OR REPLACE FUNCTION app_map_data(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_groups BIGINT[]; v_campaigns BIGINT[]; v_staff BOOLEAN; v_sup BIGINT;
BEGIN
  u := _auth(p_token);
  v_groups := _visible_groups(u);
  v_staff := u.role <> 'PILGRIM';
  IF NOT v_staff THEN
    SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
    v_sup := _group_supervisor_user(p.group_id);
  END IF;
  SELECT coalesce(array_agg(DISTINCT campaign_id), '{}') INTO v_campaigns FROM groups WHERE id = ANY (v_groups);
  IF p.campaign_id IS NOT NULL AND NOT p.campaign_id = ANY (v_campaigns) THEN
    v_campaigns := array_append(v_campaigns, p.campaign_id);
  END IF;

  RETURN json_build_object(
    'generated_at', now(),
    'role', u.role,

    -- نقاط التجمع والنطاقات الآمنة للحملة
    'locations', (SELECT coalesce(json_agg(json_build_object('id', l.id, 'name', l.name, 'type', l.type,
                    'lat', l.latitude, 'lng', l.longitude, 'radius_m', l.radius_meters) ORDER BY l.id), '[]'::json)
                    FROM locations l WHERE l.campaign_id = ANY (v_campaigns)),

    -- التجمعات المفتوحة والقادمة (مع إحداثيات مكانها) — تكفي لحساب السهم والمسافة على الجوال
    'gatherings', (SELECT coalesce(json_agg(json_build_object('id', gt.id, 'title', gt.title, 'group_id', gt.group_id,
                    'scheduled_at', gt.scheduled_at, 'deadline_minutes', gt.deadline_minutes, 'status', gt.status,
                    'location_id', l.id, 'location', l.name, 'lat', l.latitude, 'lng', l.longitude, 'radius_m', l.radius_meters,
                    'checked_in', CASE WHEN p.id IS NULL THEN NULL ELSE
                                    (SELECT a.status FROM attendance a WHERE a.gathering_id = gt.id AND a.pilgrim_id = p.id) END)
                    ORDER BY gt.scheduled_at), '[]'::json)
                    FROM gatherings gt JOIN locations l ON l.id = gt.location_id
                   WHERE gt.group_id = ANY (v_groups) AND gt.status <> 'CLOSED'
                     AND gt.scheduled_at > now() - interval '12 hours' AND gt.scheduled_at < now() + interval '3 days'),

    -- آخر موقع معروف للمشرف (الحاج: مشرف مجموعته فقط / الإدارة: كل المشرفين / المشرف: نفسه)
    'supervisors', (SELECT coalesce(json_agg(json_build_object('user_id', us.id, 'name', us.full_name, 'phone', us.phone,
                    'lat', lp.latitude, 'lng', lp.longitude, 'at', lp.client_recorded_at)), '[]'::json)
                    FROM supervisors s JOIN users us ON us.id = s.user_id
                    JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = us.id
                                   AND l.client_recorded_at > now() - interval '12 hours'
                                   ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
                   WHERE (NOT v_staff AND us.id = v_sup)
                      OR (u.role IN ('ADMIN', 'OPERATIONS_CENTER'))
                      OR (u.role = 'SUPERVISOR' AND us.id = u.id)),

    -- للحاج: «مركز المجموعة» = متوسط مواقع أفراد مجموعته خلال آخر ساعة (بدون كشف موقع كل فرد)
    'group_center', CASE WHEN v_staff OR p.group_id IS NULL THEN NULL ELSE (
                    SELECT CASE WHEN count(*) = 0 THEN NULL ELSE json_build_object(
                             'lat', round(avg(lp.latitude), 6), 'lng', round(avg(lp.longitude), 6),
                             'members', count(*), 'at', max(lp.client_recorded_at)) END
                      FROM pilgrims pp
                      JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = pp.user_id
                                     AND l.client_recorded_at > now() - interval '60 minutes'
                                     ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
                     WHERE pp.group_id = p.group_id AND pp.user_id <> u.id) END,

    -- للمشرف والإدارة: آخر موقع لكل حاج في المجموعات المسموحة مع حالته
    'pilgrims', CASE WHEN NOT v_staff THEN '[]'::json ELSE (
                  SELECT coalesce(json_agg(json_build_object('pilgrim_id', pp.id, 'name', us.full_name, 'phone', us.phone,
                    'group_id', pp.group_id, 'group', g.name, 'priority', pp.priority_level,
                    'lat', lp.latitude, 'lng', lp.longitude, 'at', lp.client_recorded_at, 'battery', lp.battery_pct,
                    'status', (SELECT a.status FROM attendance a WHERE a.pilgrim_id = pp.id ORDER BY a.checkpoint_time DESC LIMIT 1),
                    'open_alert', (SELECT a.type FROM alerts a WHERE a.pilgrim_id = pp.id AND a.status <> 'RESOLVED'
                                    ORDER BY a.created_at DESC LIMIT 1))), '[]'::json)
                    FROM pilgrims pp JOIN users us ON us.id = pp.user_id LEFT JOIN groups g ON g.id = pp.group_id
                    JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = pp.user_id
                                   ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
                   WHERE pp.group_id = ANY (v_groups)) END
  );
END $$;

REVOKE ALL ON FUNCTION app_map_data(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_map_data(UUID) TO anon, authenticated;


-- =====================================================================
-- 2) تصحيح التسلسل الزمني للمناسك في البيانات التجريبية
-- ---------------------------------------------------------------------
-- البيانات التجريبية السابقة كانت تضع أوقات المناسك نسبةً إلى لحظة التشغيل
-- (مثلاً الوقوف بعرفة يبدأ 11 مساءً)، وأماكن التجمع كانت في الوجهة لا في نقطة الانطلاق.
-- هنا تُثبَّت على الترتيب الشرعي بتوقيت مكة، مع بقاء «الآن» = يوم النحر:
--   8  ذو الحجة  التروية: الانطلاق من السكن إلى منى ضحىً، والمبيت بها
--   9  ذو الحجة  التصعيد إلى عرفة بعد الشروق، والوقوف من الزوال حتى الغروب
--   ليلة 10     النفرة إلى مزدلفة بعد الغروب، والمبيت بها حتى الفجر
--   10 ذو الحجة  رمي جمرة العقبة ثم الحلق، ثم طواف الإفاضة والسعي
--   11 و12      رمي الجمرات الثلاث بعد الزوال والمبيت بمنى (المتعجّل يخرج قبل غروب 12)
--   ثم طواف الوداع قبل مغادرة مكة
-- يُطبَّق مرة واحدة فقط على الحملة التجريبية (رقم 1).
-- =====================================================================
DO $$
DECLARE
  d10 DATE;          -- تاريخ يوم النحر (اليوم بتوقيت مكة)
  v_lr TIMESTAMP;    -- الوقت المحلي الآن
  v_accom BIGINT;    -- سكن الحملة في العزيزية
  v_new TIMESTAMPTZ; v_delta INTERVAL; v_loc BIGINT; rec RECORD;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM rituals WHERE campaign_id = 1 AND id = 2 AND name LIKE 'الوقوف بعرفة%') THEN
    RAISE NOTICE 'لا توجد بيانات تجريبية للمناسك — تم تخطي التصحيح';
    RETURN;
  END IF;
  IF EXISTS (SELECT 1 FROM rituals WHERE campaign_id = 1 AND name LIKE 'رمي الجمرات الثلاث%') THEN
    RAISE NOTICE 'التسلسل الزمني للمناسك مُصحَّح مسبقاً';
    RETURN;
  END IF;

  v_lr := now() AT TIME ZONE 'Asia/Riyadh';
  d10 := v_lr::date - CASE WHEN v_lr::time < time '06:30' THEN 1 ELSE 0 END;

  -- موقع جديد: سكن الحملة (نقطة الانطلاق يوم التروية)
  SELECT id INTO v_accom FROM locations WHERE campaign_id = 1 AND name = 'سكن الحملة — العزيزية';
  IF v_accom IS NULL THEN
    INSERT INTO locations (campaign_id, name, type, latitude, longitude, radius_meters)
    VALUES (1, 'سكن الحملة — العزيزية', 'CHECKPOINT', 21.404000, 39.862000, 150)
    RETURNING id INTO v_accom;
  END IF;

  -- المناسك: الأسماء والأوقات وترتيب العرض (seq مؤقت لتفادي تعارض القيد الفريد)
  UPDATE rituals SET seq = seq + 100 WHERE campaign_id = 1;
  UPDATE rituals SET name = 'يوم التروية — الانطلاق إلى منى والمبيت بها', hajj_day = 8, seq = 1, location_id = 2,
         starts_at = ((d10 - 2) + time '06:30') AT TIME ZONE 'Asia/Riyadh',
         ends_at   = ((d10 - 1) + time '06:00') AT TIME ZONE 'Asia/Riyadh', status = 'COMPLETED' WHERE id = 1;
  UPDATE rituals SET name = 'الوقوف بعرفة (من الزوال حتى الغروب)', hajj_day = 9, seq = 2, location_id = 3,
         starts_at = ((d10 - 1) + time '06:00') AT TIME ZONE 'Asia/Riyadh',
         ends_at   = ((d10 - 1) + time '18:00') AT TIME ZONE 'Asia/Riyadh', status = 'COMPLETED' WHERE id = 2;
  UPDATE rituals SET name = 'النفرة إلى مزدلفة والمبيت بها حتى الفجر', hajj_day = 10, seq = 3, location_id = 4,
         starts_at = ((d10 - 1) + time '18:00') AT TIME ZONE 'Asia/Riyadh',
         ends_at   = (d10 + time '06:00') AT TIME ZONE 'Asia/Riyadh', status = 'COMPLETED' WHERE id = 3;
  UPDATE rituals SET name = 'رمي جمرة العقبة ثم الحلق أو التقصير', hajj_day = 10, seq = 4, location_id = 6,
         starts_at = (d10 + time '06:00') AT TIME ZONE 'Asia/Riyadh',
         ends_at   = ((d10 + 1) + time '04:30') AT TIME ZONE 'Asia/Riyadh', status = 'IN_PROGRESS' WHERE id = 4;
  UPDATE rituals SET name = 'طواف الإفاضة والسعي', hajj_day = 10, seq = 5, location_id = 1,
         starts_at = (d10 + time '20:00') AT TIME ZONE 'Asia/Riyadh',
         ends_at   = ((d10 + 1) + time '04:30') AT TIME ZONE 'Asia/Riyadh',
         status = (CASE WHEN v_lr::time >= time '20:00' OR v_lr::time < time '04:30' THEN 'IN_PROGRESS' ELSE 'UPCOMING' END)::ritual_status
   WHERE id = 5;
  UPDATE rituals SET name = 'طواف الوداع', hajj_day = 12, seq = 8, location_id = 1,
         starts_at = ((d10 + 2) + time '19:00') AT TIME ZONE 'Asia/Riyadh',
         ends_at   = ((d10 + 3) + time '01:00') AT TIME ZONE 'Asia/Riyadh', status = 'UPCOMING' WHERE id = 6;
  INSERT INTO rituals (campaign_id, name, hajj_day, seq, location_id, starts_at, ends_at, status) VALUES
   (1, 'رمي الجمرات الثلاث بعد الزوال والمبيت بمنى', 11, 6, 6,
       ((d10 + 1) + time '12:30') AT TIME ZONE 'Asia/Riyadh', ((d10 + 2) + time '04:30') AT TIME ZONE 'Asia/Riyadh', 'UPCOMING'),
   (1, 'رمي الجمرات الثلاث ثم النفر الأول قبل الغروب', 12, 7, 6,
       ((d10 + 2) + time '12:30') AT TIME ZONE 'Asia/Riyadh', ((d10 + 2) + time '17:30') AT TIME ZONE 'Asia/Riyadh', 'UPCOMING');
  -- أي مناسك أخرى أضافتها المستخدمة تُعاد لترتيبها بعد التسلسل الأساسي
  UPDATE rituals SET seq = seq - 100 + 8 WHERE campaign_id = 1 AND seq > 100;

  -- التجمعات: المكان = نقطة الانطلاق، والوقت حسب المنسك. تُزاح الأحداث المرتبطة بنفس الفرق.
  FOR rec IN
    SELECT * FROM (VALUES
      (5, 'التجمع في السكن للانطلاق إلى منى',      v_accom, (d10 - 2) + time '07:00'),
      (6, 'التجمع في السكن للانطلاق إلى منى',      v_accom, (d10 - 2) + time '07:00'),
      (1, 'التجمع في مخيم منى للتصعيد إلى عرفة',   5::BIGINT, (d10 - 1) + time '06:30'),
      (2, 'التجمع في مخيم منى للتصعيد إلى عرفة',   5::BIGINT, (d10 - 1) + time '06:30'),
      (7, 'التجمع في عرفات للنفرة إلى مزدلفة بعد الغروب', 3::BIGINT, (d10 - 1) + time '18:10'),
      (8, 'التجمع في عرفات للنفرة إلى مزدلفة بعد الغروب', 3::BIGINT, (d10 - 1) + time '18:10')
    ) AS t(gid, title, loc, local_at)
  LOOP
    v_new := rec.local_at AT TIME ZONE 'Asia/Riyadh';
    SELECT v_new - scheduled_at INTO v_delta FROM gatherings WHERE id = rec.gid AND campaign_id = 1;
    CONTINUE WHEN v_delta IS NULL;
    UPDATE gatherings SET title = rec.title, location_id = rec.loc, scheduled_at = v_new,
           created_at = created_at + v_delta, closed_at = closed_at + v_delta WHERE id = rec.gid;
    UPDATE attendance SET checkpoint_time = checkpoint_time + v_delta, location_id = rec.loc,
           client_recorded_at = client_recorded_at + v_delta WHERE gathering_id = rec.gid;
    UPDATE alerts SET created_at = created_at + v_delta, resolved_at = resolved_at + v_delta, location_id = rec.loc
     WHERE gathering_id = rec.gid;
    UPDATE activity_log SET created_at = created_at + v_delta
     WHERE (entity = 'gathering' AND entity_id = rec.gid)
        OR (rec.gid IN (1, 2) AND action IN ('MANUAL_ATTENDANCE', 'RESOLVE_ALERT') AND group_id = (SELECT group_id FROM gatherings WHERE id = rec.gid)
            AND created_at < now() - interval '20 hours');
  END LOOP;

  -- حافلات المشاعر: منى ← عرفات صباح التاسع، عرفات ← مزدلفة بعد الغروب
  UPDATE trips SET departure_time = ((d10 - 1) + time '06:45') AT TIME ZONE 'Asia/Riyadh',
                   arrival_time   = ((d10 - 1) + time '08:15') AT TIME ZONE 'Asia/Riyadh', status = 'COMPLETED'
   WHERE vehicle_no = 'BUS-101';
  UPDATE trips SET departure_time = ((d10 - 1) + time '18:30') AT TIME ZONE 'Asia/Riyadh',
                   arrival_time   = ((d10 - 1) + time '21:00') AT TIME ZONE 'Asia/Riyadh', status = 'COMPLETED'
   WHERE vehicle_no = 'BUS-102';
  UPDATE gatherings SET trip_id = (SELECT id FROM trips WHERE vehicle_no = 'BUS-101' LIMIT 1) WHERE id IN (1, 2) AND trip_id IS NULL;
  UPDATE gatherings SET trip_id = (SELECT id FROM trips WHERE vehicle_no = 'BUS-102' LIMIT 1) WHERE id IN (7, 8) AND trip_id IS NULL;

  -- ملاحظات المشرفين وتقييمات الحجاج على عرفة: بعد الغروب
  UPDATE comments SET created_at = ((d10 - 1) + time '18:05') AT TIME ZONE 'Asia/Riyadh' + (id * interval '12 minutes')
   WHERE ritual_id = 2;
  UPDATE activity_log SET created_at = ((d10 - 1) + time '18:20') AT TIME ZONE 'Asia/Riyadh' + (group_id * interval '10 minutes')
   WHERE action = 'FINISH_RITUAL' AND description LIKE '%عرفة%';
  UPDATE activity_log SET description = replace(description, '«الوقوف بعرفة»', '«الوقوف بعرفة (من الزوال حتى الغروب)»')
   WHERE description LIKE '%«الوقوف بعرفة»%';
  UPDATE activity_log SET description = replace(description, '«تجمع الصعود إلى عرفة»', '«التجمع في مخيم منى للتصعيد إلى عرفة»')
   WHERE description LIKE '%«تجمع الصعود إلى عرفة»%';

  -- إعادة بناء تقارير المناسك المكتملة بالأوقات الصحيحة (تعليق المشرف يبقى كما هو)
  FOR rec IN SELECT r.id AS rid, g.id AS gid FROM rituals r JOIN groups g ON g.campaign_id = r.campaign_id
              WHERE r.campaign_id = 1 AND r.status = 'COMPLETED' LOOP
    PERFORM _build_ritual_report(rec.rid, rec.gid, NULL, NULL);
  END LOOP;

  RAISE NOTICE 'تم تصحيح التسلسل الزمني: يوم النحر = %', d10;
END $$;

-- تحقق
SELECT seq, hajj_day, name,
       to_char(starts_at AT TIME ZONE 'Asia/Riyadh', 'MM-DD HH24:MI') AS يبدأ,
       to_char(ends_at   AT TIME ZONE 'Asia/Riyadh', 'MM-DD HH24:MI') AS ينتهي, status
  FROM rituals WHERE campaign_id = 1 ORDER BY seq;
