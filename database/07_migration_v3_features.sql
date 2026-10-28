-- =====================================================================
-- عين الحملة — ترقية v3: المزايا الذكية
-- يُشغَّل بعد migration_v2.sql (يعتمد على: location_pings, priority_level,
-- preferred_language, _auth, _dist_m, _notify, _log, _severity ...)
-- Supabase → SQL Editor → الصقي الملف كاملاً → Run. آمن لإعادة التشغيل.
-- =====================================================================
-- ما يضيفه v3 (4 جداول → المجموع 25 جدولاً):
--  • buddy_pairs      نظام الرفيق: كل حاج مربوط بحاج آخر من نفس الفوج
--  • meeting_points   نقاط اللقاء المعتمدة للحملة
--  • heat_readings    قراءات الحرارة والرطوبة لكل موقع
--  • crowd_forecasts  كثافة الحشود المتوقعة لكل موقع ولكل فترة
--  • أنواع تنبيه جديدة: HEAT_STRESS, BUDDY_SPLIT
--  • دوال: مؤشر خطر الضياع، أفضل نقطة لقاء، جاهزية الحافلة،
--    مراقبة الحر، أفضل وقت للتحرك، فحص انفصال الرفاق
-- =====================================================================

-- 0) قيم ENUM الجديدة تُحفظ أولًا (نفس سبب v2: خطأ 55P04)
BEGIN;
ALTER TYPE alert_type ADD VALUE IF NOT EXISTS 'HEAT_STRESS';
ALTER TYPE alert_type ADD VALUE IF NOT EXISTS 'BUDDY_SPLIT';
COMMIT;

-- 1) لغات بطاقة الطوارئ: إضافة التركية والفرنسية
ALTER TABLE pilgrims DROP CONSTRAINT IF EXISTS chk_pilgrims_language;
ALTER TABLE pilgrims ADD CONSTRAINT chk_pilgrims_language CHECK (preferred_language IN ('ar','en','ur','id','tr','fr'));

-- =====================================================================
-- 2) الجداول الجديدة
-- =====================================================================

