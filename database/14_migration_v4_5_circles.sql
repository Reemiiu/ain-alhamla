-- =====================================================================
-- عين الحملة — v4.5: «عائلتي ورفقتي» (دوائر الرفقة)
-- يُشغَّل بعد 13_migration_v4_4_alert_location.sql
-- Supabase → SQL Editor → الصقي الملف كاملاً → Run. آمن لإعادة التشغيل.
-- =====================================================================
-- الفكرة: الحاج نفسه يكوّن دائرة لعائلته أو أصدقائه (حتى 12 فرداً)، ويعطيهم «رمز الدائرة»،
-- وكل فرد ينضم بنفسه من جواله (موافقة صريحة على مشاركة الموقع داخل الدائرة).
-- تطوير لنظام الرفيق: الرفيق زوج يربطه المشرف داخل الفوج نفسه، والدائرة يكوّنها الحجاج
-- وقد تجمع أفراداً من أفواج مختلفة (مثل عائلة: الرجال في فوج والنساء في فوج آخر).
--
-- ما يضيفه (جدولان → المجموع 40 جدولاً):
--  • companion_circles  الدائرة: الاسم، رمز الانضمام، المسافة الآمنة، الحملة
--  • circle_members     أعضاء الدائرة (كل حاج في دائرة واحدة فقط)
--  • دوال الحاج: إنشاء، انضمام بالرمز، خروج، إزالة عضو (لمنشئ الدائرة)، حالة الأعضاء
--  • دالة اللوحة: نظرة على الدوائر وتباعد أفرادها
--  • فحص الانفصال داخل app_smart_tick (تنبيه BUDDY_SPLIT للفرد البعيد ولدائرته)
--  • مؤشر خطر الضياع: «بعد الرفيق» صار «بعد الرفيق أو أقرب فرد من الدائرة»
--  • عند SOS أو «أنا تائه»: يصل إشعار لأفراد دائرته
-- لا يضيف قيم ENUM جديدة (يستخدم نوع التنبيه BUDDY_SPLIT الموجود).
-- =====================================================================

-- =====================================================================
-- 1) الجداول
-- =====================================================================
CREATE TABLE IF NOT EXISTS companion_circles (
    id              BIGSERIAL PRIMARY KEY,
    campaign_id     BIGINT      NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    name            VARCHAR(60) NOT NULL CHECK (char_length(btrim(name)) BETWEEN 2 AND 60),
    join_code       CHAR(6)     NOT NULL UNIQUE CHECK (join_code ~ '^[A-HJ-NP-Z2-9]{6}$'),  -- بدون I و O و 0 و 1 حتى لا تلتبس
    max_distance_m  INT         NOT NULL DEFAULT 200 CHECK (max_distance_m BETWEEN 50 AND 2000),
    created_by      BIGINT      REFERENCES users(id) ON DELETE SET NULL,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS circle_members (
    circle_id   BIGINT      NOT NULL REFERENCES companion_circles(id) ON DELETE CASCADE,
    pilgrim_id  BIGINT      NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
    is_owner    BOOLEAN     NOT NULL DEFAULT FALSE,
    joined_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (circle_id, pilgrim_id)
);
-- كل حاج في دائرة واحدة فقط
CREATE UNIQUE INDEX IF NOT EXISTS uq_circle_members_pilgrim ON circle_members (pilgrim_id);
CREATE INDEX IF NOT EXISTS idx_companion_circles_campaign ON companion_circles (campaign_id);

-- =====================================================================
-- 2) دوال داخلية
-- =====================================================================

-- رمز انضمام جديد غير مكرر (6 خانات بلا حروف ملتبسة)
CREATE OR REPLACE FUNCTION _new_circle_code()
RETURNS CHAR(6) LANGUAGE plpgsql VOLATILE SECURITY DEFINER SET search_path = public AS $$
DECLARE v_alpha TEXT := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'; v_code TEXT;
BEGIN
  LOOP
    SELECT string_agg(substr(v_alpha, 1 + floor(random() * length(v_alpha))::int, 1), '') INTO v_code
      FROM generate_series(1, 6);
    EXIT WHEN NOT EXISTS (SELECT 1 FROM companion_circles WHERE join_code = v_code);
  END LOOP;
  RETURN v_code;
END $$;

