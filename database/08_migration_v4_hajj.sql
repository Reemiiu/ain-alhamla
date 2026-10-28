-- =====================================================================
-- عين الحملة — ترقية v4: مميزات الحج
-- يُشغَّل بعد migration_v3_features.sql. آمن لإعادة التشغيل.
-- Supabase → SQL Editor → الصقي الملف كاملاً → Run
-- =====================================================================
-- ما يضيفه v4 (13 جدولاً → المجموع 38):
--  الحدود الشرعية : sacred_sites (+ دوال داخل/خارج الحد، والمبيت بمنى)
--  الصحة          : medications, medication_doses, wellness_checks (+ عمود allergies)
--  الأهل والرسائل : family_links, voice_messages, voice_message_translations, voice_message_receipts
--  التشغيل        : lost_items, prep_tasks, prep_progress
--  تطبيق الحاج    : ritual_counters (الطواف/السعي/الجمرات), ritual_guides (دليل المنسك بعدة لغات)
--  تنبيهات جديدة  : OUTSIDE_SITE, MISSED_DOSE, NO_MOVEMENT
-- مواقيت الصلاة والقبلة تُحسب في التطبيق من موقع الحاج، ولا تحتاج جدولًا.
-- =====================================================================

BEGIN;
ALTER TYPE alert_type ADD VALUE IF NOT EXISTS 'OUTSIDE_SITE';
ALTER TYPE alert_type ADD VALUE IF NOT EXISTS 'MISSED_DOSE';
ALTER TYPE alert_type ADD VALUE IF NOT EXISTS 'NO_MOVEMENT';
COMMIT;