-- نظام الرفيق: زوج واحد لكل حاج، والاثنان من نفس الفوج
CREATE TABLE IF NOT EXISTS buddy_pairs (
    id            BIGSERIAL PRIMARY KEY,
    pilgrim_a_id  BIGINT      NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
    pilgrim_b_id  BIGINT      NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
    max_distance_m INT        NOT NULL DEFAULT 150 CHECK (max_distance_m BETWEEN 20 AND 2000),
    created_by    BIGINT      REFERENCES users(id),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    CONSTRAINT chk_buddy_order CHECK (pilgrim_a_id < pilgrim_b_id)   -- يمنع تكرار الزوج بالعكس
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_buddy_a ON buddy_pairs (pilgrim_a_id);
CREATE UNIQUE INDEX IF NOT EXISTS uq_buddy_b ON buddy_pairs (pilgrim_b_id);

CREATE OR REPLACE FUNCTION trg_buddy_check()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
  IF EXISTS (SELECT 1 FROM buddy_pairs WHERE id IS DISTINCT FROM NEW.id
              AND (pilgrim_a_id IN (NEW.pilgrim_a_id, NEW.pilgrim_b_id) OR pilgrim_b_id IN (NEW.pilgrim_a_id, NEW.pilgrim_b_id))) THEN
    RAISE EXCEPTION 'BUDDY_TAKEN' USING HINT = 'أحد الحاجين مربوط برفيق آخر';
  END IF;
  IF (SELECT group_id FROM pilgrims WHERE id = NEW.pilgrim_a_id) IS DISTINCT FROM
     (SELECT group_id FROM pilgrims WHERE id = NEW.pilgrim_b_id) THEN
    RAISE EXCEPTION 'BUDDY_GROUP' USING HINT = 'الرفيقان يجب أن يكونا من نفس الفوج';
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS buddy_pairs_check ON buddy_pairs;
CREATE TRIGGER buddy_pairs_check BEFORE INSERT OR UPDATE ON buddy_pairs
  FOR EACH ROW EXECUTE FUNCTION trg_buddy_check();

-- نقاط اللقاء المعتمدة (بوابات، مستشفيات، محطات) — يمكن إغلاق نقطة مؤقتًا بسبب الزحام
CREATE TABLE IF NOT EXISTS meeting_points (
    id           BIGSERIAL PRIMARY KEY,
    campaign_id  BIGINT       NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    name         VARCHAR(150) NOT NULL,
    latitude     NUMERIC(9,6) NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
    longitude    NUMERIC(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    is_open      BOOLEAN      NOT NULL DEFAULT TRUE,
    landmark     VARCHAR(200),                       -- وصف يفهمه الحاج: "بجانب اللوحة الخضراء رقم ٥١٤"
    created_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- قراءات الطقس لكل موقع
CREATE TABLE IF NOT EXISTS heat_readings (
    id            BIGSERIAL PRIMARY KEY,
    location_id   BIGINT       NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
    temperature_c NUMERIC(4,1) NOT NULL CHECK (temperature_c BETWEEN -10 AND 60),
    humidity_pct  SMALLINT     NOT NULL CHECK (humidity_pct BETWEEN 0 AND 100),
    recorded_at   TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- كثافة الحشود المتوقعة (شخص/م²) لكل موقع ولكل فترة
CREATE TABLE IF NOT EXISTS crowd_forecasts (
    id           BIGSERIAL PRIMARY KEY,
    location_id  BIGINT       NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
    slot_start   TIMESTAMPTZ  NOT NULL,
    slot_minutes SMALLINT     NOT NULL DEFAULT 120 CHECK (slot_minutes BETWEEN 15 AND 360),
    density      NUMERIC(3,1) NOT NULL CHECK (density BETWEEN 0 AND 9.9),
    CONSTRAINT uq_crowd_slot UNIQUE (location_id, slot_start)
);

ALTER TABLE alerts ADD COLUMN IF NOT EXISTS meeting_point_id BIGINT REFERENCES meeting_points(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_meeting_points_campaign ON meeting_points (campaign_id) WHERE is_open;
CREATE INDEX IF NOT EXISTS idx_heat_location_time      ON heat_readings (location_id, recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_crowd_location_slot     ON crowd_forecasts (location_id, slot_start);

-- =====================================================================
-- 3) دوال داخلية
-- =====================================================================

-- رفيق الحاج (أو NULL)
CREATE OR REPLACE FUNCTION _buddy_of(p_pilgrim BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN pilgrim_a_id = p_pilgrim THEN pilgrim_b_id ELSE pilgrim_a_id END
    FROM buddy_pairs WHERE p_pilgrim IN (pilgrim_a_id, pilgrim_b_id) LIMIT 1
$$;

-- مركز الفوج = آخر موقع لمشرف الفوج (خلال ٣٠ دقيقة) لأنه يبقى مع الفوج،
-- وإن لم يتوفر: الوسيط (median) لآخر مواقع الأفراد بدون الحاج نفسه — الوسيط لا يتأثر بحاج تائه بعيد
CREATE OR REPLACE FUNCTION _group_center(p_group BIGINT, p_exclude BIGINT DEFAULT NULL)
RETURNS TABLE (lat NUMERIC, lng NUMERIC) LANGUAGE sql STABLE AS $$
  WITH sup AS (
    SELECT l.latitude, l.longitude FROM location_pings l
     WHERE l.user_id = _group_supervisor_user(p_group) AND l.client_recorded_at > now() - interval '30 minutes'
     ORDER BY l.client_recorded_at DESC LIMIT 1),
  mem AS (
    SELECT percentile_cont(0.5) WITHIN GROUP (ORDER BY lp.latitude)::numeric  AS lat,
           percentile_cont(0.5) WITHIN GROUP (ORDER BY lp.longitude)::numeric AS lng
      FROM pilgrims pp
      CROSS JOIN LATERAL (SELECT latitude, longitude FROM location_pings l
                           WHERE l.user_id = pp.user_id AND l.client_recorded_at > now() - interval '30 minutes'
                           ORDER BY l.client_recorded_at DESC LIMIT 1) lp
     WHERE pp.group_id = p_group AND pp.id IS DISTINCT FROM p_exclude)
  SELECT coalesce((SELECT latitude FROM sup), mem.lat), coalesce((SELECT longitude FROM sup), mem.lng) FROM mem
$$;

-- الإحساس الحراري (مبسّط): الحرارة + أثر الرطوبة فوق ٣٠٪
CREATE OR REPLACE FUNCTION _feels_like(p_temp NUMERIC, p_humidity INT)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT round(p_temp + greatest(0, p_humidity - 30) * 0.25)::int
$$;

-- الحد الحراري الشخصي: ٤٠° لكبار السن (٦٠+) أو أصحاب الحالات الصحية، ٤٥° لغيرهم
CREATE OR REPLACE FUNCTION _heat_limit(p pilgrims)
RETURNS INT LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN date_part('year', age(p.birth_date)) >= 60 OR coalesce(btrim(p.medical_notes), '') <> '' THEN 40 ELSE 45 END
$$;

-- مؤشر خطر الضياع 0–100 (نفس معادلة الواجهة):
--   البعد عن مركز الفوج ٣٥ + دقائق منذ آخر نبضة ٢٥ + البطارية ١٥ + العمر ١٠ + الحالة الصحية ١٠ + بعد الرفيق ٥
CREATE OR REPLACE FUNCTION _lost_risk(p_pilgrim BIGINT)
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE p pilgrims; me location_pings; c RECORD; v_dist INT; v_seen INT; v_age INT; v_buddy BIGINT;
        bp location_pings; v_bdist INT; s NUMERIC := 0;
BEGIN
  SELECT * INTO p FROM pilgrims WHERE id = p_pilgrim;
  SELECT * INTO me FROM location_pings WHERE user_id = p.user_id ORDER BY client_recorded_at DESC LIMIT 1;
  SELECT * INTO c FROM _group_center(p.group_id, p.id);
  v_dist := _dist_m(me.latitude, me.longitude, c.lat, c.lng);
  v_seen := CASE WHEN me.id IS NULL THEN 60 ELSE floor(extract(epoch FROM now() - me.client_recorded_at) / 60)::int END;
  v_age  := date_part('year', age(p.birth_date))::int;

  s := s + least(35, coalesce(v_dist, 0) / 1000.0 * 35);
  s := s + least(25, v_seen / 30.0 * 25);
  s := s + CASE WHEN me.battery_pct < 15 THEN 15 WHEN me.battery_pct < 30 THEN 9 WHEN me.battery_pct < 50 THEN 4 ELSE 0 END;
  s := s + CASE WHEN v_age >= 70 THEN 10 WHEN v_age >= 60 THEN 6 ELSE 0 END;
  s := s + CASE WHEN coalesce(btrim(p.medical_notes), '') <> '' THEN 10 ELSE 0 END;

  v_buddy := _buddy_of(p.id);
  IF v_buddy IS NOT NULL AND me.id IS NOT NULL THEN
    SELECT lp.* INTO bp FROM location_pings lp JOIN pilgrims b ON b.user_id = lp.user_id
     WHERE b.id = v_buddy ORDER BY lp.client_recorded_at DESC LIMIT 1;
    v_bdist := _dist_m(me.latitude, me.longitude, bp.latitude, bp.longitude);
    IF v_bdist > 500 THEN s := s + 5; END IF;
  END IF;

  RETURN json_build_object('score', round(least(100, s))::int, 'distance_m', v_dist, 'seen_min', v_seen,
    'battery', me.battery_pct, 'age', v_age, 'buddy_id', v_buddy, 'buddy_distance_m', v_bdist,
    'lat', me.latitude, 'lng', me.longitude);
END $$;

-- أفضل نقطة لقاء: أقل (مسافة الحاج × ١٫٤ + مسافة مركز الفوج) بين النقاط المفتوحة
CREATE OR REPLACE FUNCTION _best_meeting_point(p_pilgrim BIGINT)
RETURNS BIGINT LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE p pilgrims; me location_pings; c RECORD; v_id BIGINT;
BEGIN
  SELECT * INTO p FROM pilgrims WHERE id = p_pilgrim;
  SELECT * INTO me FROM location_pings WHERE user_id = p.user_id ORDER BY client_recorded_at DESC LIMIT 1;
  SELECT * INTO c FROM _group_center(p.group_id, p.id);
  SELECT m.id INTO v_id FROM meeting_points m
   WHERE m.campaign_id = p.campaign_id AND m.is_open
   ORDER BY coalesce(_dist_m(me.latitude, me.longitude, m.latitude, m.longitude), 0) * 1.4
          + coalesce(_dist_m(c.lat, c.lng, m.latitude, m.longitude), 0), m.id
   LIMIT 1;
  RETURN v_id;
END $$;

-- =====================================================================
-- 4) خدمات المشرف والإدارة (app_*) — كل دالة تتحقق من الجلسة والدور
-- =====================================================================

-- قائمة الأعضاء مرتبة بمؤشر خطر الضياع
CREATE OR REPLACE FUNCTION app_members_risk(p_token UUID, p_group_id BIGINT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_groups BIGINT[];
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  v_groups := _visible_groups(u);
  IF p_group_id IS NOT NULL THEN
    IF NOT p_group_id = ANY (v_groups) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
    v_groups := ARRAY[p_group_id];
  END IF;
  RETURN (SELECT coalesce(json_agg(x ORDER BY (x.risk->>'score')::int DESC), '[]'::json) FROM (
    SELECT pp.id, us.full_name, pp.nationality, pp.preferred_language, pp.group_id, g.name AS group_name,
           pp.priority_level, _lost_risk(pp.id) AS risk,
           (SELECT a.status FROM attendance a WHERE a.pilgrim_id = pp.id ORDER BY a.checkpoint_time DESC LIMIT 1) AS status
      FROM pilgrims pp JOIN users us ON us.id = pp.user_id LEFT JOIN groups g ON g.id = pp.group_id
     WHERE pp.group_id = ANY (v_groups)) x);
END $$;

-- ربط رفيقين (أو فك الربط بإرسال p_b = NULL)
CREATE OR REPLACE FUNCTION app_set_buddy(p_token UUID, p_a BIGINT, p_b BIGINT, p_max_distance INT DEFAULT 150)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_group BIGINT; v_id BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN']::user_role[]);
  SELECT group_id INTO v_group FROM pilgrims WHERE id = p_a;
  IF NOT _can_manage_group(u, v_group) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  DELETE FROM buddy_pairs WHERE p_a IN (pilgrim_a_id, pilgrim_b_id) OR p_b IN (pilgrim_a_id, pilgrim_b_id);
  IF p_b IS NULL THEN RETURN NULL; END IF;
  INSERT INTO buddy_pairs (pilgrim_a_id, pilgrim_b_id, max_distance_m, created_by)
  VALUES (least(p_a, p_b), greatest(p_a, p_b), coalesce(p_max_distance, 150), u.id) RETURNING id INTO v_id;
  PERFORM _log(u.id, 'SET_BUDDY', 'buddy_pair', v_id, v_group, 'ربط رفيقين في الفوج');
  RETURN v_id;
END $$;

-- إرسال أفضل نقطة لقاء لتنبيه: تُحفظ على التنبيه وتُرسل للحاج ولرفيقه
CREATE OR REPLACE FUNCTION app_send_meeting_point(p_token UUID, p_alert_id BIGINT, p_meeting_point_id BIGINT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; a alerts; p pilgrims; m meeting_points; v_buddy BIGINT; v_n INT := 0;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  SELECT * INTO a FROM alerts WHERE id = p_alert_id;
  SELECT * INTO p FROM pilgrims WHERE id = a.pilgrim_id;
  IF a.id IS NULL OR NOT _can_manage_group(u, p.group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT * INTO m FROM meeting_points WHERE id = coalesce(p_meeting_point_id, _best_meeting_point(p.id));
  IF m.id IS NULL THEN RAISE EXCEPTION 'NO_MEETING_POINT' USING HINT = 'لا توجد نقطة لقاء مفتوحة لهذه الحملة'; END IF;

  UPDATE alerts SET meeting_point_id = m.id, status = CASE WHEN status = 'OPEN' THEN 'IN_PROGRESS' ELSE status END
   WHERE id = a.id;
  PERFORM _notify(p.user_id, a.id, NULL, 'توجّه إلى نقطة اللقاء', m.name || coalesce(' — ' || m.landmark, ''));
  v_n := 1;
  v_buddy := _buddy_of(p.id);
  IF v_buddy IS NOT NULL THEN
    PERFORM _notify((SELECT user_id FROM pilgrims WHERE id = v_buddy), a.id, NULL, 'رفيقك يحتاجك', 'قابل رفيقك عند ' || m.name);
    v_n := v_n + 1;
  END IF;
  PERFORM _log(u.id, 'SEND_MEETING_POINT', 'alert', a.id, p.group_id, 'أرسل نقطة اللقاء «' || m.name || '»');
  RETURN json_build_object('meeting_point_id', m.id, 'name', m.name, 'lat', m.latitude, 'lng', m.longitude, 'notified', v_n);
END $$;

-- جاهزية الحافلة: من داخل نطاق نقطة الصعود بنبضة حديثة، ومن ينقص
CREATE OR REPLACE FUNCTION app_bus_readiness(p_token UUID, p_trip_id BIGINT, p_group_id BIGINT, p_radius_m INT DEFAULT 100)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; t trips; l locations;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  IF NOT _can_manage_group(u, p_group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT * INTO t FROM trips WHERE id = p_trip_id;
  SELECT * INTO l FROM locations WHERE id = t.route_from_id;
  RETURN (WITH m AS (
      SELECT pp.id, us.full_name, pp.preferred_language,
             _dist_m(lp.latitude, lp.longitude, l.latitude, l.longitude) AS d, lp.client_recorded_at AS at
        FROM pilgrims pp JOIN users us ON us.id = pp.user_id
        LEFT JOIN LATERAL (SELECT * FROM location_pings x WHERE x.user_id = pp.user_id
                            ORDER BY x.client_recorded_at DESC LIMIT 1) lp ON TRUE
       WHERE pp.group_id = p_group_id)
    SELECT json_build_object('trip', t.vehicle_no, 'from', l.name, 'departure_time', t.departure_time,
      'total', count(*),
      'ready', count(*) FILTER (WHERE d <= p_radius_m AND at > now() - interval '5 minutes'),
      'missing', coalesce(json_agg(json_build_object('id', id, 'name', full_name, 'distance_m', d, 'lang', preferred_language))
                 FILTER (WHERE d IS NULL OR d > p_radius_m OR at <= now() - interval '5 minutes'), '[]'::json))
    FROM m);
END $$;

-- مراقبة الحر: آخر قراءة لموقع وقائمة الحجاج الذين تجاوزوا حدهم الشخصي
CREATE OR REPLACE FUNCTION app_heat_watch(p_token UUID, p_location_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; h heat_readings; v_feels INT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  SELECT * INTO h FROM heat_readings WHERE location_id = p_location_id ORDER BY recorded_at DESC LIMIT 1;
  IF h.id IS NULL THEN RETURN json_build_object('reading', NULL, 'at_risk', '[]'::json); END IF;
  v_feels := _feels_like(h.temperature_c, h.humidity_pct);
  RETURN json_build_object(
    'reading', json_build_object('temp', h.temperature_c, 'humidity', h.humidity_pct, 'feels_like', v_feels, 'at', h.recorded_at),
    'at_risk', (SELECT coalesce(json_agg(json_build_object('id', pp.id, 'name', us.full_name, 'limit', _heat_limit(pp))
                  ORDER BY pp.birth_date), '[]'::json)
                  FROM pilgrims pp JOIN users us ON us.id = pp.user_id
                 WHERE pp.group_id = ANY (_visible_groups(u)) AND v_feels >= _heat_limit(pp)));
END $$;

-- أفضل وقت للتحرك إلى موقع (مثل الجمرات) ضمن نافذة زمنية
CREATE OR REPLACE FUNCTION app_best_slot(p_token UUID, p_location_id BIGINT, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token);
  RETURN json_build_object(
    'best', (SELECT json_build_object('slot_start', slot_start, 'density', density) FROM crowd_forecasts
              WHERE location_id = p_location_id AND slot_start BETWEEN p_from AND p_to ORDER BY density, slot_start LIMIT 1),
    'peak', (SELECT max(density) FROM crowd_forecasts WHERE location_id = p_location_id AND slot_start BETWEEN p_from AND p_to),
    'slots', (SELECT coalesce(json_agg(json_build_object('slot_start', slot_start, 'density', density) ORDER BY slot_start), '[]'::json)
                FROM crowd_forecasts WHERE location_id = p_location_id AND slot_start BETWEEN p_from AND p_to));
END $$;

-- فحص دوري (يُستدعى مع app_tick): تنبيه انفصال الرفاق + تنبيه الإجهاد الحراري
CREATE OR REPLACE FUNCTION app_smart_tick(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_split INT := 0; v_heat INT := 0; rec RECORD; v_alert BIGINT; v_feels INT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);

  -- انفصال الرفاق: المسافة بين آخر نبضتين (خلال ١٠ دقائق) أكبر من الحد
  FOR rec IN
    SELECT bp.pilgrim_a_id, bp.pilgrim_b_id, bp.max_distance_m, pa.group_id, pa.priority_level, pa.user_id AS ua, pb.user_id AS ub,
           _dist_m(la.latitude, la.longitude, lb.latitude, lb.longitude) AS d
      FROM buddy_pairs bp
      JOIN pilgrims pa ON pa.id = bp.pilgrim_a_id JOIN pilgrims pb ON pb.id = bp.pilgrim_b_id
      JOIN LATERAL (SELECT * FROM location_pings x WHERE x.user_id = pa.user_id AND x.client_recorded_at > now() - interval '10 minutes'
                     ORDER BY x.client_recorded_at DESC LIMIT 1) la ON TRUE
      JOIN LATERAL (SELECT * FROM location_pings x WHERE x.user_id = pb.user_id AND x.client_recorded_at > now() - interval '10 minutes'
                     ORDER BY x.client_recorded_at DESC LIMIT 1) lb ON TRUE
     WHERE pa.group_id = ANY (_visible_groups(u))
  LOOP
    IF rec.d > rec.max_distance_m AND NOT EXISTS (
         SELECT 1 FROM alerts WHERE pilgrim_id IN (rec.pilgrim_a_id, rec.pilgrim_b_id) AND type = 'BUDDY_SPLIT'
            AND status <> 'RESOLVED' AND created_at > now() - interval '30 minutes') THEN
      INSERT INTO alerts (pilgrim_id, type, severity, note)
      VALUES (rec.pilgrim_a_id, 'BUDDY_SPLIT', _severity(CASE WHEN rec.d > 500 THEN 'MEDIUM' ELSE 'LOW' END::alert_severity, rec.priority_level),
              'المسافة بين الرفيقين ' || rec.d || ' م')
      RETURNING id INTO v_alert;
      PERFORM _notify(rec.ua, v_alert, NULL, 'ابتعدت عن رفيقك', 'المسافة ' || rec.d || ' م — ارجعا لبعض أو توجها لأقرب نقطة لقاء');
      PERFORM _notify(rec.ub, v_alert, NULL, 'ابتعدت عن رفيقك', 'المسافة ' || rec.d || ' م — ارجعا لبعض أو توجها لأقرب نقطة لقاء');
      IF rec.d > 500 AND _group_supervisor_user(rec.group_id) IS NOT NULL THEN
        PERFORM _notify(_group_supervisor_user(rec.group_id), v_alert, NULL, 'انفصال رفيقين', 'المسافة ' || rec.d || ' م');
      END IF;
      v_split := v_split + 1;
    END IF;
  END LOOP;

  -- الإجهاد الحراري: أقرب موقع لآخر نبضة الحاج وآخر قراءة طقس خلال ساعة
  FOR rec IN
    SELECT pp.id, pp.user_id, pp.priority_level, _heat_limit(pp) AS lim, h.temperature_c, h.humidity_pct
      FROM pilgrims pp
      JOIN LATERAL (SELECT * FROM location_pings x WHERE x.user_id = pp.user_id AND x.client_recorded_at > now() - interval '30 minutes'
                     ORDER BY x.client_recorded_at DESC LIMIT 1) lp ON TRUE
      JOIN LATERAL (SELECT l.id FROM locations l WHERE l.campaign_id = pp.campaign_id
                     ORDER BY _dist_m(lp.latitude, lp.longitude, l.latitude, l.longitude) LIMIT 1) nl ON TRUE
      JOIN LATERAL (SELECT * FROM heat_readings hr WHERE hr.location_id = nl.id AND hr.recorded_at > now() - interval '60 minutes'
                     ORDER BY hr.recorded_at DESC LIMIT 1) h ON TRUE
     WHERE pp.group_id = ANY (_visible_groups(u))
  LOOP
    v_feels := _feels_like(rec.temperature_c, rec.humidity_pct);
    IF v_feels >= rec.lim AND NOT EXISTS (
         SELECT 1 FROM alerts WHERE pilgrim_id = rec.id AND type = 'HEAT_STRESS' AND created_at > now() - interval '2 hours') THEN
      INSERT INTO alerts (pilgrim_id, type, severity, note)
      VALUES (rec.id, 'HEAT_STRESS', _severity('LOW', rec.priority_level), 'الإحساس الحراري ' || v_feels || '°')
      RETURNING id INTO v_alert;
      PERFORM _notify(rec.user_id, v_alert, NULL, 'اشرب ماء واجلس في الظل', 'الحرارة المحسوسة ' || v_feels || '° وهي أعلى من الحد الآمن لك');
      v_heat := v_heat + 1;
    END IF;
  END LOOP;

  RETURN json_build_object('buddy_split_alerts', v_split, 'heat_alerts', v_heat);
END $$;

-- =====================================================================
-- 5) الصلاحيات (نفس نمط v2)
-- =====================================================================
DO $$
DECLARE t TEXT; f RECORD;
BEGIN
  FOREACH t IN ARRAY ARRAY['buddy_pairs','meeting_points','heat_readings','crowd_forecasts'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    EXECUTE format('DROP POLICY IF EXISTS app_read ON public.%I', t);
  END LOOP;
  -- تُقرأ مباشرة من لوحة التحكم
  FOREACH t IN ARRAY ARRAY['meeting_points','heat_readings','crowd_forecasts','buddy_pairs'] LOOP
    EXECUTE format('GRANT SELECT ON public.%I TO anon, authenticated', t);
    EXECUTE format('CREATE POLICY app_read ON public.%I FOR SELECT TO anon, authenticated USING (true)', t);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('_buddy_of','_group_center','_feels_like','_heat_limit','_lost_risk',
              '_best_meeting_point','app_members_risk','app_set_buddy','app_send_meeting_point','app_bus_readiness',
              'app_heat_watch','app_best_slot','app_smart_tick') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    IF f.proname LIKE 'app\_%' THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig); END IF;
  END LOOP;
END $$;

-- تحقق: يجب أن يظهر 25 جدولاً
SELECT count(*) AS tables_count FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