-- دائرة الحاج (أو NULL)
CREATE OR REPLACE FUNCTION _circle_of(p_pilgrim BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT circle_id FROM circle_members WHERE pilgrim_id = p_pilgrim
$$;

-- أقرب فرد من دائرة الحاج له موقع خلال p_minutes دقيقة: {pilgrim_id, name, distance_m}
CREATE OR REPLACE FUNCTION _circle_nearest(p_pilgrim BIGINT, p_minutes INT DEFAULT 60)
RETURNS JSON LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  WITH me AS (
    SELECT lp.latitude, lp.longitude FROM pilgrims p
      JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = p.user_id
                     AND l.client_recorded_at > now() - make_interval(mins => p_minutes)
                     ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
     WHERE p.id = p_pilgrim)
  SELECT json_build_object('pilgrim_id', o.id, 'name', us.full_name,
                           'distance_m', _dist_m(me.latitude, me.longitude, lp.latitude, lp.longitude))
    FROM me, circle_members cm
    JOIN circle_members om ON om.circle_id = cm.circle_id AND om.pilgrim_id <> cm.pilgrim_id
    JOIN pilgrims o ON o.id = om.pilgrim_id JOIN users us ON us.id = o.user_id
    JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = o.user_id
                   AND l.client_recorded_at > now() - make_interval(mins => p_minutes)
                   ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
   WHERE cm.pilgrim_id = p_pilgrim
   ORDER BY _dist_m(me.latitude, me.longitude, lp.latitude, lp.longitude) LIMIT 1
$$;

-- إشعار كل أفراد الدائرة (عدا المستثنى)
CREATE OR REPLACE FUNCTION _notify_circle(p_circle BIGINT, p_except_pilgrim BIGINT, p_alert BIGINT, p_title TEXT, p_body TEXT)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE rec RECORD; v_n INT := 0;
BEGIN
  FOR rec IN SELECT p.user_id FROM circle_members cm JOIN pilgrims p ON p.id = cm.pilgrim_id
              WHERE cm.circle_id = p_circle AND cm.pilgrim_id IS DISTINCT FROM p_except_pilgrim LOOP
    PERFORM _notify(rec.user_id, p_alert, NULL, p_title, p_body);
    v_n := v_n + 1;
  END LOOP;
  RETURN v_n;
END $$;

-- =====================================================================
-- 3) خدمات الحاج (app_*) — كل دالة تتحقق من الجلسة وأن المستخدم حاج
-- =====================================================================