DO $$ BEGIN CREATE TYPE site_key        AS ENUM ('ARAFAH', 'MUZDALIFAH', 'MINA');                         EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE dose_status     AS ENUM ('DUE', 'TAKEN', 'MISSED', 'SKIPPED');                   EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE wellness_status AS ENUM ('SENT', 'ANSWERED_OK', 'HELP', 'ESCALATED', 'SUPPRESSED'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE lost_status     AS ENUM ('OPEN', 'FOUND', 'RETURNED');                           EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE lost_category   AS ENUM ('PASSPORT', 'PHONE', 'GLASSES', 'BAG', 'MONEY', 'OTHER'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN CREATE TYPE counter_kind    AS ENUM ('TAWAF', 'SAI', 'JAMRAH_SUGHRA', 'JAMRAH_WUSTA', 'JAMRAH_AQABA'); EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE pilgrims ADD COLUMN IF NOT EXISTS allergies TEXT;

-- =====================================================================
-- 1) الحدود الشرعية
-- =====================================================================
-- boundary: مصفوفة نقاط [[lat, lng], ...] بترتيب الحد. campaign_id = NULL يعني حدًا عامًا لكل الحملات
CREATE TABLE IF NOT EXISTS sacred_sites (
    id          BIGSERIAL PRIMARY KEY,
    campaign_id BIGINT       REFERENCES campaigns(id) ON DELETE CASCADE,
    key         site_key     NOT NULL,
    name        VARCHAR(100) NOT NULL,
    boundary    JSONB        NOT NULL CHECK (jsonb_typeof(boundary) = 'array' AND jsonb_array_length(boundary) >= 3),
    is_active   BOOLEAN      NOT NULL DEFAULT TRUE,
    note        TEXT
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_sacred_site_key ON sacred_sites (coalesce(campaign_id, 0), key) WHERE is_active;

-- نقطة داخل مضلّع (ray casting)، x = خط الطول، y = خط العرض
CREATE OR REPLACE FUNCTION _point_in_site(p_lat NUMERIC, p_lng NUMERIC, p_site BIGINT)
RETURNS BOOLEAN LANGUAGE plpgsql STABLE AS $$
DECLARE b JSONB; n INT; i INT; j INT; yi NUMERIC; xi NUMERIC; yj NUMERIC; xj NUMERIC; c BOOLEAN := FALSE;
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN RETURN NULL; END IF;
  SELECT boundary INTO b FROM sacred_sites WHERE id = p_site;
  n := jsonb_array_length(b); j := n - 1;
  FOR i IN 0 .. n - 1 LOOP
    yi := (b->i->>0)::numeric; xi := (b->i->>1)::numeric;
    yj := (b->j->>0)::numeric; xj := (b->j->>1)::numeric;
    IF ((yi > p_lat) <> (yj > p_lat)) AND (p_lng < (xj - xi) * (p_lat - yi) / (yj - yi) + xi) THEN c := NOT c; END IF;
    j := i;
  END LOOP;
  RETURN c;
END $$;

-- أقرب مسافة (متر) من نقطة إلى حد المشعر، مع إحداثيات أقرب نقطة على الحد لتوجيه الحاج
CREATE OR REPLACE FUNCTION _site_edge(p_lat NUMERIC, p_lng NUMERIC, p_site BIGINT)
RETURNS TABLE (distance_m INT, edge_lat NUMERIC, edge_lng NUMERIC) LANGUAGE plpgsql STABLE AS $$
DECLARE b JSONB; n INT; i INT; kx FLOAT8; ky FLOAT8 := 110540;
        x1 FLOAT8; y1 FLOAT8; x2 FLOAT8; y2 FLOAT8; t FLOAT8; px FLOAT8; py FLOAT8; d FLOAT8; best FLOAT8 := NULL; bpx FLOAT8; bpy FLOAT8;
BEGIN
  SELECT boundary INTO b FROM sacred_sites WHERE id = p_site;
  n := jsonb_array_length(b); kx := 111320 * cos(radians(p_lat::float8));
  FOR i IN 0 .. n - 1 LOOP
    -- إسقاط مستوٍ حول نقطة الحاج (دقيق بما يكفي لمسافات المشاعر)
    x1 := ((b->i->>1)::float8 - p_lng::float8) * kx;             y1 := ((b->i->>0)::float8 - p_lat::float8) * ky;
    x2 := ((b->((i + 1) % n)->>1)::float8 - p_lng::float8) * kx; y2 := ((b->((i + 1) % n)->>0)::float8 - p_lat::float8) * ky;
    t := greatest(0, least(1, ((0 - x1) * (x2 - x1) + (0 - y1) * (y2 - y1)) / nullif((x2 - x1) ^ 2 + (y2 - y1) ^ 2, 0)));
    px := x1 + coalesce(t, 0) * (x2 - x1); py := y1 + coalesce(t, 0) * (y2 - y1);
    d := sqrt(px ^ 2 + py ^ 2);
    IF best IS NULL OR d < best THEN best := d; bpx := px; bpy := py; END IF;
  END LOOP;
  distance_m := round(best)::int; edge_lat := p_lat + (bpy / ky)::numeric; edge_lng := p_lng + (bpx / kx)::numeric;
  RETURN NEXT;
END $$;

CREATE OR REPLACE FUNCTION _active_site(p_campaign BIGINT, p_key site_key)
RETURNS BIGINT LANGUAGE sql STABLE AS $$
  SELECT id FROM sacred_sites WHERE key = p_key AND is_active AND (campaign_id = p_campaign OR campaign_id IS NULL)
   ORDER BY campaign_id NULLS LAST LIMIT 1
$$;

-- من داخل الحد ومن خارجه الآن (آخر نبضة خلال ٣٠ دقيقة)
CREATE OR REPLACE FUNCTION app_site_check(p_token UUID, p_key site_key)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  RETURN (SELECT coalesce(json_agg(x ORDER BY x.inside, x.distance_m DESC NULLS LAST), '[]'::json) FROM (
    SELECT pp.id, us.full_name, pp.group_id, pp.preferred_language, lp.latitude AS lat, lp.longitude AS lng, lp.client_recorded_at AS at,
           _point_in_site(lp.latitude, lp.longitude, s.site) AS inside,
           CASE WHEN NOT _point_in_site(lp.latitude, lp.longitude, s.site) THEN e.distance_m END AS distance_m,
           CASE WHEN NOT _point_in_site(lp.latitude, lp.longitude, s.site) THEN e.edge_lat END AS edge_lat,
           CASE WHEN NOT _point_in_site(lp.latitude, lp.longitude, s.site) THEN e.edge_lng END AS edge_lng
      FROM pilgrims pp JOIN users us ON us.id = pp.user_id
      CROSS JOIN LATERAL (SELECT _active_site(pp.campaign_id, p_key) AS site) s
      JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = pp.user_id AND l.client_recorded_at > now() - interval '30 minutes'
                     ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
      CROSS JOIN LATERAL _site_edge(lp.latitude, lp.longitude, s.site) e
     WHERE pp.group_id = ANY (_visible_groups(u)) AND s.site IS NOT NULL) x);
END $$;

-- فحص دوري وقت المنسك (مثل يوم عرفة): تنبيه لكل حاج خارج الحد + إشعار له بالاتجاه
CREATE OR REPLACE FUNCTION app_site_tick(p_token UUID, p_key site_key)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; rec RECORD; v_alert BIGINT; v_n INT := 0; v_sup BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  FOR rec IN SELECT x.*, pp.user_id, pp.priority_level FROM json_to_recordset(app_site_check(p_token, p_key))
               AS x(id BIGINT, full_name TEXT, group_id BIGINT, lat NUMERIC, lng NUMERIC, inside BOOLEAN, distance_m INT)
               JOIN pilgrims pp ON pp.id = x.id
              WHERE NOT x.inside LOOP
    CONTINUE WHEN EXISTS (SELECT 1 FROM alerts WHERE pilgrim_id = rec.id AND type = 'OUTSIDE_SITE' AND status <> 'RESOLVED'
                            AND created_at > now() - interval '20 minutes');
    INSERT INTO alerts (pilgrim_id, type, severity, note)
    VALUES (rec.id, 'OUTSIDE_SITE', _severity(CASE WHEN p_key = 'ARAFAH' THEN 'CRITICAL' ELSE 'MEDIUM' END::alert_severity, rec.priority_level),
            'خارج حدود ' || (SELECT name FROM sacred_sites WHERE id = _active_site((SELECT campaign_id FROM pilgrims WHERE id = rec.id), p_key))
            || ' بمسافة ' || rec.distance_m || ' م')
    RETURNING id INTO v_alert;
    PERFORM _notify(rec.user_id, v_alert, NULL, 'أنت خارج حدود المشعر', 'تحرك ' || rec.distance_m || ' م نحو الداخل، واتبع السهم في التطبيق');
    v_sup := _group_supervisor_user(rec.group_id);
    IF v_sup IS NOT NULL THEN PERFORM _notify(v_sup, v_alert, NULL, 'حاج خارج الحدود', rec.full_name || ' على بعد ' || rec.distance_m || ' م خارج الحد'); END IF;
    v_n := v_n + 1;
  END LOOP;
  RETURN json_build_object('outside_alerts', v_n);
END $$;

-- المبيت: ساعات وجود كل حاج داخل حد المشعر بين وقتين (المغرب → الفجر).
-- كل نبضة داخل الحد تُحسب حتى النبضة التالية بحد أقصى ١٥ دقيقة (انقطاع الإشارة لا يُحسب مبيتًا)
CREATE OR REPLACE FUNCTION app_overnight_report(p_token UUID, p_from TIMESTAMPTZ, p_to TIMESTAMPTZ, p_key site_key DEFAULT 'MINA')
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_half NUMERIC := extract(epoch FROM p_to - p_from) / 3600 / 2;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  RETURN json_build_object('night_hours', round(v_half * 2, 2), 'required_hours', round(v_half, 2), 'pilgrims', (
    SELECT coalesce(json_agg(json_build_object('id', id, 'name', full_name, 'hours', round(h, 2), 'complete', h > v_half) ORDER BY h), '[]'::json)
      FROM (SELECT pp.id, us.full_name,
                   coalesce((SELECT sum(least(extract(epoch FROM coalesce(nxt, p_to) - client_recorded_at), 900)) / 3600
                               FROM (SELECT l.client_recorded_at, l.latitude, l.longitude,
                                            lead(l.client_recorded_at) OVER (ORDER BY l.client_recorded_at) AS nxt
                                       FROM location_pings l WHERE l.user_id = pp.user_id AND l.client_recorded_at BETWEEN p_from AND p_to) w
                              WHERE _point_in_site(w.latitude, w.longitude, _active_site(pp.campaign_id, p_key))), 0) AS h
              FROM pilgrims pp JOIN users us ON us.id = pp.user_id
             WHERE pp.group_id = ANY (_visible_groups(u))) t));
END $$;

-- =====================================================================
-- 2) الصحة: الأدوية والجرعات و"أنت بخير؟"
-- =====================================================================
CREATE TABLE IF NOT EXISTS medications (
    id             BIGSERIAL PRIMARY KEY,
    pilgrim_id     BIGINT       NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
    name           VARCHAR(120) NOT NULL,
    condition      VARCHAR(80),
    schedule_times TIME[]       NOT NULL DEFAULT '{}',   -- فارغة = عند الحاجة
    needs_fridge   BOOLEAN      NOT NULL DEFAULT FALSE,
    is_active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at     TIMESTAMPTZ  NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS medication_doses (
    id            BIGSERIAL PRIMARY KEY,
    medication_id BIGINT      NOT NULL REFERENCES medications(id) ON DELETE CASCADE,
    scheduled_at  TIMESTAMPTZ NOT NULL,
    status        dose_status NOT NULL DEFAULT 'DUE',
    taken_at      TIMESTAMPTZ,
    confirmed_by  BIGINT      REFERENCES users(id),     -- الحاج نفسه أو المشرف
    CONSTRAINT uq_dose UNIQUE (medication_id, scheduled_at)
);
CREATE TABLE IF NOT EXISTS wellness_checks (
    id            BIGSERIAL PRIMARY KEY,
    pilgrim_id    BIGINT          NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
    still_minutes INT             NOT NULL CHECK (still_minutes >= 0),
    latitude      NUMERIC(9,6),
    longitude     NUMERIC(9,6),
    status        wellness_status NOT NULL DEFAULT 'SENT',
    sent_at       TIMESTAMPTZ     NOT NULL DEFAULT now(),
    answered_at   TIMESTAMPTZ,
    alert_id      BIGINT          REFERENCES alerts(id) ON DELETE SET NULL
);
CREATE INDEX IF NOT EXISTS idx_doses_due      ON medication_doses (scheduled_at) WHERE status = 'DUE';
CREATE INDEX IF NOT EXISTS idx_wellness_open  ON wellness_checks (sent_at) WHERE status = 'SENT';
CREATE INDEX IF NOT EXISTS idx_meds_pilgrim   ON medications (pilgrim_id) WHERE is_active;

-- يولّد جرعات يوم كامل لكل الأدوية المجدولة (بتوقيت مكة)
CREATE OR REPLACE FUNCTION app_generate_doses(p_token UUID, p_day DATE DEFAULT (now() AT TIME ZONE 'Asia/Riyadh')::date)
RETURNS INT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_n INT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  INSERT INTO medication_doses (medication_id, scheduled_at)
  SELECT m.id, (p_day + t) AT TIME ZONE 'Asia/Riyadh'
    FROM medications m JOIN pilgrims pp ON pp.id = m.pilgrim_id CROSS JOIN LATERAL unnest(m.schedule_times) t
   WHERE m.is_active AND pp.group_id = ANY (_visible_groups(u))
  ON CONFLICT (medication_id, scheduled_at) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN v_n;
END $$;

-- تأكيد أخذ الجرعة (من الحاج أو مشرفه)
CREATE OR REPLACE FUNCTION app_take_dose(p_token UUID, p_dose_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_pilgrim pilgrims;
BEGIN
  u := _auth(p_token);
  SELECT pp.* INTO v_pilgrim FROM medication_doses d JOIN medications m ON m.id = d.medication_id JOIN pilgrims pp ON pp.id = m.pilgrim_id
   WHERE d.id = p_dose_id;
  IF v_pilgrim.id IS NULL OR NOT (v_pilgrim.user_id = u.id OR _can_manage_group(u, v_pilgrim.group_id)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  UPDATE medication_doses SET status = 'TAKEN', taken_at = now(), confirmed_by = u.id WHERE id = p_dose_id;
  UPDATE alerts SET status = 'RESOLVED', resolved_at = now(), resolved_by = u.id
   WHERE pilgrim_id = v_pilgrim.id AND type = 'MISSED_DOSE' AND status <> 'RESOLVED' AND note LIKE '%#' || p_dose_id;
END $$;

-- جرعات اليوم للحاج نفسه (تطبيق الحاج)
CREATE OR REPLACE FUNCTION app_my_doses(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  RETURN (SELECT coalesce(json_agg(json_build_object('dose_id', d.id, 'name', m.name, 'condition', m.condition,
            'scheduled_at', d.scheduled_at, 'status', d.status, 'needs_fridge', m.needs_fridge) ORDER BY d.scheduled_at), '[]'::json)
            FROM medication_doses d JOIN medications m ON m.id = d.medication_id JOIN pilgrims pp ON pp.id = m.pilgrim_id
           WHERE pp.user_id = u.id AND (d.scheduled_at AT TIME ZONE 'Asia/Riyadh')::date = (now() AT TIME ZONE 'Asia/Riyadh')::date);
END $$;

-- فحص "أنت بخير؟": جوال الحاج يبلّغ عن توقف الحركة. داخل المخيم = لا سؤال (SUPPRESSED)
CREATE OR REPLACE FUNCTION app_wellness_report(p_token UUID, p_still_minutes INT, p_lat NUMERIC, p_lng NUMERIC)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_in_camp BOOLEAN; v_id BIGINT; v_status wellness_status;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  SELECT EXISTS (SELECT 1 FROM locations l WHERE l.campaign_id = p.campaign_id AND l.type = 'SAFE_ZONE'
                  AND _dist_m(p_lat, p_lng, l.latitude, l.longitude) <= l.radius_meters) INTO v_in_camp;
  IF EXISTS (SELECT 1 FROM wellness_checks WHERE pilgrim_id = p.id AND status = 'SENT') THEN
    RETURN json_build_object('status', 'ALREADY_ASKED');
  END IF;
  v_status := CASE WHEN v_in_camp OR p_still_minutes < 25 THEN 'SUPPRESSED' ELSE 'SENT' END;
  INSERT INTO wellness_checks (pilgrim_id, still_minutes, latitude, longitude, status)
  VALUES (p.id, p_still_minutes, p_lat, p_lng, v_status) RETURNING id INTO v_id;
  RETURN json_build_object('check_id', v_id, 'status', v_status, 'ask', v_status = 'SENT', 'timeout_seconds', 60);
END $$;

CREATE OR REPLACE FUNCTION app_wellness_answer(p_token UUID, p_check_id BIGINT, p_ok BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; w wellness_checks; p pilgrims; v_alert BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT w2.* INTO w FROM wellness_checks w2 JOIN pilgrims pp ON pp.id = w2.pilgrim_id WHERE w2.id = p_check_id AND pp.user_id = u.id;
  IF w.id IS NULL THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT * INTO p FROM pilgrims WHERE id = w.pilgrim_id;
  IF p_ok THEN
    UPDATE wellness_checks SET status = 'ANSWERED_OK', answered_at = now() WHERE id = w.id;
  ELSE
    INSERT INTO alerts (pilgrim_id, type, severity, note) VALUES (p.id, 'NO_MOVEMENT', 'CRITICAL', 'الحاج طلب مساعدة من فحص "أنت بخير؟"')
    RETURNING id INTO v_alert;
    UPDATE wellness_checks SET status = 'HELP', answered_at = now(), alert_id = v_alert WHERE id = w.id;
    IF _group_supervisor_user(p.group_id) IS NOT NULL THEN
      PERFORM _notify(_group_supervisor_user(p.group_id), v_alert, NULL, 'حاج يطلب مساعدة', u.full_name || ' ضغط «أحتاج مساعدة»');
    END IF;
  END IF;
END $$;

-- فحص دوري: جرعات فائتة (بعد ٣٠ دقيقة) + أسئلة "أنت بخير؟" بلا رد (بعد ٦٠ ثانية)
CREATE OR REPLACE FUNCTION app_health_tick(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; rec RECORD; v_alert BIGINT; v_missed INT := 0; v_esc INT := 0;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  FOR rec IN SELECT d.id, m.name, pp.id AS pid, pp.group_id, pp.priority_level, us.full_name
               FROM medication_doses d JOIN medications m ON m.id = d.medication_id JOIN pilgrims pp ON pp.id = m.pilgrim_id
               JOIN users us ON us.id = pp.user_id
              WHERE d.status = 'DUE' AND d.scheduled_at < now() - interval '30 minutes' AND pp.group_id = ANY (_visible_groups(u)) LOOP
    UPDATE medication_doses SET status = 'MISSED' WHERE id = rec.id;
    INSERT INTO alerts (pilgrim_id, type, severity, note)
    VALUES (rec.pid, 'MISSED_DOSE', _severity('LOW', rec.priority_level), 'لم يؤكد جرعة ' || rec.name || ' #' || rec.id)
    RETURNING id INTO v_alert;
    IF _group_supervisor_user(rec.group_id) IS NOT NULL THEN
      PERFORM _notify(_group_supervisor_user(rec.group_id), v_alert, NULL, 'جرعة فائتة', rec.full_name || ': ' || rec.name);
    END IF;
    v_missed := v_missed + 1;
  END LOOP;

  FOR rec IN SELECT w.id, w.pilgrim_id, w.still_minutes, pp.group_id, us.full_name
               FROM wellness_checks w JOIN pilgrims pp ON pp.id = w.pilgrim_id JOIN users us ON us.id = pp.user_id
              WHERE w.status = 'SENT' AND w.sent_at < now() - interval '60 seconds' AND pp.group_id = ANY (_visible_groups(u)) LOOP
    INSERT INTO alerts (pilgrim_id, type, severity, note)
    VALUES (rec.pilgrim_id, 'NO_MOVEMENT', 'CRITICAL', 'لا حركة منذ ' || rec.still_minutes || ' دقيقة ولم يرد على "أنت بخير؟"')
    RETURNING id INTO v_alert;
    UPDATE wellness_checks SET status = 'ESCALATED', alert_id = v_alert WHERE id = rec.id;
    IF _group_supervisor_user(rec.group_id) IS NOT NULL THEN
      PERFORM _notify(_group_supervisor_user(rec.group_id), v_alert, NULL, 'لم يرد: أنت بخير؟', rec.full_name || ' بلا حركة منذ ' || rec.still_minutes || ' دقيقة');
    END IF;
    v_esc := v_esc + 1;
  END LOOP;
  RETURN json_build_object('missed_doses', v_missed, 'escalated_checks', v_esc);
END $$;

-- بطاقة المسعف: أقل قدر من البيانات الطبية اللازمة للإسعاف
CREATE OR REPLACE FUNCTION app_medic_card(p_token UUID, p_pilgrim_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims;
BEGIN
  u := _auth(p_token);
  SELECT * INTO p FROM pilgrims WHERE id = p_pilgrim_id;
  IF p.id IS NULL OR NOT (p.user_id = u.id OR _can_manage_group(u, p.group_id)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  RETURN json_build_object('name', (SELECT full_name FROM users WHERE id = p.user_id), 'blood_type', p.blood_type,
    'age', date_part('year', age(p.birth_date))::int, 'medical_notes', p.medical_notes, 'allergies', p.allergies,
    'medications', (SELECT coalesce(json_agg(name ORDER BY name), '[]'::json) FROM medications WHERE pilgrim_id = p.id AND is_active),
    'emergency', (SELECT json_build_object('name', name, 'relation', relation, 'phone', phone) FROM emergency_contacts
                   WHERE pilgrim_id = p.id ORDER BY is_primary DESC LIMIT 1));
END $$;

-- =====================================================================
-- 3) الأهل والرسائل الصوتية
-- =====================================================================
CREATE TABLE IF NOT EXISTS family_links (
    id          BIGSERIAL PRIMARY KEY,
    pilgrim_id  BIGINT      NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
    contact_id  BIGINT      REFERENCES emergency_contacts(id) ON DELETE SET NULL,
    token       UUID        NOT NULL UNIQUE DEFAULT gen_random_uuid(),
    expires_at  TIMESTAMPTZ NOT NULL,
    is_active   BOOLEAN     NOT NULL DEFAULT TRUE,
    views       INT         NOT NULL DEFAULT 0,
    last_viewed TIMESTAMPTZ,
    created_by  BIGINT      REFERENCES users(id),
    created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS voice_messages (
    id            BIGSERIAL PRIMARY KEY,
    broadcast_id  BIGINT      REFERENCES broadcasts(id) ON DELETE CASCADE,
    sender_id     BIGINT      NOT NULL REFERENCES users(id),
    group_id      BIGINT      REFERENCES groups(id) ON DELETE CASCADE,   -- NULL = كل الحملة
    audio_url     TEXT,                                                  -- ملف الصوت في Supabase Storage
    duration_sec  SMALLINT    CHECK (duration_sec BETWEEN 1 AND 300),
    transcript_ar TEXT        NOT NULL,
    is_urgent     BOOLEAN     NOT NULL DEFAULT FALSE,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
-- الترجمات تُولَّد في الخادم (Edge Function تستدعي خدمة ترجمة) ثم تُحفظ هنا
CREATE TABLE IF NOT EXISTS voice_message_translations (
    voice_id BIGINT     NOT NULL REFERENCES voice_messages(id) ON DELETE CASCADE,
    lang     VARCHAR(5) NOT NULL CHECK (lang IN ('en','ur','id','tr','fr')),
    text     TEXT       NOT NULL,
    PRIMARY KEY (voice_id, lang)
);
CREATE TABLE IF NOT EXISTS voice_message_receipts (
    voice_id   BIGINT      NOT NULL REFERENCES voice_messages(id) ON DELETE CASCADE,
    pilgrim_id BIGINT      NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
    heard_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (voice_id, pilgrim_id)
);
CREATE INDEX IF NOT EXISTS idx_family_links_pilgrim ON family_links (pilgrim_id);

CREATE OR REPLACE FUNCTION app_create_family_link(p_token UUID, p_pilgrim_id BIGINT, p_contact_id BIGINT, p_hours INT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_exp TIMESTAMPTZ; l family_links;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE id = p_pilgrim_id;
  IF p.id IS NULL OR NOT _can_manage_group(u, p.group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_contact_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM emergency_contacts WHERE id = p_contact_id AND pilgrim_id = p.id) THEN
    RAISE EXCEPTION 'CONTACT_NOT_FOUND';
  END IF;
  -- الافتراضي: حتى نهاية الحملة
  v_exp := coalesce(now() + make_interval(hours => p_hours),
                    (SELECT greatest((end_date + 1)::timestamptz, now() + interval '1 day') FROM campaigns WHERE id = p.campaign_id),
                    now() + interval '7 days');
  INSERT INTO family_links (pilgrim_id, contact_id, expires_at, created_by) VALUES (p.id, p_contact_id, v_exp, u.id) RETURNING * INTO l;
  PERFORM _log(u.id, 'FAMILY_LINK', 'family_link', l.id, p.group_id, 'أنشأ رابط متابعة للأهل');
  RETURN json_build_object('id', l.id, 'token', l.token, 'expires_at', l.expires_at);
END $$;

CREATE OR REPLACE FUNCTION app_set_family_link(p_token UUID, p_link_id BIGINT, p_active BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_group BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN']::user_role[]);
  SELECT pp.group_id INTO v_group FROM family_links f JOIN pilgrims pp ON pp.id = f.pilgrim_id WHERE f.id = p_link_id;
  IF NOT _can_manage_group(u, v_group) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  UPDATE family_links SET is_active = p_active WHERE id = p_link_id;
END $$;

-- صفحة الأهل (بدون تسجيل دخول): بالرمز فقط، ولا تُرجع أي إحداثيات
CREATE OR REPLACE FUNCTION family_view(p_link UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE l family_links; p pilgrims; v_last TIMESTAMPTZ; v_open BOOLEAN;
BEGIN
  SELECT * INTO l FROM family_links WHERE token = p_link;
  IF l.id IS NULL OR NOT l.is_active OR l.expires_at < now() THEN RETURN json_build_object('valid', false); END IF;
  UPDATE family_links SET views = views + 1, last_viewed = now() WHERE id = l.id;
  SELECT * INTO p FROM pilgrims WHERE id = l.pilgrim_id;
  SELECT max(client_recorded_at) INTO v_last FROM location_pings WHERE user_id = p.user_id;
  v_open := EXISTS (SELECT 1 FROM alerts WHERE pilgrim_id = p.id AND status <> 'RESOLVED'
                     AND type IN ('SOS','LOST','GEOFENCE_BREACH','OUTSIDE_SITE','NO_MOVEMENT'));
  RETURN json_build_object('valid', true,
    'name', (SELECT full_name FROM users WHERE id = p.user_id),
    'status', CASE WHEN v_open THEN 'SUPERVISOR_FOLLOWING' ELSE 'OK' END,   -- لا تفاصيل التنبيه للأهل
    'last_update', v_last,
    'group', (SELECT name FROM groups WHERE id = p.group_id),
    'rituals', (SELECT coalesce(json_agg(json_build_object('name', name, 'status', status) ORDER BY seq), '[]'::json)
                  FROM rituals WHERE campaign_id = p.campaign_id),
    'message', (SELECT json_build_object('title', title, 'body', body, 'at', created_at) FROM broadcasts
                 WHERE (group_id = p.group_id OR (group_id IS NULL AND campaign_id = p.campaign_id)) AND NOT is_urgent
                 ORDER BY created_at DESC LIMIT 1),
    'expires_at', l.expires_at);
END $$;

-- رسالة صوتية: تُنشئ broadcast عاديًا (فيصل للتطبيق) + الترجمات المرسلة من الخادم
CREATE OR REPLACE FUNCTION app_send_voice(p_token UUID, p_group_id BIGINT, p_transcript TEXT, p_translations JSONB DEFAULT '{}'::jsonb,
    p_audio_url TEXT DEFAULT NULL, p_duration INT DEFAULT NULL, p_urgent BOOLEAN DEFAULT FALSE)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_b JSON; v_id BIGINT; k TEXT; v TEXT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  v_b := app_send_broadcast(p_token, p_group_id, 'رسالة صوتية من ' || u.full_name, btrim(p_transcript), p_urgent);
  INSERT INTO voice_messages (broadcast_id, sender_id, group_id, audio_url, duration_sec, transcript_ar, is_urgent)
  VALUES ((v_b->>'broadcast_id')::bigint, u.id, p_group_id, p_audio_url, p_duration, btrim(p_transcript), coalesce(p_urgent, FALSE))
  RETURNING id INTO v_id;
  FOR k, v IN SELECT * FROM jsonb_each_text(coalesce(p_translations, '{}'::jsonb)) LOOP
    INSERT INTO voice_message_translations (voice_id, lang, text) VALUES (v_id, k, v) ON CONFLICT (voice_id, lang) DO UPDATE SET text = EXCLUDED.text;
  END LOOP;
  RETURN v_id;
END $$;

-- الحاج يسمع الرسالة: تُرجع النص بلغته وتسجل السماع
CREATE OR REPLACE FUNCTION app_voice_heard(p_token UUID, p_voice_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; vm voice_messages;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  SELECT * INTO vm FROM voice_messages WHERE id = p_voice_id AND (group_id = p.group_id OR group_id IS NULL);
  IF vm.id IS NULL THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  INSERT INTO voice_message_receipts (voice_id, pilgrim_id) VALUES (vm.id, p.id) ON CONFLICT DO NOTHING;
  RETURN json_build_object('audio_url', vm.audio_url, 'lang', p.preferred_language,
    'text', coalesce((SELECT text FROM voice_message_translations WHERE voice_id = vm.id AND lang = p.preferred_language), vm.transcript_ar));
END $$;

-- من سمع الرسالة، مقسّمًا حسب اللغة
CREATE OR REPLACE FUNCTION app_voice_status(p_token UUID, p_voice_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; vm voice_messages;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  SELECT * INTO vm FROM voice_messages WHERE id = p_voice_id;
  RETURN (SELECT coalesce(json_object_agg(lang, json_build_object('heard', heard, 'total', total)), '{}'::json) FROM (
    SELECT pp.preferred_language AS lang, count(r.pilgrim_id) AS heard, count(*) AS total
      FROM pilgrims pp LEFT JOIN voice_message_receipts r ON r.pilgrim_id = pp.id AND r.voice_id = vm.id
     WHERE (vm.group_id IS NULL OR pp.group_id = vm.group_id) AND pp.group_id = ANY (_visible_groups(u))
     GROUP BY pp.preferred_language) t);
END $$;

-- =====================================================================
-- 4) التشغيل: المفقودات وتجهيز ما قبل السفر
-- =====================================================================
CREATE TABLE IF NOT EXISTS lost_items (
    id               BIGSERIAL PRIMARY KEY,
    campaign_id      BIGINT        NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    reporter_id      BIGINT        NOT NULL REFERENCES users(id),
    owner_pilgrim_id BIGINT        REFERENCES pilgrims(id) ON DELETE SET NULL,
    category         lost_category NOT NULL DEFAULT 'OTHER',
    description      VARCHAR(300)  NOT NULL,
    last_seen_place  VARCHAR(150),
    status           lost_status   NOT NULL DEFAULT 'OPEN',
    is_urgent        BOOLEAN       NOT NULL DEFAULT FALSE,
    found_by         BIGINT        REFERENCES users(id),
    found_at         TIMESTAMPTZ,
    returned_at      TIMESTAMPTZ,
    created_at       TIMESTAMPTZ   NOT NULL DEFAULT now()
);
CREATE TABLE IF NOT EXISTS prep_tasks (
    id          BIGSERIAL PRIMARY KEY,
    campaign_id BIGINT       NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    key         VARCHAR(30)  NOT NULL,
    name        VARCHAR(150) NOT NULL,
    seq         SMALLINT     NOT NULL DEFAULT 0,
    CONSTRAINT uq_prep_task UNIQUE (campaign_id, key)
);
CREATE TABLE IF NOT EXISTS prep_progress (
    pilgrim_id BIGINT      NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
    task_id    BIGINT      NOT NULL REFERENCES prep_tasks(id) ON DELETE CASCADE,
    done_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    PRIMARY KEY (pilgrim_id, task_id)
);
CREATE INDEX IF NOT EXISTS idx_lost_open ON lost_items (campaign_id, status) WHERE status <> 'RETURNED';

-- بلاغ مفقود من الحاج. جواز السفر = أولوية ويُبلّغ مدير الحملة
CREATE OR REPLACE FUNCTION app_report_lost(p_token UUID, p_category lost_category, p_description TEXT, p_place TEXT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_id BIGINT; rec RECORD;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  INSERT INTO lost_items (campaign_id, reporter_id, owner_pilgrim_id, category, description, last_seen_place, is_urgent)
  VALUES (p.campaign_id, u.id, p.id, p_category, btrim(p_description), nullif(btrim(p_place), ''), p_category = 'PASSPORT')
  RETURNING id INTO v_id;
  FOR rec IN SELECT s.user_id FROM supervisors s WHERE s.campaign_id = p.campaign_id
             UNION SELECT c.admin_id FROM campaigns c WHERE c.id = p.campaign_id AND p_category = 'PASSPORT' AND c.admin_id IS NOT NULL LOOP
    PERFORM _notify(rec.user_id, NULL, NULL, CASE WHEN p_category = 'PASSPORT' THEN 'عاجل: جواز سفر مفقود' ELSE 'بلاغ مفقودات' END,
                    u.full_name || ': ' || btrim(p_description));
  END LOOP;
  RETURN v_id;
END $$;

-- المشرف: تسجيل غرض موجود (جديد أو مطابق لبلاغ قائم)
CREATE OR REPLACE FUNCTION app_report_found(p_token UUID, p_item_id BIGINT DEFAULT NULL, p_description TEXT DEFAULT NULL,
    p_place TEXT DEFAULT NULL, p_owner BIGINT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_id BIGINT; v_owner BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  IF p_item_id IS NOT NULL THEN
    UPDATE lost_items SET status = 'FOUND', found_by = u.id, found_at = now() WHERE id = p_item_id AND status = 'OPEN'
    RETURNING id, owner_pilgrim_id INTO v_id, v_owner;
  ELSE
    INSERT INTO lost_items (campaign_id, reporter_id, owner_pilgrim_id, description, last_seen_place, status, found_by, found_at)
    VALUES (coalesce((SELECT campaign_id FROM supervisors WHERE user_id = u.id), (SELECT campaign_id FROM pilgrims WHERE id = p_owner),
                    (SELECT id FROM campaigns ORDER BY (status = 'ACTIVE') DESC, id LIMIT 1)), u.id, p_owner, btrim(p_description), p_place, 'FOUND', u.id, now())
    RETURNING id, owner_pilgrim_id INTO v_id, v_owner;
  END IF;
  IF v_owner IS NOT NULL THEN
    PERFORM _notify((SELECT user_id FROM pilgrims WHERE id = v_owner), NULL, NULL, 'وُجد غرضك', 'تواصل مع ' || u.full_name || ' لاستلامه');
  END IF;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION app_return_lost(p_token UUID, p_item_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  UPDATE lost_items SET status = 'RETURNED', returned_at = now() WHERE id = p_item_id AND status = 'FOUND';
  IF NOT FOUND THEN RAISE EXCEPTION 'NOT_FOUND_YET' USING HINT = 'سجّلي الغرض كموجود أولًا'; END IF;
END $$;

-- الحاج يحدّث مهمة تجهيز
CREATE OR REPLACE FUNCTION app_prep_toggle(p_token UUID, p_task_id BIGINT, p_done BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_pid BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT id INTO v_pid FROM pilgrims WHERE user_id = u.id;
  IF p_done THEN INSERT INTO prep_progress (pilgrim_id, task_id) VALUES (v_pid, p_task_id) ON CONFLICT DO NOTHING;
  ELSE DELETE FROM prep_progress WHERE pilgrim_id = v_pid AND task_id = p_task_id; END IF;
END $$;

-- مصفوفة الجاهزية للمشرف
CREATE OR REPLACE FUNCTION app_prep_matrix(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  RETURN json_build_object(
    'tasks', (SELECT coalesce(json_agg(json_build_object('id', t.id, 'name', t.name) ORDER BY t.seq), '[]'::json)
                FROM prep_tasks t WHERE t.campaign_id IN (SELECT campaign_id FROM groups WHERE id = ANY (_visible_groups(u)))),
    'pilgrims', (SELECT coalesce(json_agg(json_build_object('id', pp.id, 'name', us.full_name,
                   'done', (SELECT coalesce(json_agg(pr.task_id), '[]'::json) FROM prep_progress pr WHERE pr.pilgrim_id = pp.id))), '[]'::json)
                   FROM pilgrims pp JOIN users us ON us.id = pp.user_id WHERE pp.group_id = ANY (_visible_groups(u))));
END $$;

-- =====================================================================
-- 5) تطبيق الحاج: عدّادات المناسك ودليل المنسك
-- =====================================================================
CREATE TABLE IF NOT EXISTS ritual_counters (
    id         BIGSERIAL PRIMARY KEY,
    pilgrim_id BIGINT       NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
    kind       counter_kind NOT NULL,
    hajj_day   SMALLINT     NOT NULL CHECK (hajj_day BETWEEN 7 AND 14),
    count      SMALLINT     NOT NULL DEFAULT 0 CHECK (count BETWEEN 0 AND 7),
    updated_at TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_counter UNIQUE (pilgrim_id, kind, hajj_day)
);
CREATE TABLE IF NOT EXISTS ritual_guides (
    id       BIGSERIAL PRIMARY KEY,
    hajj_day SMALLINT     NOT NULL CHECK (hajj_day BETWEEN 7 AND 14),
    lang     VARCHAR(5)   NOT NULL DEFAULT 'ar' CHECK (lang IN ('ar','en','ur','id','tr','fr')),
    title    VARCHAR(100) NOT NULL,
    steps    JSONB        NOT NULL DEFAULT '[]'::jsonb,
    dua      TEXT,
    tip      TEXT,
    CONSTRAINT uq_guide UNIQUE (hajj_day, lang)
);

-- شوط/حصاة واحدة للأمام أو للخلف. الجمرات بالترتيب: الصغرى ← الوسطى ← العقبة (يوم ١٠: العقبة فقط)
CREATE OR REPLACE FUNCTION app_counter_step(p_token UUID, p_kind counter_kind, p_day INT, p_delta INT DEFAULT 1)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_pid BIGINT; v_prev counter_kind; v_count INT;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT id INTO v_pid FROM pilgrims WHERE user_id = u.id;
  IF p_kind::text LIKE 'JAMRAH%' THEN
    IF p_day < 10 OR p_day > 13 THEN RAISE EXCEPTION 'NO_RAMI_TODAY' USING HINT = 'الرمي من يوم ١٠ إلى ١٣'; END IF;
    IF p_day = 10 AND p_kind <> 'JAMRAH_AQABA' THEN RAISE EXCEPTION 'AQABA_ONLY' USING HINT = 'يوم النحر: جمرة العقبة فقط'; END IF;
    v_prev := CASE p_kind WHEN 'JAMRAH_WUSTA' THEN 'JAMRAH_SUGHRA' WHEN 'JAMRAH_AQABA' THEN CASE WHEN p_day = 10 THEN NULL ELSE 'JAMRAH_WUSTA' END END;
    IF p_delta > 0 AND v_prev IS NOT NULL AND coalesce((SELECT count FROM ritual_counters
         WHERE pilgrim_id = v_pid AND kind = v_prev AND hajj_day = p_day), 0) < 7 THEN
      RAISE EXCEPTION 'ORDER' USING HINT = 'أكمل الجمرة السابقة أولًا';
    END IF;
  END IF;
  INSERT INTO ritual_counters (pilgrim_id, kind, hajj_day, count) VALUES (v_pid, p_kind, p_day, greatest(0, least(7, p_delta)))
  ON CONFLICT (pilgrim_id, kind, hajj_day) DO UPDATE SET count = greatest(0, least(7, ritual_counters.count + p_delta)), updated_at = now()
  RETURNING count INTO v_count;
  RETURN json_build_object('kind', p_kind, 'day', p_day, 'count', v_count, 'complete', v_count = 7);
END $$;

-- دليل اليوم بلغة الحاج (يرجع للعربية إن لم تتوفر الترجمة)
CREATE OR REPLACE FUNCTION app_guide(p_token UUID, p_day INT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_lang TEXT;
BEGIN
  u := _auth(p_token);
  SELECT preferred_language INTO v_lang FROM pilgrims WHERE user_id = u.id;
  RETURN (SELECT row_to_json(g) FROM (SELECT hajj_day, lang, title, steps, dua, tip FROM ritual_guides
           WHERE hajj_day = p_day AND lang IN (coalesce(v_lang, 'ar'), 'ar') ORDER BY (lang = coalesce(v_lang, 'ar')) DESC LIMIT 1) g);
END $$;

-- =====================================================================
-- 6) تقرير نهاية الحج (يجمع ritual_reports من v2)
-- =====================================================================
CREATE OR REPLACE FUNCTION app_season_report(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_groups BIGINT[];
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  v_groups := _visible_groups(u);
  RETURN json_build_object(
    'groups', (SELECT coalesce(json_agg(json_build_object('group', g.name,
        'attendance', (SELECT coalesce(json_agg(json_build_object('ritual', r.name,
              'rate', round(100.0 * (rr.present_count + rr.late_count) / nullif(rr.total_count, 0))) ORDER BY r.seq), '[]'::json)
              FROM ritual_reports rr JOIN rituals r ON r.id = rr.ritual_id WHERE rr.group_id = g.id),
        'alerts', (SELECT count(*) FROM alerts a JOIN pilgrims pp ON pp.id = a.pilgrim_id WHERE pp.group_id = g.id),
        'avg_response_min', (SELECT round(avg(extract(epoch FROM a.resolved_at - a.created_at) / 60)::numeric, 1)
              FROM alerts a JOIN pilgrims pp ON pp.id = a.pilgrim_id WHERE pp.group_id = g.id AND a.resolved_at IS NOT NULL),
        'avg_rating', (SELECT round(avg(rating)::numeric, 1) FROM comments WHERE group_id = g.id AND kind = 'PILGRIM_FEEDBACK'),
        'notes', (SELECT coalesce(json_agg(body), '[]'::json) FROM comments WHERE group_id = g.id AND kind = 'SUPERVISOR_NOTE')
      ) ORDER BY g.id), '[]'::json) FROM groups g WHERE g.id = ANY (v_groups)),
    'alerts_by_type', (SELECT coalesce(json_object_agg(type, n), '{}'::json) FROM (
        SELECT a.type, count(*) n FROM alerts a JOIN pilgrims pp ON pp.id = a.pilgrim_id WHERE pp.group_id = ANY (v_groups) GROUP BY a.type) t),
    'lost_items', (SELECT json_build_object('total', count(*), 'returned', count(*) FILTER (WHERE status = 'RETURNED'))
                     FROM lost_items WHERE campaign_id IN (SELECT campaign_id FROM groups WHERE id = ANY (v_groups))));
END $$;

-- =====================================================================
-- 7) الصلاحيات (نفس نمط v2)
-- =====================================================================
DO $$
DECLARE t TEXT; f RECORD;
BEGIN
  FOREACH t IN ARRAY ARRAY['sacred_sites','medications','medication_doses','wellness_checks','family_links','voice_messages',
                           'voice_message_translations','voice_message_receipts','lost_items','prep_tasks','prep_progress',
                           'ritual_counters','ritual_guides'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
    EXECUTE format('DROP POLICY IF EXISTS app_read ON public.%I', t);
  END LOOP;
  -- بيانات عامة غير حساسة تُقرأ مباشرة. الطبية والأهل والمفقودات عبر الدوال فقط
  FOREACH t IN ARRAY ARRAY['sacred_sites','prep_tasks','ritual_guides'] LOOP
    EXECUTE format('GRANT SELECT ON public.%I TO anon, authenticated', t);
    EXECUTE format('CREATE POLICY app_read ON public.%I FOR SELECT TO anon, authenticated USING (true)', t);
  END LOOP;
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND p.proname IN ('_point_in_site','_site_edge','_active_site','app_site_check','app_site_tick',
              'app_overnight_report','app_generate_doses','app_take_dose','app_my_doses','app_wellness_report','app_wellness_answer',
              'app_health_tick','app_medic_card','app_create_family_link','app_set_family_link','family_view','app_send_voice',
              'app_voice_heard','app_voice_status','app_report_lost','app_report_found','app_return_lost','app_prep_toggle',
              'app_prep_matrix','app_counter_step','app_guide','app_season_report') LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    IF f.proname LIKE 'app\_%' OR f.proname = 'family_view' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig);
    END IF;
  END LOOP;
END $$;

-- تحقق: يجب أن يظهر 38 جدولاً
SELECT count(*) AS tables_count FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
