-- =====================================================================
-- عين الحملة — v4.1: دوال القراءة للوحة التحكم + أداة سيناريو العرض
-- يُشغَّل بعد migration_v4_hajj.sql. آمن لإعادة التشغيل. لا يضيف جداول.
-- =====================================================================

-- حالة الرفاق الآن: المسافة بين آخر موقعين
CREATE OR REPLACE FUNCTION app_buddy_status(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  RETURN (SELECT coalesce(json_agg(x ORDER BY x.distance_m DESC NULLS LAST), '[]'::json) FROM (
    SELECT bp.id, bp.max_distance_m, pa.id AS a_id, ua.full_name AS a_name, pb.id AS b_id, ub.full_name AS b_name, pa.group_id,
           _dist_m(la.latitude, la.longitude, lb.latitude, lb.longitude) AS distance_m
      FROM buddy_pairs bp
      JOIN pilgrims pa ON pa.id = bp.pilgrim_a_id JOIN users ua ON ua.id = pa.user_id
      JOIN pilgrims pb ON pb.id = bp.pilgrim_b_id JOIN users ub ON ub.id = pb.user_id
      LEFT JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = pa.user_id ORDER BY l.client_recorded_at DESC LIMIT 1) la ON TRUE
      LEFT JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = pb.user_id ORDER BY l.client_recorded_at DESC LIMIT 1) lb ON TRUE
     WHERE pa.group_id = ANY (_visible_groups(u))) x);
END $$;