-- حالة دائرتي: الأعضاء وآخر موقع لكل فرد والمسافة والاتجاه مني
CREATE OR REPLACE FUNCTION app_circle_status(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; c companion_circles; me location_pings;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  SELECT cc.* INTO c FROM companion_circles cc JOIN circle_members cm ON cm.circle_id = cc.id WHERE cm.pilgrim_id = p.id;
  IF c.id IS NULL THEN RETURN json_build_object('circle', NULL, 'members', '[]'::json); END IF;
  me := _last_ping(u.id, 720);
  RETURN json_build_object(
    'circle', json_build_object('id', c.id, 'name', c.name, 'join_code', c.join_code, 'max_distance_m', c.max_distance_m,
              'is_owner', (SELECT is_owner FROM circle_members WHERE circle_id = c.id AND pilgrim_id = p.id),
              'created_at', c.created_at),
    'me', CASE WHEN me.id IS NULL THEN NULL ELSE json_build_object('lat', me.latitude, 'lng', me.longitude, 'at', me.client_recorded_at) END,
    'members', (SELECT coalesce(json_agg(x ORDER BY x.is_me DESC, x.is_owner DESC, x.joined_at), '[]'::json) FROM (
        SELECT o.id AS pilgrim_id, us.full_name AS name, us.phone, g.name AS group_name, cm.is_owner, cm.joined_at,
               o.id = p.id AS is_me, o.priority_level,
               lp.latitude AS lat, lp.longitude AS lng, lp.client_recorded_at AS at, lp.battery_pct AS battery,
               CASE WHEN o.id = p.id THEN NULL ELSE _dist_m(me.latitude, me.longitude, lp.latitude, lp.longitude) END AS distance_m,
               CASE WHEN o.id = p.id THEN NULL ELSE _bearing(me.latitude, me.longitude, lp.latitude, lp.longitude) END AS bearing
          FROM circle_members cm
          JOIN pilgrims o ON o.id = cm.pilgrim_id JOIN users us ON us.id = o.user_id
          LEFT JOIN groups g ON g.id = o.group_id
          LEFT JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = o.user_id
                              ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
         WHERE cm.circle_id = c.id) x));
END $$;

-- إنشاء دائرة: المنشئ أول عضو ويستلم رمز الانضمام
CREATE OR REPLACE FUNCTION app_circle_create(p_token UUID, p_name TEXT, p_max_distance INT DEFAULT 200)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_id BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  IF _circle_of(p.id) IS NOT NULL THEN
    RAISE EXCEPTION 'ALREADY_IN_CIRCLE' USING HINT = 'أنت في دائرة بالفعل — اخرج منها أولاً';
  END IF;
  IF char_length(btrim(coalesce(p_name, ''))) < 2 THEN
    RAISE EXCEPTION 'NAME_REQUIRED' USING HINT = 'اكتب اسماً للدائرة (حرفان على الأقل)';
  END IF;
  INSERT INTO companion_circles (campaign_id, name, join_code, max_distance_m, created_by)
  VALUES (p.campaign_id, left(btrim(p_name), 60), _new_circle_code(), least(2000, greatest(50, coalesce(p_max_distance, 200))), u.id)
  RETURNING id INTO v_id;
  INSERT INTO circle_members (circle_id, pilgrim_id, is_owner) VALUES (v_id, p.id, TRUE);
  RETURN app_circle_status(p_token);
END $$;

-- الانضمام برمز الدائرة (من نفس الحملة فقط، وحد أقصى 12 فرداً)
CREATE OR REPLACE FUNCTION app_circle_join(p_token UUID, p_code TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; c companion_circles; v_code TEXT; v_cur BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  v_code := upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g'));
  SELECT * INTO c FROM companion_circles WHERE join_code = v_code AND campaign_id = p.campaign_id;
  IF c.id IS NULL THEN
    RAISE EXCEPTION 'CIRCLE_NOT_FOUND' USING HINT = 'الرمز غير صحيح — تأكد منه مع صاحب الدائرة';
  END IF;
  v_cur := _circle_of(p.id);
  IF v_cur = c.id THEN RETURN app_circle_status(p_token); END IF;
  IF v_cur IS NOT NULL THEN
    RAISE EXCEPTION 'ALREADY_IN_CIRCLE' USING HINT = 'أنت في دائرة أخرى — اخرج منها أولاً';
  END IF;
  IF (SELECT count(*) FROM circle_members WHERE circle_id = c.id) >= 12 THEN
    RAISE EXCEPTION 'CIRCLE_FULL' USING HINT = 'الدائرة مكتملة (12 فرداً)';
  END IF;
  INSERT INTO circle_members (circle_id, pilgrim_id) VALUES (c.id, p.id);
  PERFORM _notify_circle(c.id, p.id, NULL, 'انضم فرد إلى «' || c.name || '»', u.full_name || ' انضم إلى دائرتكم');
  RETURN app_circle_status(p_token);
END $$;

-- الخروج من الدائرة: تنتقل الإدارة لأقدم عضو، وتُحذف الدائرة إن فرغت
CREATE OR REPLACE FUNCTION app_circle_leave(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; m circle_members; c companion_circles;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  SELECT * INTO m FROM circle_members WHERE pilgrim_id = p.id;
  IF m.circle_id IS NULL THEN RETURN json_build_object('circle', NULL, 'members', '[]'::json); END IF;
  SELECT * INTO c FROM companion_circles WHERE id = m.circle_id;
  DELETE FROM circle_members WHERE pilgrim_id = p.id;
  IF NOT EXISTS (SELECT 1 FROM circle_members WHERE circle_id = c.id) THEN
    DELETE FROM companion_circles WHERE id = c.id;
  ELSE
    IF m.is_owner THEN
      UPDATE circle_members SET is_owner = TRUE
       WHERE circle_id = c.id AND pilgrim_id = (SELECT pilgrim_id FROM circle_members WHERE circle_id = c.id ORDER BY joined_at, pilgrim_id LIMIT 1);
    END IF;
    PERFORM _notify_circle(c.id, NULL, NULL, 'غادر فرد «' || c.name || '»', u.full_name || ' خرج من دائرتكم');
  END IF;
  RETURN json_build_object('circle', NULL, 'members', '[]'::json);
END $$;

-- إزالة عضو (لمنشئ الدائرة فقط) — مثلاً من انضم بالخطأ
CREATE OR REPLACE FUNCTION app_circle_remove(p_token UUID, p_pilgrim_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; c companion_circles;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  SELECT cc.* INTO c FROM companion_circles cc JOIN circle_members cm ON cm.circle_id = cc.id
   WHERE cm.pilgrim_id = p.id AND cm.is_owner;
  IF c.id IS NULL OR p_pilgrim_id = p.id
     OR NOT EXISTS (SELECT 1 FROM circle_members WHERE circle_id = c.id AND pilgrim_id = p_pilgrim_id) THEN
    RAISE EXCEPTION 'FORBIDDEN' USING HINT = 'هذه الخدمة لمنشئ الدائرة فقط';
  END IF;
  DELETE FROM circle_members WHERE circle_id = c.id AND pilgrim_id = p_pilgrim_id;
  PERFORM _notify((SELECT user_id FROM pilgrims WHERE id = p_pilgrim_id), NULL, NULL,
                  'أُزلت من «' || c.name || '»', 'يمكنك الانضمام لدائرة أخرى برمزها');
  RETURN app_circle_status(p_token);
END $$;

-- =====================================================================
-- 4) خدمة اللوحة: الدوائر التي فيها حاج من أفواج المستخدم، وتباعد أفرادها
-- =====================================================================
CREATE OR REPLACE FUNCTION app_circles_overview(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_groups BIGINT[];
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  v_groups := _visible_groups(u);
  RETURN (SELECT coalesce(json_agg(x ORDER BY x.split DESC, x.spread_m DESC NULLS LAST, x.id), '[]'::json) FROM (
    SELECT c.id, c.name, c.max_distance_m, mem.members, mem.member_count, mem.spread_m,
           coalesce(mem.spread_m > c.max_distance_m, FALSE) AS split
      FROM companion_circles c
      CROSS JOIN LATERAL (
        WITH m AS (
          SELECT o.id, us.full_name, g.name AS group_name, o.group_id, cm.is_owner, lp.latitude, lp.longitude, lp.client_recorded_at AS at
            FROM circle_members cm JOIN pilgrims o ON o.id = cm.pilgrim_id JOIN users us ON us.id = o.user_id
            LEFT JOIN groups g ON g.id = o.group_id
            LEFT JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = o.user_id
                                ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
           WHERE cm.circle_id = c.id),
        nearest AS (   -- لكل فرد: المسافة لأقرب فرد آخر من دائرته
          SELECT a.id, min(_dist_m(a.latitude, a.longitude, b.latitude, b.longitude)) AS d
            FROM m a JOIN m b ON b.id <> a.id GROUP BY a.id)
        SELECT count(*)::int AS member_count,
               max(n.d) AS spread_m,
               json_agg(json_build_object('pilgrim_id', m.id, 'name', m.full_name, 'group_name', m.group_name,
                        'is_owner', m.is_owner, 'at', m.at, 'nearest_m', n.d,
                        'mine', m.group_id = ANY (v_groups)) ORDER BY m.is_owner DESC, m.full_name) AS members
          FROM m LEFT JOIN nearest n ON n.id = m.id) mem
     WHERE EXISTS (SELECT 1 FROM circle_members cm JOIN pilgrims o ON o.id = cm.pilgrim_id
                    WHERE cm.circle_id = c.id AND o.group_id = ANY (v_groups))) x);
END $$;

-- =====================================================================
-- 5) مؤشر خطر الضياع: «بعد الرفيق» صار «بعد الرفيق أو أقرب فرد من الدائرة»
--    (نفس معادلة v3 تماماً، والإضافة في الجزء الأخير فقط)
-- =====================================================================
CREATE OR REPLACE FUNCTION _lost_risk(p_pilgrim BIGINT)
RETURNS JSON LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE p pilgrims; me location_pings; c RECORD; v_dist INT; v_seen INT; v_age INT; v_buddy BIGINT;
        bp location_pings; v_bdist INT; v_circle JSON; v_cdist INT; s NUMERIC := 0;
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
  END IF;
  IF me.id IS NOT NULL AND _circle_of(p.id) IS NOT NULL THEN
    v_circle := _circle_nearest(p.id, 720);
    v_cdist := (v_circle->>'distance_m')::int;
  END IF;
  -- الأقرب بين الرفيق وأفراد الدائرة: إن كان أبعد من ٥٠٠ م يضيف ٥ نقاط (كما في v3)
  IF least(v_bdist, v_cdist) > 500 THEN s := s + 5; END IF;

  RETURN json_build_object('score', round(least(100, s))::int, 'distance_m', v_dist, 'seen_min', v_seen,
    'battery', me.battery_pct, 'age', v_age, 'buddy_id', v_buddy, 'buddy_distance_m', v_bdist,
    'circle_id', _circle_of(p.id), 'circle_nearest_m', v_cdist,
    'lat', me.latitude, 'lng', me.longitude);
END $$;

-- =====================================================================
-- 6) الفحص الدوري: نفس app_smart_tick في v3 + فحص انفصال أفراد الدوائر
-- =====================================================================
CREATE OR REPLACE FUNCTION app_smart_tick(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_split INT := 0; v_heat INT := 0; v_circle INT := 0; rec RECORD; v_alert BIGINT; v_feels INT;
        v_groups BIGINT[]; v_sup BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  v_groups := _visible_groups(u);

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
     WHERE pa.group_id = ANY (v_groups)
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

  -- v4.5 انفصال أفراد الدائرة: فرد أقرب فرد له من دائرته (بمواقع خلال ١٠ دقائق) أبعد من حد الدائرة.
  -- إن تفرّق الجميع (مثل دائرة من شخصين) يُنشأ تنبيه واحد فقط للدائرة على الفرد الأعلى أولوية.
  FOR rec IN
    WITH m AS (
      SELECT cm.circle_id, o.id, o.user_id, o.group_id, o.priority_level, us.full_name, lp.latitude, lp.longitude
        FROM circle_members cm JOIN pilgrims o ON o.id = cm.pilgrim_id JOIN users us ON us.id = o.user_id
        JOIN LATERAL (SELECT * FROM location_pings x WHERE x.user_id = o.user_id AND x.client_recorded_at > now() - interval '10 minutes'
                       ORDER BY x.client_recorded_at DESC LIMIT 1) lp ON TRUE),
    n AS (
      SELECT a.circle_id, a.id, a.user_id, a.group_id, a.priority_level, a.full_name,
             min(_dist_m(a.latitude, a.longitude, b.latitude, b.longitude)) AS d
        FROM m a JOIN m b ON b.circle_id = a.circle_id AND b.id <> a.id
       GROUP BY a.circle_id, a.id, a.user_id, a.group_id, a.priority_level, a.full_name),
    f AS (
      SELECT n.*, c.name AS circle_name, c.max_distance_m,
             count(*) OVER (PARTITION BY n.circle_id) AS tracked,
             count(*) FILTER (WHERE n.d > c.max_distance_m) OVER (PARTITION BY n.circle_id) AS far,
             row_number() OVER (PARTITION BY n.circle_id
               ORDER BY CASE n.priority_level WHEN 'CRITICAL' THEN 0 WHEN 'HIGH' THEN 1 ELSE 2 END, n.id) AS rk
        FROM n JOIN companion_circles c ON c.id = n.circle_id)
    SELECT * FROM f
     WHERE f.d > f.max_distance_m
       AND (f.far < f.tracked OR f.rk = 1)
       AND EXISTS (SELECT 1 FROM circle_members cm JOIN pilgrims o ON o.id = cm.pilgrim_id
                    WHERE cm.circle_id = f.circle_id AND o.group_id = ANY (v_groups))
  LOOP
    IF NOT EXISTS (
         SELECT 1 FROM alerts a JOIN circle_members cm ON cm.pilgrim_id = a.pilgrim_id
          WHERE cm.circle_id = rec.circle_id AND a.type = 'BUDDY_SPLIT' AND a.status <> 'RESOLVED'
            AND a.created_at > now() - interval '30 minutes'
            AND (a.pilgrim_id = rec.id OR rec.far = rec.tracked)) THEN
      INSERT INTO alerts (pilgrim_id, type, severity, note)
      VALUES (rec.id, 'BUDDY_SPLIT', _severity(CASE WHEN rec.d > 500 THEN 'MEDIUM' ELSE 'LOW' END::alert_severity, rec.priority_level),
              CASE WHEN rec.far = rec.tracked THEN 'تفرّق أفراد «' || rec.circle_name || '» — أقرب مسافة بينهم ' || rec.d || ' م'
                   ELSE 'ابتعد عن «' || rec.circle_name || '» — أقرب فرد على بعد ' || rec.d || ' م' END)
      RETURNING id INTO v_alert;
      PERFORM _notify(rec.user_id, v_alert, NULL, 'ابتعدت عن «' || rec.circle_name || '»',
                      'أقرب فرد منك على بعد ' || rec.d || ' م — افتح «عائلتي ورفقتي» لترى الاتجاه، أو توجه لأقرب نقطة لقاء');
      PERFORM _notify_circle(rec.circle_id, rec.id, v_alert, rec.full_name || ' ابتعد عن «' || rec.circle_name || '»',
                             'المسافة ' || rec.d || ' م — افتح «عائلتي ورفقتي» لترى الاتجاه');
      v_sup := _group_supervisor_user(rec.group_id);
      IF rec.d > 500 AND v_sup IS NOT NULL THEN
        PERFORM _notify(v_sup, v_alert, NULL, 'حاج ابتعد عن عائلته/رفقته', rec.full_name || ' — ' || rec.d || ' م عن أقرب فرد من «' || rec.circle_name || '»');
      END IF;
      v_circle := v_circle + 1;
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
     WHERE pp.group_id = ANY (v_groups)
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

  RETURN json_build_object('buddy_split_alerts', v_split, 'circle_split_alerts', v_circle, 'heat_alerts', v_heat);
END $$;

-- =====================================================================
-- 7) SOS و«أنا تائه»: إشعار أفراد دائرة الحاج (Trigger بعد إنشاء التنبيه)
-- =====================================================================
CREATE OR REPLACE FUNCTION trg_alert_notify_circle()
RETURNS TRIGGER LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_circle BIGINT; v_name TEXT;
BEGIN
  IF NEW.type IN ('SOS', 'LOST') THEN
    v_circle := _circle_of(NEW.pilgrim_id);
    IF v_circle IS NOT NULL THEN
      SELECT us.full_name INTO v_name FROM pilgrims p JOIN users us ON us.id = p.user_id WHERE p.id = NEW.pilgrim_id;
      PERFORM _notify_circle(v_circle, NEW.pilgrim_id, NEW.id,
        CASE WHEN NEW.type = 'SOS' THEN v_name || ' من رفقتك يطلب مساعدة' ELSE v_name || ' من رفقتك تائه' END,
        'افتح «عائلتي ورفقتي» لترى مسافته واتجاهه، واتصل به أو بالمشرف');
    END IF;
  END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_alert_notify_circle ON alerts;
CREATE TRIGGER trg_alert_notify_circle AFTER INSERT ON alerts
  FOR EACH ROW EXECUTE FUNCTION trg_alert_notify_circle();

-- =====================================================================
-- 8) الصلاحيات (نفس نمط v2/v3): لا قراءة مباشرة للجدولين، والدخول عبر دوال app_* فقط
-- =====================================================================
DO $$
DECLARE t TEXT; f RECORD;
BEGIN
  FOREACH t IN ARRAY ARRAY['companion_circles','circle_members'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('_new_circle_code','_circle_of','_circle_nearest','_notify_circle',
              '_lost_risk','trg_alert_notify_circle','app_circle_status','app_circle_create','app_circle_join',
              'app_circle_leave','app_circle_remove','app_circles_overview','app_smart_tick') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    IF f.proname LIKE 'app\_%' THEN EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig); END IF;
  END LOOP;
END $$;

-- =====================================================================
-- 9) بيانات العرض: دائرة واحدة لحساب الحاج التجريبي 1030303030 (تُضاف مرة واحدة فقط)
--    محمد أحمد وبودي سانتوسو من الفوج الأول، وفيصل عمر من الفوج الثاني — لتظهر فكرة الدائرة بين فوجين
-- =====================================================================
DO $$
DECLARE v_owner BIGINT; v_camp BIGINT; v_circle BIGINT;
BEGIN
  SELECT p.id, p.campaign_id INTO v_owner, v_camp FROM pilgrims p JOIN users u ON u.id = p.user_id WHERE u.national_id = '1030303030';
  IF v_owner IS NULL OR EXISTS (SELECT 1 FROM companion_circles) THEN RETURN; END IF;
  INSERT INTO companion_circles (campaign_id, name, join_code, max_distance_m, created_by)
  VALUES (v_camp, 'عائلة محمد أحمد', _new_circle_code(), 200, (SELECT user_id FROM pilgrims WHERE id = v_owner))
  RETURNING id INTO v_circle;
  INSERT INTO circle_members (circle_id, pilgrim_id, is_owner) VALUES (v_circle, v_owner, TRUE);
  INSERT INTO circle_members (circle_id, pilgrim_id)
  SELECT v_circle, p.id FROM pilgrims p JOIN users u ON u.id = p.user_id
   WHERE u.national_id IN ('1030303033', '2040404040') AND p.campaign_id = v_camp
  ON CONFLICT DO NOTHING;
END $$;

-- تحقق: يجب أن يظهر 40 جدولاً و82 دالة app_* (76 + 6 جديدة)
SELECT (SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE') AS tables_count,
       (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.proname LIKE 'app\_%') AS app_functions;