-- نظرة الأدوية لليوم (بتوقيت مكة)
CREATE OR REPLACE FUNCTION app_meds_overview(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_day DATE := (now() AT TIME ZONE 'Asia/Riyadh')::date;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  RETURN (SELECT coalesce(json_agg(json_build_object('medication_id', m.id, 'pilgrim_id', pp.id, 'pilgrim', us.full_name,
            'group_id', pp.group_id, 'name', m.name, 'condition', m.condition, 'needs_fridge', m.needs_fridge, 'prn', cardinality(m.schedule_times) = 0,
            'allergies', pp.allergies, 'blood_type', pp.blood_type,
            'doses', (SELECT coalesce(json_agg(json_build_object('id', d.id, 'at', d.scheduled_at, 'status', d.status, 'taken_at', d.taken_at)
                        ORDER BY d.scheduled_at), '[]'::json)
                        FROM medication_doses d WHERE d.medication_id = m.id AND (d.scheduled_at AT TIME ZONE 'Asia/Riyadh')::date = v_day))
            ORDER BY us.full_name, m.name), '[]'::json)
            FROM medications m JOIN pilgrims pp ON pp.id = m.pilgrim_id JOIN users us ON us.id = pp.user_id
           WHERE m.is_active AND pp.group_id = ANY (_visible_groups(u)));
END $$;

-- فحوص "أنت بخير؟" آخر ٢٤ ساعة
CREATE OR REPLACE FUNCTION app_wellness_list(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  RETURN (SELECT coalesce(json_agg(json_build_object('id', w.id, 'pilgrim', us.full_name, 'pilgrim_id', pp.id, 'still_minutes', w.still_minutes,
            'status', w.status, 'sent_at', w.sent_at, 'answered_at', w.answered_at, 'lat', w.latitude, 'lng', w.longitude) ORDER BY w.sent_at DESC), '[]'::json)
            FROM wellness_checks w JOIN pilgrims pp ON pp.id = w.pilgrim_id JOIN users us ON us.id = pp.user_id
           WHERE w.sent_at > now() - interval '24 hours' AND pp.group_id = ANY (_visible_groups(u)));
END $$;

-- روابط الأهل
CREATE OR REPLACE FUNCTION app_family_links(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  RETURN (SELECT coalesce(json_agg(json_build_object('id', f.id, 'token', f.token, 'pilgrim_id', pp.id, 'pilgrim', us.full_name,
            'contact', e.name, 'relation', e.relation, 'expires_at', f.expires_at, 'is_active', f.is_active AND f.expires_at > now(),
            'views', f.views, 'last_viewed', f.last_viewed, 'created_at', f.created_at) ORDER BY f.created_at DESC), '[]'::json)
            FROM family_links f JOIN pilgrims pp ON pp.id = f.pilgrim_id JOIN users us ON us.id = pp.user_id
            LEFT JOIN emergency_contacts e ON e.id = f.contact_id
           WHERE pp.group_id = ANY (_visible_groups(u)));
END $$;

-- جهات طوارئ حاج (لاختيار مستلم رابط الأهل)
CREATE OR REPLACE FUNCTION app_contacts_of(p_token UUID, p_pilgrim_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_group BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN']::user_role[]);
  SELECT group_id INTO v_group FROM pilgrims WHERE id = p_pilgrim_id;
  IF NOT _can_manage_group(u, v_group) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  RETURN (SELECT coalesce(json_agg(json_build_object('id', id, 'name', name, 'relation', relation, 'is_primary', is_primary)
            ORDER BY is_primary DESC, id), '[]'::json) FROM emergency_contacts WHERE pilgrim_id = p_pilgrim_id);
END $$;

-- الرسائل الصوتية مع ترجماتها وعدد من سمعها
CREATE OR REPLACE FUNCTION app_voice_list(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  RETURN (SELECT coalesce(json_agg(json_build_object('id', v.id, 'sender', us.full_name, 'group', g.name, 'group_id', v.group_id,
            'transcript_ar', v.transcript_ar, 'is_urgent', v.is_urgent, 'created_at', v.created_at, 'audio_url', v.audio_url,
            'translations', (SELECT coalesce(json_object_agg(t.lang, t.text), '{}'::json) FROM voice_message_translations t WHERE t.voice_id = v.id),
            'status', app_voice_status(p_token, v.id)) ORDER BY v.created_at DESC), '[]'::json)
            FROM voice_messages v JOIN users us ON us.id = v.sender_id LEFT JOIN groups g ON g.id = v.group_id
           WHERE v.group_id IS NULL OR v.group_id = ANY (_visible_groups(u)));
END $$;

-- لوحة المفقودات
CREATE OR REPLACE FUNCTION app_lost_list(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  RETURN (SELECT coalesce(json_agg(json_build_object('id', l.id, 'category', l.category, 'description', l.description,
            'place', l.last_seen_place, 'status', l.status, 'is_urgent', l.is_urgent, 'created_at', l.created_at,
            'owner', ou.full_name, 'owner_id', l.owner_pilgrim_id, 'reporter', ru.full_name, 'finder', fu.full_name, 'found_at', l.found_at)
            ORDER BY (l.status = 'OPEN') DESC, l.is_urgent DESC, l.created_at DESC), '[]'::json)
            FROM lost_items l JOIN users ru ON ru.id = l.reporter_id
            LEFT JOIN pilgrims op ON op.id = l.owner_pilgrim_id LEFT JOIN users ou ON ou.id = op.user_id
            LEFT JOIN users fu ON fu.id = l.found_by
           WHERE l.campaign_id IN (SELECT campaign_id FROM groups WHERE id = ANY (_visible_groups(u))));
END $$;

-- أفضل نقطة لقاء لحاج (للعرض في صفحة التنبيهات قبل الإرسال)
CREATE OR REPLACE FUNCTION app_meeting_suggestion(p_token UUID, p_pilgrim_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; m meeting_points; me location_pings; c RECORD;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE id = p_pilgrim_id;
  IF p.id IS NULL OR NOT _can_manage_group(u, p.group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT * INTO m FROM meeting_points WHERE id = _best_meeting_point(p.id);
  SELECT * INTO me FROM location_pings WHERE user_id = p.user_id ORDER BY client_recorded_at DESC LIMIT 1;
  SELECT * INTO c FROM _group_center(p.group_id, p.id);
  RETURN json_build_object(
    'meeting_point', CASE WHEN m.id IS NULL THEN NULL ELSE json_build_object('id', m.id, 'name', m.name, 'landmark', m.landmark, 'lat', m.latitude, 'lng', m.longitude,
       'pilgrim_distance_m', _dist_m(me.latitude, me.longitude, m.latitude, m.longitude), 'group_distance_m', _dist_m(c.lat, c.lng, m.latitude, m.longitude)) END,
    'pilgrim', CASE WHEN me.id IS NULL THEN NULL ELSE json_build_object('lat', me.latitude, 'lng', me.longitude, 'at', me.client_recorded_at, 'battery', me.battery_pct) END,
    'group_center', json_build_object('lat', c.lat, 'lng', c.lng),
    'risk', _lost_risk(p.id),
    'buddy', (SELECT us.full_name FROM pilgrims b JOIN users us ON us.id = b.user_id WHERE b.id = _buddy_of(p.id)),
    'others', (SELECT coalesce(json_agg(json_build_object('id', id, 'name', name, 'lat', latitude, 'lng', longitude, 'is_open', is_open)), '[]'::json)
                 FROM meeting_points WHERE campaign_id = p.campaign_id));
END $$;

-- =====================================================================
-- أداة العرض (للإدارة فقط): تضع الحجاج في مواقع واقعية الآن حتى تظهر كل الميزات
-- بيانات حقيقية في القاعدة، والمواقع فقط هي المحاكاة بدل GPS الجوالات.
-- MINA   : الحجاج في مخيم منى، حاج بعيد ٩٠٠م ببطارية ضعيفة، ورفيقان منفصلان
-- ARAFAH : الحجاج في عرفة، وحاجان خارج حدود عرفة غربًا (جهة نمرة/عُرنة)
-- كلاهما يحدّث قراءات الحرارة وتوقعات الزحام وجرعات اليوم ومبيت الليلة الماضية
-- =====================================================================
CREATE OR REPLACE FUNCTION app_demo_scenario(p_token UUID, p_scenario TEXT DEFAULT 'MINA')
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_base RECORD; rec RECORD; v_n INT := 0; v_day DATE := (now() AT TIME ZONE 'Asia/Riyadh')::date;
        v_from TIMESTAMPTZ; v_to TIMESTAMPTZ; v_mina RECORD; v_jam BIGINT; h INT;
BEGIN
  u := _auth(p_token, ARRAY['ADMIN','OPERATIONS_CENTER']::user_role[]);
  IF p_scenario NOT IN ('MINA', 'ARAFAH') THEN RAISE EXCEPTION 'BAD_SCENARIO' USING HINT = 'السيناريو MINA أو ARAFAH'; END IF;

  IF p_scenario = 'MINA' THEN
    SELECT latitude AS lat, longitude AS lng INTO v_base FROM locations WHERE name LIKE 'مخيم الحملة%' ORDER BY id LIMIT 1;
    IF v_base.lat IS NULL THEN SELECT latitude AS lat, longitude AS lng INTO v_base FROM locations WHERE name = 'منى' LIMIT 1; END IF;
  ELSE
    SELECT latitude AS lat, longitude AS lng INTO v_base FROM locations WHERE name IN ('عرفات', 'عرفة') ORDER BY id LIMIT 1;
  END IF;
  IF v_base.lat IS NULL THEN RAISE EXCEPTION 'NO_BASE_LOCATION'; END IF;

  -- مواقع العرض السابقة (دقة 8م) تُستبدل حتى لا يختلط سيناريو بآخر
  DELETE FROM location_pings WHERE accuracy_m = 8 AND client_recorded_at > now() - interval '3 hours';

  -- إزاحات بالمتر (شمال، شرق) + البطارية + منذ كم دقيقة
  FOR rec IN
    SELECT us.id AS user_id, x.dn, x.de, x.bat, x.ago
      FROM (VALUES
        -- national_id, MINA(dn,de,bat,ago), ARAFAH(dn,de,bat,ago)
        ('1030303030',  10,  -15, 80, 1,    40,   -60, 77, 1),
        ('1030303031',  25,   10, 55, 2,     0, -2550, 52, 2),
        ('1030303032', -220, 180, 41, 4,   -70,    90, 39, 3),
        ('2040404040',  15,   20, 66, 1,    60,    20, 61, 1),
        ('2040404041', 480, -760, 14, 12,  150, -3000, 12, 9),
        ('1030303033', -20,    5, 72, 1,   -40,    30, 70, 1),
        ('1030303034',   5,  -25, 38, 2,    10,   -20, 35, 2),
        ('1030303035',  30,   30, 90, 1,    80,    60, 88, 1),
        ('2040404042', -35,  -10, 61, 2,   -90,   -40, 58, 2),
        ('1020202020',   0,    0, 95, 0,     0,     0, 93, 0),
        ('1020202021',  12,   12, 91, 0,    20,    10, 90, 0)
      ) AS t(nid, mdn, mde, mbat, mago, adn, ade, abat, aago)
      JOIN users us ON us.national_id = t.nid
      CROSS JOIN LATERAL (SELECT CASE WHEN p_scenario = 'MINA' THEN t.mdn ELSE t.adn END AS dn,
                                 CASE WHEN p_scenario = 'MINA' THEN t.mde ELSE t.ade END AS de,
                                 CASE WHEN p_scenario = 'MINA' THEN t.mbat ELSE t.abat END AS bat,
                                 CASE WHEN p_scenario = 'MINA' THEN t.mago ELSE t.aago END AS ago) x
  LOOP
    INSERT INTO location_pings (user_id, latitude, longitude, accuracy_m, battery_pct, client_recorded_at)
    VALUES (rec.user_id, round((v_base.lat + rec.dn / 110540.0)::numeric, 6),
            round((v_base.lng + rec.de / (111320.0 * cos(radians(v_base.lat::float8))))::numeric, 6), 8, rec.bat,
            now() - make_interval(mins => rec.ago));
    v_n := v_n + 1;
  END LOOP;

  -- قراءات الحرارة الآن لكل مواقع الحملة
  INSERT INTO heat_readings (location_id, temperature_c, humidity_pct)
  SELECT id, CASE WHEN name IN ('عرفات', 'عرفة') THEN 44 ELSE 42 END, CASE WHEN name IN ('عرفات', 'عرفة') THEN 24 ELSE 31 END
    FROM locations WHERE campaign_id = 1 OR campaign_id IS NULL;

  -- توقعات زحام الجمرات لـ ٢٤ ساعة القادمة (ذروة الظهر، أخف بعد العشاء)
  SELECT id INTO v_jam FROM locations WHERE name = 'الجمرات' LIMIT 1;
  IF v_jam IS NOT NULL THEN
    DELETE FROM crowd_forecasts WHERE location_id = v_jam AND slot_start > now() - interval '2 hours';
    FOR h IN 0 .. 11 LOOP
      INSERT INTO crowd_forecasts (location_id, slot_start, slot_minutes, density)
      SELECT v_jam, s, 120,
             round((1.4 + 3.9 * greatest(0, cos(radians((extract(hour FROM s AT TIME ZONE 'Asia/Riyadh') - 12.5) * 15))))::numeric, 1)
        FROM (SELECT date_trunc('hour', now()) + make_interval(hours => h * 2) AS s) z
      ON CONFLICT (location_id, slot_start) DO UPDATE SET density = EXCLUDED.density;
    END LOOP;
  END IF;

  -- جرعات اليوم + تأكيد بعض جرعات الصباح
  INSERT INTO medication_doses (medication_id, scheduled_at)
  SELECT m.id, (v_day + t) AT TIME ZONE 'Asia/Riyadh' FROM medications m CROSS JOIN LATERAL unnest(m.schedule_times) t WHERE m.is_active
  ON CONFLICT (medication_id, scheduled_at) DO NOTHING;
  UPDATE medication_doses d SET status = 'TAKEN', taken_at = d.scheduled_at + interval '6 minutes'
    FROM medications m JOIN pilgrims pp ON pp.id = m.pilgrim_id JOIN users us ON us.id = pp.user_id
   WHERE d.medication_id = m.id AND d.status = 'DUE' AND us.national_id IN ('1030303035', '1030303034')
     AND d.scheduled_at < now() - interval '30 minutes';

  -- مبيت الليلة الماضية بمنى (من ٥:٣٠م أمس إلى ٥:٣٠ص اليوم بتوقيت مكة)، مرة واحدة لكل ليلة
  v_from := ((v_day - 1) + time '17:30') AT TIME ZONE 'Asia/Riyadh';
  v_to   := (v_day + time '05:30') AT TIME ZONE 'Asia/Riyadh';
  SELECT latitude AS lat, longitude AS lng INTO v_mina FROM locations WHERE name LIKE 'مخيم الحملة%' ORDER BY id LIMIT 1;
  IF v_mina.lat IS NOT NULL AND NOT EXISTS (SELECT 1 FROM location_pings WHERE client_recorded_at BETWEEN v_from AND v_to AND accuracy_m = 7) THEN
    INSERT INTO location_pings (user_id, latitude, longitude, accuracy_m, battery_pct, client_recorded_at)
    SELECT us.id, v_mina.lat + (random() - 0.5) * 0.0006, v_mina.lng + (random() - 0.5) * 0.0006, 7, 70, ts
      FROM users us JOIN pilgrims pp ON pp.user_id = us.id
      CROSS JOIN LATERAL generate_series(v_from, v_to, interval '10 minutes') ts
     WHERE ts < v_from + CASE us.national_id WHEN '2040404041' THEN interval '90 minutes'
                                             WHEN '1030303032' THEN interval '3 hours 40 minutes'
                                             WHEN '1030303034' THEN interval '5 hours'
                                             ELSE interval '12 hours' END;
  END IF;

  PERFORM _log(u.id, 'DEMO_SCENARIO', NULL, NULL, NULL, 'شغّل سيناريو العرض ' || p_scenario);
  RETURN json_build_object('scenario', p_scenario, 'positions', v_n, 'night_from', v_from, 'night_to', v_to);
END $$;

DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('app_buddy_status','app_meds_overview','app_wellness_list','app_family_links',
              'app_contacts_of','app_voice_list','app_lost_list','app_meeting_suggestion','app_demo_scenario') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig);
  END LOOP;
END $$;

SELECT count(*) AS app_functions FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = 'public' AND p.proname LIKE 'app\_%';
