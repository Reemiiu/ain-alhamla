-- =====================================================================
-- عين الحملة — ترقية قاعدة البيانات إلى الإصدار v2
-- Supabase → SQL Editor → New query → الصقي المحتوى كاملاً → Run
-- يُشغَّل فوق القاعدة الحية الحالية (13 جدولاً). آمن لإعادة التشغيل.
-- بعده شغّلي 05_seed_v2.sql (بيانات تجريبية للمناسك والتجمعات).
-- =====================================================================
-- ما يضيفه v2:
--  • 8 جداول: rituals, gatherings, location_pings, ritual_reports,
--    broadcasts, comments, activity_log, app_sessions  → المجموع 21 جدولاً
--  • أعمدة: أولوية الحاج (كبار سن/مرضى)، تاريخ الميلاد، الجنسية، لغة
--    التطبيق، الخط الكبير، وقت التسجيل على الجهاز (وضع عدم الاتصال)...
--  • 3 واجهات حسب الدور: الحاج / المشرف / الإدارة (+ مركز العمليات)
--  • دوال app_* : كل كتابة وكل قراءة حساسة تمر عبر دالة تتحقق من
--    "جلسة الدخول" ودور المستخدم داخل الخادم نفسه.
-- =====================================================================

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- ---------------------------------------------------------------------
-- 0) أنواع ENUM جديدة / قيم جديدة
-- ---------------------------------------------------------------------
-- قيم ENUM الجديدة تُحفظ (COMMIT) قبل باقي الملف، لأن PostgreSQL يرفض استخدام قيمة ENUM جديدة
-- في نفس المعاملة التي أُضيفت فيها (خطأ 55P04 في SQL Editor عند تشغيل الملف دفعة واحدة).
BEGIN;
ALTER TYPE alert_type           ADD VALUE IF NOT EXISTS 'LOST';         -- زر "أنا تائه"
ALTER TYPE alert_type           ADD VALUE IF NOT EXISTS 'LOW_BATTERY';  -- بطارية الجوال منخفضة
ALTER TYPE notification_channel ADD VALUE IF NOT EXISTS 'IN_APP';
COMMIT;

DO $$ BEGIN
  CREATE TYPE priority_level   AS ENUM ('NORMAL', 'HIGH', 'CRITICAL');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE ritual_status    AS ENUM ('UPCOMING', 'IN_PROGRESS', 'COMPLETED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE gathering_status AS ENUM ('SCHEDULED', 'OPEN', 'CLOSED');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
DO $$ BEGIN
  CREATE TYPE comment_kind     AS ENUM ('SUPERVISOR_NOTE', 'ADMIN_REPLY', 'PILGRIM_FEEDBACK');
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

-- ---------------------------------------------------------------------
-- 1) أعمدة جديدة على الجداول الحالية
-- ---------------------------------------------------------------------
ALTER TABLE pilgrims
  ADD COLUMN IF NOT EXISTS birth_date         DATE,
  ADD COLUMN IF NOT EXISTS nationality        VARCHAR(60),
  ADD COLUMN IF NOT EXISTS preferred_language VARCHAR(5)     NOT NULL DEFAULT 'ar',
  ADD COLUMN IF NOT EXISTS large_text         BOOLEAN        NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS priority_level     priority_level NOT NULL DEFAULT 'NORMAL',
  ADD COLUMN IF NOT EXISTS priority_reason    VARCHAR(150),
  ADD COLUMN IF NOT EXISTS priority_manual    BOOLEAN        NOT NULL DEFAULT FALSE;
DO $$ BEGIN
  ALTER TABLE pilgrims ADD CONSTRAINT chk_pilgrims_language CHECK (preferred_language IN ('ar','en','ur','id'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;

ALTER TABLE users ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT now();

-- =====================================================================
-- 2) الجداول الجديدة
-- =====================================================================

-- المناسك (التروية، عرفة، مزدلفة، الرمي، الإفاضة، الوداع) — التقرير يصدر بعد كل منسك
CREATE TABLE IF NOT EXISTS rituals (
    id            BIGSERIAL PRIMARY KEY,
    campaign_id   BIGINT        NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    name          VARCHAR(120)  NOT NULL,
    hajj_day      SMALLINT      NOT NULL CHECK (hajj_day BETWEEN 7 AND 14),   -- يوم ذي الحجة
    seq           SMALLINT      NOT NULL,
    location_id   BIGINT        REFERENCES locations(id) ON DELETE SET NULL,
    starts_at     TIMESTAMPTZ   NOT NULL,
    ends_at       TIMESTAMPTZ   NOT NULL,
    status        ritual_status NOT NULL DEFAULT 'UPCOMING',
    CONSTRAINT chk_ritual_time CHECK (ends_at > starts_at),
    CONSTRAINT uq_ritual_seq UNIQUE (campaign_id, seq)
);

-- التجمعات: موعد + مكان + مهلة زمنية (deadline_minutes) لمجموعة معيّنة
CREATE TABLE IF NOT EXISTS gatherings (
    id               BIGSERIAL PRIMARY KEY,
    campaign_id      BIGINT           NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    group_id         BIGINT           NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    ritual_id        BIGINT           REFERENCES rituals(id) ON DELETE SET NULL,
    trip_id          BIGINT           REFERENCES trips(id) ON DELETE SET NULL,
    location_id      BIGINT           NOT NULL REFERENCES locations(id),
    title            VARCHAR(150)     NOT NULL,
    scheduled_at     TIMESTAMPTZ      NOT NULL,
    deadline_minutes INT              NOT NULL DEFAULT 15 CHECK (deadline_minutes BETWEEN 0 AND 240),
    status           gathering_status NOT NULL DEFAULT 'SCHEDULED',
    created_by       BIGINT           REFERENCES users(id),
    created_at       TIMESTAMPTZ      NOT NULL DEFAULT now(),
    closed_at        TIMESTAMPTZ
);

-- نبضات الموقع من جوال الحاج/المشرف (تُرسل لاحقاً عند ضعف الشبكة)
CREATE TABLE IF NOT EXISTS location_pings (
    id                 BIGSERIAL PRIMARY KEY,
    user_id            BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    latitude           NUMERIC(9,6) NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
    longitude          NUMERIC(9,6) NOT NULL CHECK (longitude BETWEEN -180 AND 180),
    accuracy_m         INT,
    battery_pct        SMALLINT     CHECK (battery_pct IS NULL OR battery_pct BETWEEN 0 AND 100),
    client_recorded_at TIMESTAMPTZ  NOT NULL,
    synced_at          TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- تقرير بعد كل منسك لكل مجموعة (يُعاد توليده عند أي تحديث)
CREATE TABLE IF NOT EXISTS ritual_reports (
    id                 BIGSERIAL PRIMARY KEY,
    ritual_id          BIGINT       NOT NULL REFERENCES rituals(id) ON DELETE CASCADE,
    group_id           BIGINT       NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
    total_count        INT          NOT NULL DEFAULT 0,
    present_count      INT          NOT NULL DEFAULT 0,
    late_count         INT          NOT NULL DEFAULT 0,
    absent_count       INT          NOT NULL DEFAULT 0,
    out_of_range_count INT          NOT NULL DEFAULT 0,
    alerts_count       INT          NOT NULL DEFAULT 0,
    sos_count          INT          NOT NULL DEFAULT 0,
    avg_response_min   NUMERIC(6,1),
    avg_rating         NUMERIC(3,2),
    supervisor_comment TEXT,
    summary            JSONB        NOT NULL DEFAULT '{}'::jsonb,
    created_by         BIGINT       REFERENCES users(id),
    created_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ  NOT NULL DEFAULT now(),
    CONSTRAINT uq_ritual_report UNIQUE (ritual_id, group_id)
);

-- رسائل جماعية من المشرف لمجموعته أو من الإدارة للحملة كاملة
CREATE TABLE IF NOT EXISTS broadcasts (
    id          BIGSERIAL PRIMARY KEY,
    campaign_id BIGINT       NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
    group_id    BIGINT       REFERENCES groups(id) ON DELETE CASCADE,   -- NULL = كل الحملة
    sender_id   BIGINT       NOT NULL REFERENCES users(id),
    title       VARCHAR(150) NOT NULL,
    body        TEXT         NOT NULL,
    is_urgent   BOOLEAN      NOT NULL DEFAULT FALSE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- التعليقات: ملاحظات المشرفين، ردود الإدارة، وتقييم الحجاج بعد كل منسك
CREATE TABLE IF NOT EXISTS comments (
    id          BIGSERIAL PRIMARY KEY,
    author_id   BIGINT       NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    kind        comment_kind NOT NULL,
    ritual_id   BIGINT       REFERENCES rituals(id) ON DELETE CASCADE,
    group_id    BIGINT       REFERENCES groups(id) ON DELETE CASCADE,
    pilgrim_id  BIGINT       REFERENCES pilgrims(id) ON DELETE CASCADE,
    alert_id    BIGINT       REFERENCES alerts(id) ON DELETE CASCADE,
    parent_id   BIGINT       REFERENCES comments(id) ON DELETE CASCADE,
    rating      SMALLINT     CHECK (rating IS NULL OR rating BETWEEN 1 AND 5),
    body        TEXT         NOT NULL DEFAULT '',
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now(),
    read_at     TIMESTAMPTZ
);

-- سجل الشغل: كل إجراء ينفّذه مشرف/إدارة (تراه الإدارة)
CREATE TABLE IF NOT EXISTS activity_log (
    id          BIGSERIAL PRIMARY KEY,
    actor_id    BIGINT       REFERENCES users(id) ON DELETE SET NULL,
    action      VARCHAR(40)  NOT NULL,
    entity      VARCHAR(30),
    entity_id   BIGINT,
    group_id    BIGINT       REFERENCES groups(id) ON DELETE SET NULL,
    description TEXT         NOT NULL,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT now()
);

-- جلسات الدخول: رمز (token) يصدر عند الدخول وتتحقق منه كل دالة app_*
CREATE TABLE IF NOT EXISTS app_sessions (
    token        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id      BIGINT      NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at   TIMESTAMPTZ NOT NULL DEFAULT now(),
    expires_at   TIMESTAMPTZ NOT NULL,
    last_seen_at TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- أعمدة تربط الجداول الحالية بالجديدة
ALTER TABLE attendance
  ADD COLUMN IF NOT EXISTS gathering_id       BIGINT REFERENCES gatherings(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS distance_m         INT,
  ADD COLUMN IF NOT EXISTS recorded_by        BIGINT REFERENCES users(id),
  ADD COLUMN IF NOT EXISTS client_recorded_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS synced_at          TIMESTAMPTZ NOT NULL DEFAULT now();

ALTER TABLE alerts
  ADD COLUMN IF NOT EXISTS gathering_id BIGINT REFERENCES gatherings(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS ritual_id    BIGINT REFERENCES rituals(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS latitude     NUMERIC(9,6),
  ADD COLUMN IF NOT EXISTS longitude    NUMERIC(9,6),
  ADD COLUMN IF NOT EXISTS note         TEXT,
  ADD COLUMN IF NOT EXISTS escalated_at TIMESTAMPTZ;

ALTER TABLE sos_requests
  ADD COLUMN IF NOT EXISTS acknowledged_at TIMESTAMPTZ;

ALTER TABLE notifications
  ADD COLUMN IF NOT EXISTS broadcast_id BIGINT REFERENCES broadcasts(id) ON DELETE CASCADE,
  ADD COLUMN IF NOT EXISTS title        VARCHAR(150),
  ADD COLUMN IF NOT EXISTS body         TEXT;

-- ---------------------------------------------------------------------
-- 3) الفهارس
-- ---------------------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_rituals_campaign          ON rituals (campaign_id, seq);
CREATE INDEX IF NOT EXISTS idx_gatherings_group_time     ON gatherings (group_id, scheduled_at);
CREATE INDEX IF NOT EXISTS idx_gatherings_open           ON gatherings (status) WHERE status <> 'CLOSED';
CREATE INDEX IF NOT EXISTS idx_gatherings_ritual         ON gatherings (ritual_id);
CREATE INDEX IF NOT EXISTS idx_pings_user_time           ON location_pings (user_id, client_recorded_at DESC);
CREATE INDEX IF NOT EXISTS idx_ritual_reports_group      ON ritual_reports (group_id);
CREATE INDEX IF NOT EXISTS idx_broadcasts_group          ON broadcasts (group_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_comments_ritual           ON comments (ritual_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_comments_parent           ON comments (parent_id);
CREATE INDEX IF NOT EXISTS idx_activity_time             ON activity_log (created_at DESC);
CREATE INDEX IF NOT EXISTS idx_activity_actor            ON activity_log (actor_id);
CREATE INDEX IF NOT EXISTS idx_sessions_user             ON app_sessions (user_id);
CREATE INDEX IF NOT EXISTS idx_attendance_gathering      ON attendance (gathering_id);
CREATE INDEX IF NOT EXISTS idx_pilgrims_priority         ON pilgrims (priority_level);
CREATE INDEX IF NOT EXISTS idx_notifications_unread      ON notifications (user_id) WHERE read_at IS NULL;
-- حضور واحد لكل حاج في كل تجمع، وتنبيه واحد من كل نوع لكل حاج في كل تجمع
CREATE UNIQUE INDEX IF NOT EXISTS uq_attendance_gathering ON attendance (pilgrim_id, gathering_id) WHERE gathering_id IS NOT NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_alert_gathering      ON alerts (pilgrim_id, gathering_id, type) WHERE gathering_id IS NOT NULL;

-- =====================================================================
-- 4) دوال مساعدة داخلية (لا تُستدعى من الخارج)
-- =====================================================================

-- المسافة بالمتر بين نقطتين (Haversine)
CREATE OR REPLACE FUNCTION _dist_m(lat1 NUMERIC, lng1 NUMERIC, lat2 NUMERIC, lng2 NUMERIC)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN lat1 IS NULL OR lng1 IS NULL OR lat2 IS NULL OR lng2 IS NULL THEN NULL ELSE
    round(2 * 6371000 * asin(sqrt(
      power(sin(radians((lat2 - lat1)::float8) / 2), 2) +
      cos(radians(lat1::float8)) * cos(radians(lat2::float8)) *
      power(sin(radians((lng2 - lng1)::float8) / 2), 2))))::int END
$$;

-- اتجاه البوصلة بالدرجات من النقطة 1 إلى النقطة 2 (0 = شمال)
CREATE OR REPLACE FUNCTION _bearing(lat1 NUMERIC, lng1 NUMERIC, lat2 NUMERIC, lng2 NUMERIC)
RETURNS INT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN lat1 IS NULL OR lat2 IS NULL THEN NULL ELSE
    ((degrees(atan2(
        sin(radians((lng2 - lng1)::float8)) * cos(radians(lat2::float8)),
        cos(radians(lat1::float8)) * sin(radians(lat2::float8)) -
        sin(radians(lat1::float8)) * cos(radians(lat2::float8)) * cos(radians((lng2 - lng1)::float8))
     ))::int + 360) % 360) END
$$;

-- يحسب أولوية الحاج تلقائياً من العمر والحالة الصحية
CREATE OR REPLACE FUNCTION trg_pilgrim_priority()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE v_age INT; v_med BOOLEAN;
BEGIN
  IF NEW.priority_manual THEN RETURN NEW; END IF;
  v_age := CASE WHEN NEW.birth_date IS NULL THEN NULL ELSE date_part('year', age(NEW.birth_date))::int END;
  v_med := coalesce(btrim(NEW.medical_notes), '') <> '';
  IF (v_age >= 75) OR (v_age >= 65 AND v_med) THEN
    NEW.priority_level := 'CRITICAL';
  ELSIF (v_age >= 65) OR v_med THEN
    NEW.priority_level := 'HIGH';
  ELSE
    NEW.priority_level := 'NORMAL';
  END IF;
  NEW.priority_reason := nullif(concat_ws(' + ',
      CASE WHEN v_age >= 65 THEN 'كبير سن (' || v_age || ')' END,
      CASE WHEN v_med THEN 'حالة صحية' END), '');
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS pilgrims_priority ON pilgrims;
CREATE TRIGGER pilgrims_priority
  BEFORE INSERT OR UPDATE OF birth_date, medical_notes, priority_manual ON pilgrims
  FOR EACH ROW EXECUTE FUNCTION trg_pilgrim_priority();
UPDATE pilgrims SET medical_notes = medical_notes;   -- حساب الأولوية للحجاج الحاليين

-- اسم نوع التنبيه بالعربية (لسجل الشغل والإشعارات)
CREATE OR REPLACE FUNCTION _alert_label(t alert_type)
RETURNS TEXT LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE t::text WHEN 'SOS' THEN 'طلب نجدة SOS' WHEN 'LOST' THEN 'حاج تائه' WHEN 'ABSENCE' THEN 'غياب'
    WHEN 'DELAY' THEN 'تأخر' WHEN 'GEOFENCE_BREACH' THEN 'خروج عن النطاق' WHEN 'LOW_BATTERY' THEN 'بطارية منخفضة' ELSE t::text END
$$;

-- يتحقق من رمز الجلسة ويعيد المستخدم، ويرفض الأدوار غير المسموحة
CREATE OR REPLACE FUNCTION _auth(p_token UUID, p_roles user_role[] DEFAULT NULL)
RETURNS users LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  SELECT us.* INTO u FROM app_sessions s JOIN users us ON us.id = s.user_id
   WHERE s.token = p_token AND s.expires_at > now() AND us.is_active;
  IF u.id IS NULL THEN
    RAISE EXCEPTION 'SESSION_EXPIRED' USING HINT = 'انتهت الجلسة، سجّل الدخول من جديد';
  END IF;
  IF p_roles IS NOT NULL AND NOT (u.role = ANY (p_roles)) THEN
    RAISE EXCEPTION 'FORBIDDEN' USING HINT = 'هذه الخدمة غير متاحة لدورك';
  END IF;
  UPDATE app_sessions SET last_seen_at = now() WHERE token = p_token;
  RETURN u;
END $$;

-- المجموعات التي يحق للمستخدم رؤيتها (المشرف: مجموعاته فقط)
CREATE OR REPLACE FUNCTION _visible_groups(u users)
RETURNS BIGINT[] LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN u.role IN ('ADMIN', 'OPERATIONS_CENTER') THEN (SELECT coalesce(array_agg(id), '{}') FROM groups)
    WHEN u.role = 'SUPERVISOR' THEN (SELECT coalesce(array_agg(g.id), '{}') FROM groups g
                                       JOIN supervisors s ON s.id = g.supervisor_id WHERE s.user_id = u.id)
    ELSE (SELECT coalesce(array_agg(group_id), '{}') FROM pilgrims WHERE user_id = u.id AND group_id IS NOT NULL)
  END
$$;

CREATE OR REPLACE FUNCTION _can_manage_group(u users, p_group_id BIGINT)
RETURNS BOOLEAN LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT u.role IN ('ADMIN', 'OPERATIONS_CENTER')
      OR (u.role = 'SUPERVISOR' AND p_group_id = ANY (_visible_groups(u)))
$$;

CREATE OR REPLACE FUNCTION _log(p_actor BIGINT, p_action TEXT, p_entity TEXT, p_entity_id BIGINT, p_group BIGINT, p_desc TEXT)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO activity_log (actor_id, action, entity, entity_id, group_id, description)
  VALUES (p_actor, p_action, p_entity, p_entity_id, p_group, p_desc);
$$;

CREATE OR REPLACE FUNCTION _notify(p_user BIGINT, p_alert BIGINT, p_broadcast BIGINT, p_title TEXT, p_body TEXT)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  INSERT INTO notifications (user_id, alert_id, broadcast_id, channel, title, body)
  VALUES (p_user, p_alert, p_broadcast, 'IN_APP', p_title, p_body);
$$;

-- آخر موقع معروف لمستخدم (خلال p_minutes دقيقة)
CREATE OR REPLACE FUNCTION _last_ping(p_user BIGINT, p_minutes INT DEFAULT 180)
RETURNS location_pings LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT * FROM location_pings
   WHERE user_id = p_user AND client_recorded_at > now() - make_interval(mins => p_minutes)
   ORDER BY client_recorded_at DESC LIMIT 1
$$;

-- وقت الجهاز المقبول (لوضع عدم الاتصال): لا مستقبل، ولا أقدم من 12 ساعة
CREATE OR REPLACE FUNCTION _client_time(p_ts TIMESTAMPTZ)
RETURNS TIMESTAMPTZ LANGUAGE sql STABLE AS $$
  SELECT CASE WHEN p_ts IS NULL OR p_ts > now() + interval '2 minutes' OR p_ts < now() - interval '12 hours'
              THEN now() ELSE p_ts END
$$;

-- مشرف المجموعة (user_id)
CREATE OR REPLACE FUNCTION _group_supervisor_user(p_group BIGINT)
RETURNS BIGINT LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT s.user_id FROM groups g JOIN supervisors s ON s.id = g.supervisor_id WHERE g.id = p_group
$$;

-- خطورة التنبيه حسب أولوية الحاج
CREATE OR REPLACE FUNCTION _severity(p_base alert_severity, p_priority priority_level)
RETURNS alert_severity LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE
    WHEN p_priority = 'CRITICAL' THEN 'CRITICAL'::alert_severity
    WHEN p_priority = 'HIGH' AND p_base = 'LOW' THEN 'MEDIUM'::alert_severity
    WHEN p_priority = 'HIGH' AND p_base = 'MEDIUM' THEN 'CRITICAL'::alert_severity
    ELSE p_base END
$$;

-- =====================================================================
-- 5) الدخول والجلسة
-- =====================================================================
CREATE OR REPLACE FUNCTION app_login(p_national_id TEXT, p_password TEXT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u users; v_token UUID;
BEGIN
  SELECT * INTO u FROM users
   WHERE national_id = btrim(p_national_id) AND is_active
     AND password_hash = crypt(p_password, password_hash);
  IF u.id IS NULL THEN RETURN NULL; END IF;
  DELETE FROM app_sessions WHERE user_id = u.id AND expires_at < now();
  INSERT INTO app_sessions (user_id, expires_at)
  VALUES (u.id, now() + CASE WHEN u.role = 'PILGRIM' THEN interval '30 days' ELSE interval '12 hours' END)
  RETURNING token INTO v_token;
  IF u.role <> 'PILGRIM' THEN
    PERFORM _log(u.id, 'LOGIN', 'user', u.id, NULL, 'تسجيل دخول');
  END IF;
  RETURN json_build_object('token', v_token, 'user', json_build_object(
    'id', u.id, 'full_name', u.full_name, 'national_id', u.national_id,
    'phone', u.phone, 'role', u.role, 'is_active', u.is_active));
END $$;

CREATE OR REPLACE FUNCTION app_logout(p_token UUID)
RETURNS VOID LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  DELETE FROM app_sessions WHERE token = p_token;
$$;

-- ملف المستخدم الكامل حسب دوره (الحاج: ملفه الطبي وجهات طوارئه ومشرفه)
CREATE OR REPLACE FUNCTION app_me(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; r JSON;
BEGIN
  u := _auth(p_token);
  IF u.role = 'PILGRIM' THEN
    SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
    SELECT json_build_object(
      'user', json_build_object('id', u.id, 'full_name', u.full_name, 'national_id', u.national_id, 'phone', u.phone, 'role', u.role),
      'pilgrim', json_build_object('id', p.id, 'campaign_id', p.campaign_id, 'group_id', p.group_id,
         'passport_no', p.passport_no, 'blood_type', p.blood_type, 'medical_notes', p.medical_notes,
         'birth_date', p.birth_date, 'nationality', p.nationality, 'preferred_language', p.preferred_language,
         'large_text', p.large_text, 'priority_level', p.priority_level, 'priority_reason', p.priority_reason),
      'campaign', (SELECT json_build_object('id', c.id, 'name', c.name, 'license_no', c.license_no, 'status', c.status)
                     FROM campaigns c WHERE c.id = p.campaign_id),
      'group', (SELECT json_build_object('id', g.id, 'name', g.name, 'capacity', g.capacity,
                  'supervisor_name', su.full_name, 'supervisor_phone', su.phone, 'supervisor_user_id', su.id)
                  FROM groups g LEFT JOIN supervisors s ON s.id = g.supervisor_id LEFT JOIN users su ON su.id = s.user_id
                 WHERE g.id = p.group_id),
      'contacts', (SELECT coalesce(json_agg(json_build_object('id', e.id, 'name', e.name, 'relation', e.relation,
                     'phone', e.phone, 'is_primary', e.is_primary) ORDER BY e.is_primary DESC, e.id), '[]'::json)
                     FROM emergency_contacts e WHERE e.pilgrim_id = p.id)
    ) INTO r;
  ELSE
    SELECT json_build_object(
      'user', json_build_object('id', u.id, 'full_name', u.full_name, 'national_id', u.national_id, 'phone', u.phone, 'role', u.role),
      'supervisor', (SELECT json_build_object('id', s.id, 'job_title', s.job_title, 'campaign_id', s.campaign_id)
                       FROM supervisors s WHERE s.user_id = u.id),
      'groups', (SELECT coalesce(json_agg(json_build_object('id', g.id, 'name', g.name, 'capacity', g.capacity,
                   'campaign_id', g.campaign_id) ORDER BY g.id), '[]'::json)
                   FROM groups g WHERE g.id = ANY (_visible_groups(u))),
      'campaign', (SELECT json_build_object('id', c.id, 'name', c.name, 'status', c.status)
                     FROM campaigns c ORDER BY (c.status = 'ACTIVE') DESC, c.id LIMIT 1)
    ) INTO r;
  END IF;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION app_update_preferences(p_token UUID, p_language TEXT, p_large_text BOOLEAN)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  UPDATE pilgrims SET preferred_language = coalesce(p_language, preferred_language),
                      large_text = coalesce(p_large_text, large_text)
   WHERE user_id = u.id;
END $$;

-- =====================================================================
-- 6) خدمات الحاج: الموقع، مؤشر القرب، جدول اليوم، الحضور، SOS، "أنا تائه"
-- =====================================================================

-- مؤشر القرب: المسافة من المشرف، من أقرب فرد، ومن نقطة التجمع القادمة (مع اتجاه البوصلة)
CREATE OR REPLACE FUNCTION app_proximity(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; me location_pings; sup location_pings; v_sup BIGINT;
        g RECORD; z RECORD; nm RECORD;
BEGIN
  u := _auth(p_token);
  me := _last_ping(u.id, 720);
  IF u.role = 'PILGRIM' THEN
    SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
    v_sup := _group_supervisor_user(p.group_id);
  END IF;
  IF v_sup IS NOT NULL THEN sup := _last_ping(v_sup, 180); END IF;

  -- أقرب فرد من نفس المجموعة له موقع حديث
  SELECT us.full_name, _dist_m(me.latitude, me.longitude, lp.latitude, lp.longitude) AS d INTO nm
    FROM pilgrims pp JOIN users us ON us.id = pp.user_id
    CROSS JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = pp.user_id
                         AND l.client_recorded_at > now() - interval '60 minutes'
                         ORDER BY l.client_recorded_at DESC LIMIT 1) lp
   WHERE pp.group_id = p.group_id AND pp.user_id <> u.id AND me.id IS NOT NULL
   ORDER BY d LIMIT 1;

  -- التجمع القادم/الحالي لمجموعتي
  SELECT gt.id, gt.title, gt.scheduled_at, gt.deadline_minutes, gt.status, l.name AS loc, l.latitude, l.longitude, l.radius_meters
    INTO g FROM gatherings gt JOIN locations l ON l.id = gt.location_id
   WHERE gt.group_id = coalesce(p.group_id, -1) AND gt.status <> 'CLOSED'
     AND gt.scheduled_at > now() - interval '6 hours'
   ORDER BY gt.scheduled_at LIMIT 1;

  -- أقرب نطاق آمن/نقطة من مواقع الحملة
  SELECT l.name, l.radius_meters, _dist_m(me.latitude, me.longitude, l.latitude, l.longitude) AS d INTO z
    FROM locations l WHERE me.id IS NOT NULL AND (l.campaign_id = p.campaign_id OR p.campaign_id IS NULL)
   ORDER BY d LIMIT 1;

  RETURN json_build_object(
    'me', CASE WHEN me.id IS NULL THEN NULL ELSE json_build_object('lat', me.latitude, 'lng', me.longitude,
            'at', me.client_recorded_at, 'battery', me.battery_pct) END,
    'supervisor', CASE WHEN sup.id IS NULL THEN NULL ELSE json_build_object(
            'distance_m', _dist_m(me.latitude, me.longitude, sup.latitude, sup.longitude),
            'bearing', _bearing(me.latitude, me.longitude, sup.latitude, sup.longitude),
            'at', sup.client_recorded_at) END,
    'nearest_member', CASE WHEN nm.full_name IS NULL THEN NULL ELSE json_build_object('name', nm.full_name, 'distance_m', nm.d) END,
    'zone', CASE WHEN z.name IS NULL THEN NULL ELSE json_build_object('name', z.name, 'distance_m', z.d,
            'radius_m', z.radius_meters, 'inside', z.d <= z.radius_meters) END,
    'gathering', CASE WHEN g.id IS NULL THEN NULL ELSE json_build_object('id', g.id, 'title', g.title,
            'location', g.loc, 'scheduled_at', g.scheduled_at, 'deadline_minutes', g.deadline_minutes,
            'status', g.status, 'lat', g.latitude, 'lng', g.longitude, 'radius_m', g.radius_meters,
            'distance_m', _dist_m(me.latitude, me.longitude, g.latitude, g.longitude),
            'bearing', _bearing(me.latitude, me.longitude, g.latitude, g.longitude),
            'checked_in', (SELECT a.status FROM attendance a WHERE a.gathering_id = g.id AND a.pilgrim_id = p.id)) END
  );
END $$;

-- نبضة موقع (من الحاج أو المشرف). تُطلق تنبيه الخروج عن النطاق وتنبيه البطارية.
CREATE OR REPLACE FUNCTION app_record_ping(p_token UUID, p_lat NUMERIC, p_lng NUMERIC,
    p_accuracy INT DEFAULT NULL, p_battery INT DEFAULT NULL, p_recorded_at TIMESTAMPTZ DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_at TIMESTAMPTZ; ref RECORD; v_alert BIGINT; v_sup BIGINT;
BEGIN
  u := _auth(p_token);
  v_at := _client_time(p_recorded_at);
  INSERT INTO location_pings (user_id, latitude, longitude, accuracy_m, battery_pct, client_recorded_at)
  VALUES (u.id, p_lat, p_lng, p_accuracy, p_battery, v_at);

  IF u.role = 'PILGRIM' AND v_at > now() - interval '15 minutes' THEN
    SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
    v_sup := _group_supervisor_user(p.group_id);

    -- النطاق المرجعي: موقع التجمع الحالي، وإلا أقرب موقع للحملة
    SELECT l.id, l.name, l.radius_meters, _dist_m(p_lat, p_lng, l.latitude, l.longitude) AS d INTO ref
      FROM gatherings gt JOIN locations l ON l.id = gt.location_id
     WHERE gt.group_id = p.group_id AND gt.status = 'OPEN'
     ORDER BY gt.scheduled_at DESC LIMIT 1;
    IF ref.id IS NULL THEN
      SELECT l.id, l.name, l.radius_meters, _dist_m(p_lat, p_lng, l.latitude, l.longitude) AS d INTO ref
        FROM locations l WHERE l.campaign_id = p.campaign_id ORDER BY d LIMIT 1;
    END IF;

    IF ref.id IS NOT NULL AND ref.d > ref.radius_meters * 1.5 AND NOT EXISTS (
         SELECT 1 FROM alerts WHERE pilgrim_id = p.id AND type = 'GEOFENCE_BREACH' AND status <> 'RESOLVED'
            AND created_at > now() - interval '30 minutes') THEN
      INSERT INTO alerts (pilgrim_id, location_id, type, severity, latitude, longitude, note)
      VALUES (p.id, ref.id, 'GEOFENCE_BREACH', _severity('MEDIUM', p.priority_level), p_lat, p_lng,
              'على بعد ' || ref.d || ' م من ' || ref.name)
      RETURNING id INTO v_alert;
      IF v_sup IS NOT NULL THEN
        PERFORM _notify(v_sup, v_alert, NULL, 'خروج عن النطاق', u.full_name || ' على بعد ' || ref.d || ' م من ' || ref.name);
      END IF;
    END IF;

    IF p_battery IS NOT NULL AND p_battery < 15 AND NOT EXISTS (
         SELECT 1 FROM alerts WHERE pilgrim_id = p.id AND type = 'LOW_BATTERY' AND created_at > now() - interval '3 hours') THEN
      INSERT INTO alerts (pilgrim_id, type, severity, latitude, longitude, note)
      VALUES (p.id, 'LOW_BATTERY', _severity('LOW', p.priority_level), p_lat, p_lng, 'البطارية ' || p_battery || '٪')
      RETURNING id INTO v_alert;
      IF v_sup IS NOT NULL THEN
        PERFORM _notify(v_sup, v_alert, NULL, 'بطارية منخفضة', u.full_name || ': ' || p_battery || '٪ — قد ينقطع تتبعه قريباً');
      END IF;
    END IF;
  END IF;

  RETURN app_proximity(p_token);
END $$;

-- جدول اليوم: المناسك + تجمعات مجموعتي + رحلاتها + حالة حضوري
CREATE OR REPLACE FUNCTION app_today(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_groups BIGINT[];
BEGIN
  u := _auth(p_token);
  v_groups := _visible_groups(u);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  RETURN json_build_object(
    'rituals', (SELECT coalesce(json_agg(json_build_object('id', r.id, 'name', r.name, 'hajj_day', r.hajj_day,
                  'starts_at', r.starts_at, 'ends_at', r.ends_at, 'status', r.status, 'location', l.name) ORDER BY r.seq), '[]'::json)
                  FROM rituals r LEFT JOIN locations l ON l.id = r.location_id
                 WHERE r.campaign_id IN (SELECT campaign_id FROM groups WHERE id = ANY (v_groups))),
    'gatherings', (SELECT coalesce(json_agg(json_build_object('id', gt.id, 'title', gt.title, 'group_id', gt.group_id,
                  'scheduled_at', gt.scheduled_at, 'deadline_minutes', gt.deadline_minutes, 'status', gt.status,
                  'location', l.name, 'ritual_id', gt.ritual_id,
                  'my_status', (SELECT a.status FROM attendance a WHERE a.gathering_id = gt.id AND a.pilgrim_id = p.id))
                  ORDER BY gt.scheduled_at), '[]'::json)
                  FROM gatherings gt JOIN locations l ON l.id = gt.location_id
                 WHERE gt.group_id = ANY (v_groups) AND gt.scheduled_at > now() - interval '24 hours'),
    'trips', (SELECT coalesce(json_agg(json_build_object('id', t.id, 'vehicle_no', t.vehicle_no, 'driver_name', t.driver_name,
                  'from', lf.name, 'to', lt.name, 'departure_time', t.departure_time, 'status', t.status) ORDER BY t.departure_time), '[]'::json)
                  FROM trips t LEFT JOIN locations lf ON lf.id = t.route_from_id LEFT JOIN locations lt ON lt.id = t.route_to_id
                 WHERE t.status <> 'COMPLETED' AND EXISTS (SELECT 1 FROM trip_groups tg WHERE tg.trip_id = t.id AND tg.group_id = ANY (v_groups)))
  );
END $$;

-- تسجيل الحضور من التطبيق: يحسب حاضر/متأخر/خارج النطاق من المهلة والمسافة
CREATE OR REPLACE FUNCTION app_check_in(p_token UUID, p_gathering_id BIGINT, p_lat NUMERIC, p_lng NUMERIC,
    p_recorded_at TIMESTAMPTZ DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; g RECORD; v_at TIMESTAMPTZ; v_d INT; v_status attendance_status;
        v_late INT; v_alert BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  SELECT gt.*, l.latitude AS lat, l.longitude AS lng, l.radius_meters AS radius, l.name AS loc
    INTO g FROM gatherings gt JOIN locations l ON l.id = gt.location_id WHERE gt.id = p_gathering_id;
  IF g.id IS NULL OR g.group_id IS DISTINCT FROM p.group_id THEN RAISE EXCEPTION 'GATHERING_NOT_FOUND'; END IF;
  IF g.status = 'CLOSED' THEN RAISE EXCEPTION 'GATHERING_CLOSED' USING HINT = 'تم إغلاق هذا التجمع'; END IF;
  v_at := _client_time(p_recorded_at);
  IF v_at < g.scheduled_at - interval '90 minutes' THEN
    RAISE EXCEPTION 'TOO_EARLY' USING HINT = 'يفتح تسجيل الحضور قبل الموعد بساعة ونصف';
  END IF;
  v_d := _dist_m(p_lat, p_lng, g.lat, g.lng);
  v_late := greatest(0, floor(extract(epoch FROM v_at - g.scheduled_at) / 60)::int - g.deadline_minutes);
  v_status := CASE WHEN v_d IS NOT NULL AND v_d > g.radius THEN 'OUT_OF_RANGE'
                   WHEN v_late > 0 THEN 'LATE' ELSE 'PRESENT' END;

  INSERT INTO attendance (pilgrim_id, location_id, gathering_id, checkpoint_time, status, source, distance_m, client_recorded_at)
  VALUES (p.id, g.location_id, g.id, v_at, v_status, 'APP_CHECKIN', v_d, p_recorded_at)
  ON CONFLICT (pilgrim_id, gathering_id) WHERE gathering_id IS NOT NULL
  DO UPDATE SET status = EXCLUDED.status, checkpoint_time = EXCLUDED.checkpoint_time,
                distance_m = EXCLUDED.distance_m, source = 'APP_CHECKIN', synced_at = now();

  IF p_lat IS NOT NULL THEN
    INSERT INTO location_pings (user_id, latitude, longitude, client_recorded_at) VALUES (u.id, p_lat, p_lng, v_at);
  END IF;

  -- حضر الآن: يُغلق تنبيه الغياب المفتوح لهذا التجمع
  IF v_status <> 'OUT_OF_RANGE' THEN
    UPDATE alerts SET status = 'RESOLVED', resolved_at = now(), note = coalesce(note || ' — ', '') || 'سجّل حضوره لاحقاً'
     WHERE pilgrim_id = p.id AND gathering_id = g.id AND type = 'ABSENCE' AND status <> 'RESOLVED';
  END IF;
  IF v_status = 'LATE' THEN
    INSERT INTO alerts (pilgrim_id, location_id, gathering_id, ritual_id, type, severity, note)
    VALUES (p.id, g.location_id, g.id, g.ritual_id, 'DELAY', _severity('LOW', p.priority_level), 'تأخر ' || v_late || ' دقيقة عن المهلة')
    ON CONFLICT (pilgrim_id, gathering_id, type) WHERE gathering_id IS NOT NULL DO NOTHING;
  END IF;
  RETURN json_build_object('status', v_status, 'distance_m', v_d, 'late_minutes', v_late, 'location', g.loc);
END $$;

-- SOS (p_kind = 'SOS') أو "أنا تائه" (p_kind = 'LOST'): يُبلَّغ المشرف ومركز العمليات وأقرب 3 أفراد
CREATE OR REPLACE FUNCTION app_trigger_sos(p_token UUID, p_lat NUMERIC DEFAULT NULL, p_lng NUMERIC DEFAULT NULL,
    p_recorded_at TIMESTAMPTZ DEFAULT NULL, p_kind TEXT DEFAULT 'SOS')
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_at TIMESTAMPTZ; v_alert BIGINT; v_sos BIGINT; v_sup BIGINT; v_n INT := 0;
        v_title TEXT; v_body TEXT; rec RECORD; v_lat NUMERIC; v_lng NUMERIC; lp location_pings;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  v_at := _client_time(p_recorded_at);
  v_lat := p_lat; v_lng := p_lng;
  IF v_lat IS NULL THEN lp := _last_ping(u.id, 60); v_lat := lp.latitude; v_lng := lp.longitude; END IF;
  IF v_lat IS NOT NULL THEN
    INSERT INTO location_pings (user_id, latitude, longitude, client_recorded_at) VALUES (u.id, v_lat, v_lng, v_at);
  END IF;

  IF p_kind = 'LOST' THEN
    INSERT INTO alerts (pilgrim_id, type, severity, latitude, longitude, note, created_at)
    VALUES (p.id, 'LOST', _severity('MEDIUM', p.priority_level), v_lat, v_lng, 'الحاج أبلغ أنه تائه', v_at)
    RETURNING id INTO v_alert;
    v_title := 'حاج تائه'; v_body := u.full_name || ' ضغط «أنا تائه» ويحتاج توجيهاً';
  ELSE
    INSERT INTO alerts (pilgrim_id, type, severity, latitude, longitude, created_at)
    VALUES (p.id, 'SOS', 'CRITICAL', v_lat, v_lng, v_at) RETURNING id INTO v_alert;
    INSERT INTO sos_requests (alert_id, pilgrim_id, latitude, longitude, status, triggered_at)
    VALUES (v_alert, p.id, v_lat, v_lng, 'PENDING', v_at) RETURNING id INTO v_sos;
    v_title := 'طلب نجدة SOS'; v_body := u.full_name || ' يطلب مساعدة فورية';
  END IF;

  v_sup := _group_supervisor_user(p.group_id);
  IF v_sup IS NOT NULL THEN PERFORM _notify(v_sup, v_alert, NULL, v_title, v_body); v_n := v_n + 1; END IF;
  FOR rec IN SELECT id FROM users WHERE role = 'OPERATIONS_CENTER' AND is_active LOOP
    PERFORM _notify(rec.id, v_alert, NULL, v_title, v_body); v_n := v_n + 1;
  END LOOP;
  -- أقرب 3 أفراد من المجموعة (آخر موقع خلال ساعة)
  IF v_lat IS NOT NULL THEN
    FOR rec IN
      SELECT pp.user_id FROM pilgrims pp
        CROSS JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = pp.user_id
                             AND l.client_recorded_at > now() - interval '60 minutes'
                             ORDER BY l.client_recorded_at DESC LIMIT 1) lp2
       WHERE pp.group_id = p.group_id AND pp.user_id <> u.id
       ORDER BY _dist_m(v_lat, v_lng, lp2.latitude, lp2.longitude) LIMIT 3
    LOOP
      PERFORM _notify(rec.user_id, v_alert, NULL, v_title || ' قريب منك', v_body); v_n := v_n + 1;
    END LOOP;
  END IF;
  RETURN json_build_object('alert_id', v_alert, 'sos_id', v_sos, 'notified', v_n, 'has_location', v_lat IS NOT NULL);
END $$;

-- تنبيهاتي وإشعاراتي (تنبيهات تخصني + رسائل المشرف + بلاغات قريبة مني)
CREATE OR REPLACE FUNCTION app_my_feed(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token);
  RETURN json_build_object(
    'unread', (SELECT count(*) FROM notifications WHERE user_id = u.id AND read_at IS NULL),
    'notifications', (SELECT coalesce(json_agg(x ORDER BY x.sent_at DESC), '[]'::json) FROM (
        SELECT n.id, n.title, n.body, n.sent_at, n.read_at, n.alert_id, n.broadcast_id,
               a.type AS alert_type, a.severity, a.status AS alert_status, b.is_urgent
          FROM notifications n LEFT JOIN alerts a ON a.id = n.alert_id LEFT JOIN broadcasts b ON b.id = n.broadcast_id
         WHERE n.user_id = u.id ORDER BY n.sent_at DESC LIMIT 50) x),
    'my_alerts', (SELECT coalesce(json_agg(x ORDER BY x.created_at DESC), '[]'::json) FROM (
        SELECT a.id, a.type, a.severity, a.status, a.created_at, a.resolved_at, a.note
          FROM alerts a JOIN pilgrims pp ON pp.id = a.pilgrim_id
         WHERE pp.user_id = u.id ORDER BY a.created_at DESC LIMIT 30) x)
  );
END $$;

CREATE OR REPLACE FUNCTION app_mark_read(p_token UUID)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token);
  UPDATE notifications SET read_at = now() WHERE user_id = u.id AND read_at IS NULL;
END $$;

CREATE OR REPLACE FUNCTION app_save_contact(p_token UUID, p_name TEXT, p_relation TEXT, p_phone TEXT, p_is_primary BOOLEAN DEFAULT FALSE)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_pid BIGINT; v_id BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT id INTO v_pid FROM pilgrims WHERE user_id = u.id;
  IF p_is_primary OR NOT EXISTS (SELECT 1 FROM emergency_contacts WHERE pilgrim_id = v_pid) THEN
    UPDATE emergency_contacts SET is_primary = FALSE WHERE pilgrim_id = v_pid;
    p_is_primary := TRUE;
  END IF;
  INSERT INTO emergency_contacts (pilgrim_id, name, relation, phone, is_primary)
  VALUES (v_pid, btrim(p_name), nullif(btrim(p_relation), ''), regexp_replace(p_phone, '[^0-9+]', '', 'g'), p_is_primary)
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION app_delete_contact(p_token UUID, p_contact_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  DELETE FROM emergency_contacts e USING pilgrims pp
   WHERE e.id = p_contact_id AND e.pilgrim_id = pp.id AND pp.user_id = u.id;
END $$;

-- تقييم الحاج للخدمة بعد المنسك (نجوم + تعليق)
CREATE OR REPLACE FUNCTION app_rate_ritual(p_token UUID, p_ritual_id BIGINT, p_rating INT, p_body TEXT DEFAULT '')
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  DELETE FROM comments WHERE author_id = u.id AND ritual_id = p_ritual_id AND kind = 'PILGRIM_FEEDBACK';
  INSERT INTO comments (author_id, kind, ritual_id, group_id, pilgrim_id, rating, body)
  VALUES (u.id, 'PILGRIM_FEEDBACK', p_ritual_id, p.group_id, p.id, p_rating, coalesce(p_body, ''));
END $$;

-- =====================================================================
-- 7) خدمات المشرف (والإدارة)
-- =====================================================================

-- لوحة المجموعة: الحجاج مرتبين بالأولوية مع حضور التجمع الحالي وآخر موقع وبطارية
CREATE OR REPLACE FUNCTION app_board(p_token UUID, p_group_id BIGINT DEFAULT NULL)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_groups BIGINT[];
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  v_groups := _visible_groups(u);
  IF p_group_id IS NOT NULL THEN
    IF NOT p_group_id = ANY (v_groups) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
    v_groups := ARRAY[p_group_id];
  END IF;
  RETURN json_build_object(
    'groups', (SELECT coalesce(json_agg(json_build_object('id', g.id, 'name', g.name, 'capacity', g.capacity,
        'supervisor_name', su.full_name, 'members', (SELECT count(*) FROM pilgrims WHERE group_id = g.id),
        'gathering', (SELECT json_build_object('id', gt.id, 'title', gt.title, 'scheduled_at', gt.scheduled_at,
              'deadline_minutes', gt.deadline_minutes, 'status', gt.status, 'location', l.name, 'ritual_id', gt.ritual_id,
              'ritual', (SELECT r.name FROM rituals r WHERE r.id = gt.ritual_id),
              'checked', (SELECT count(*) FROM attendance a WHERE a.gathering_id = gt.id AND a.status IN ('PRESENT','LATE')))
            FROM gatherings gt JOIN locations l ON l.id = gt.location_id
           WHERE gt.group_id = g.id AND gt.status <> 'CLOSED' ORDER BY gt.scheduled_at LIMIT 1)
      ) ORDER BY g.id), '[]'::json)
      FROM groups g LEFT JOIN supervisors s ON s.id = g.supervisor_id LEFT JOIN users su ON su.id = s.user_id
     WHERE g.id = ANY (v_groups)),
    'pilgrims', (SELECT coalesce(json_agg(x ORDER BY x.prio DESC, x.full_name), '[]'::json) FROM (
      SELECT pp.id, pp.user_id, us.full_name, us.national_id, us.phone, pp.group_id, g.name AS group_name,
             pp.priority_level, pp.priority_reason, pp.nationality, pp.preferred_language,
             CASE pp.priority_level WHEN 'CRITICAL' THEN 3 WHEN 'HIGH' THEN 2 ELSE 1 END AS prio,
             date_part('year', age(pp.birth_date))::int AS age,
             (SELECT json_build_object('status', a.status, 'at', a.checkpoint_time, 'location', l.name, 'source', a.source)
                FROM attendance a LEFT JOIN locations l ON l.id = a.location_id
               WHERE a.pilgrim_id = pp.id ORDER BY a.checkpoint_time DESC LIMIT 1) AS last_attendance,
             (SELECT a.status FROM attendance a JOIN gatherings gt ON gt.id = a.gathering_id
               WHERE a.pilgrim_id = pp.id AND gt.group_id = pp.group_id AND gt.status <> 'CLOSED'
               ORDER BY gt.scheduled_at LIMIT 1) AS current_status,
             (SELECT json_build_object('at', lp.client_recorded_at, 'battery', lp.battery_pct,
                     'lat', lp.latitude, 'lng', lp.longitude)
                FROM location_pings lp WHERE lp.user_id = pp.user_id ORDER BY lp.client_recorded_at DESC LIMIT 1) AS last_ping,
             (SELECT count(*) FROM alerts a WHERE a.pilgrim_id = pp.id AND a.status <> 'RESOLVED') AS open_alerts
        FROM pilgrims pp JOIN users us ON us.id = pp.user_id LEFT JOIN groups g ON g.id = pp.group_id
       WHERE pp.group_id = ANY (v_groups) OR (u.role IN ('ADMIN','OPERATIONS_CENTER') AND p_group_id IS NULL AND pp.group_id IS NULL)) x)
  );
END $$;

-- الملف الحساس للحاج (طبي/جواز/جهات طوارئ) — للمشرف على مجموعته والإدارة فقط
CREATE OR REPLACE FUNCTION app_pilgrim_profile(p_token UUID, p_pilgrim_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; r JSON;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE id = p_pilgrim_id;
  IF p.id IS NULL OR NOT _can_manage_group(u, p.group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT json_build_object('id', p.id, 'full_name', us.full_name, 'national_id', us.national_id, 'phone', us.phone,
    'passport_no', p.passport_no, 'blood_type', p.blood_type, 'medical_notes', p.medical_notes,
    'birth_date', p.birth_date, 'age', date_part('year', age(p.birth_date))::int, 'nationality', p.nationality,
    'preferred_language', p.preferred_language, 'priority_level', p.priority_level, 'priority_reason', p.priority_reason,
    'group_id', p.group_id,
    'contacts', (SELECT coalesce(json_agg(json_build_object('name', e.name, 'relation', e.relation, 'phone', e.phone,
                   'is_primary', e.is_primary) ORDER BY e.is_primary DESC), '[]'::json) FROM emergency_contacts e WHERE e.pilgrim_id = p.id),
    'attendance', (SELECT coalesce(json_agg(json_build_object('status', a.status, 'at', a.checkpoint_time, 'location', l.name,
                   'source', a.source, 'gathering', gt.title) ORDER BY a.checkpoint_time DESC), '[]'::json)
                   FROM attendance a LEFT JOIN locations l ON l.id = a.location_id LEFT JOIN gatherings gt ON gt.id = a.gathering_id
                  WHERE a.pilgrim_id = p.id)
  ) INTO r FROM users us WHERE us.id = p.user_id;
  RETURN r;
END $$;

CREATE OR REPLACE FUNCTION app_create_gathering(p_token UUID, p_group_id BIGINT, p_location_id BIGINT, p_title TEXT,
    p_scheduled_at TIMESTAMPTZ, p_deadline_minutes INT DEFAULT 15, p_ritual_id BIGINT DEFAULT NULL, p_trip_id BIGINT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_id BIGINT; v_campaign BIGINT; v_gname TEXT; rec RECORD;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN']::user_role[]);
  IF NOT _can_manage_group(u, p_group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT campaign_id, name INTO v_campaign, v_gname FROM groups WHERE id = p_group_id;
  INSERT INTO gatherings (campaign_id, group_id, ritual_id, trip_id, location_id, title, scheduled_at, deadline_minutes, status, created_by)
  VALUES (v_campaign, p_group_id, p_ritual_id, p_trip_id, p_location_id, btrim(p_title), p_scheduled_at, coalesce(p_deadline_minutes, 15),
          (CASE WHEN p_scheduled_at <= now() + interval '90 minutes' THEN 'OPEN' ELSE 'SCHEDULED' END)::gathering_status, u.id)
  RETURNING id INTO v_id;
  -- إشعار أفراد المجموعة بالتجمع الجديد
  FOR rec IN SELECT user_id FROM pilgrims WHERE group_id = p_group_id LOOP
    PERFORM _notify(rec.user_id, NULL, NULL, 'تجمع جديد: ' || btrim(p_title),
      'الموعد ' || to_char(p_scheduled_at AT TIME ZONE 'Asia/Riyadh', 'HH24:MI') || ' — المهلة ' || coalesce(p_deadline_minutes, 15) || ' دقيقة');
  END LOOP;
  PERFORM _log(u.id, 'CREATE_GATHERING', 'gathering', v_id, p_group_id,
    'فتح تجمع «' || btrim(p_title) || '» لـ' || v_gname || ' الساعة ' || to_char(p_scheduled_at AT TIME ZONE 'Asia/Riyadh', 'HH24:MI'));
  RETURN v_id;
END $$;

-- تسجيل حضور يدوي من المشرف (MANUAL)
CREATE OR REPLACE FUNCTION app_manual_attendance(p_token UUID, p_gathering_id BIGINT, p_pilgrim_id BIGINT, p_status attendance_status)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; g gatherings; v_name TEXT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN']::user_role[]);
  SELECT * INTO g FROM gatherings WHERE id = p_gathering_id;
  IF g.id IS NULL OR NOT _can_manage_group(u, g.group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF NOT EXISTS (SELECT 1 FROM pilgrims WHERE id = p_pilgrim_id AND group_id = g.group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  INSERT INTO attendance (pilgrim_id, location_id, gathering_id, status, source, recorded_by)
  VALUES (p_pilgrim_id, g.location_id, g.id, p_status, 'MANUAL', u.id)
  ON CONFLICT (pilgrim_id, gathering_id) WHERE gathering_id IS NOT NULL
  DO UPDATE SET status = EXCLUDED.status, source = 'MANUAL', recorded_by = u.id, checkpoint_time = now(), synced_at = now();
  IF p_status IN ('PRESENT','LATE') THEN
    UPDATE alerts SET status = 'RESOLVED', resolved_at = now(), resolved_by = u.id
     WHERE pilgrim_id = p_pilgrim_id AND gathering_id = g.id AND type = 'ABSENCE' AND status <> 'RESOLVED';
  END IF;
  SELECT us.full_name INTO v_name FROM pilgrims pp JOIN users us ON us.id = pp.user_id WHERE pp.id = p_pilgrim_id;
  PERFORM _log(u.id, 'MANUAL_ATTENDANCE', 'attendance', p_pilgrim_id, g.group_id,
    'سجّل ' || v_name || ' «' || CASE p_status WHEN 'PRESENT' THEN 'حاضر' WHEN 'LATE' THEN 'متأخر'
      WHEN 'ABSENT' THEN 'غائب' ELSE 'خارج النطاق' END || '» في «' || g.title || '»');
END $$;

-- يبني/يحدّث تقرير المنسك لمجموعة
CREATE OR REPLACE FUNCTION _build_ritual_report(p_ritual BIGINT, p_group BIGINT, p_actor BIGINT, p_comment TEXT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE r rituals; v_id BIGINT; v_total INT; v_gath BIGINT[];
BEGIN
  SELECT * INTO r FROM rituals WHERE id = p_ritual;
  SELECT coalesce(array_agg(id), '{}') INTO v_gath FROM gatherings WHERE ritual_id = p_ritual AND group_id = p_group;
  SELECT count(*) INTO v_total FROM pilgrims WHERE group_id = p_group;

  INSERT INTO ritual_reports AS rr (ritual_id, group_id, total_count, present_count, late_count, absent_count,
        out_of_range_count, alerts_count, sos_count, avg_response_min, avg_rating, supervisor_comment, summary, created_by)
  SELECT p_ritual, p_group, v_total,
    -- لكل حاج: أسوأ حالة له في تجمعات هذا المنسك
    count(*) FILTER (WHERE w.st = 'PRESENT'), count(*) FILTER (WHERE w.st = 'LATE'),
    count(*) FILTER (WHERE w.st = 'ABSENT'),  count(*) FILTER (WHERE w.st = 'OUT_OF_RANGE'),
    (SELECT count(*) FROM alerts a JOIN pilgrims pp ON pp.id = a.pilgrim_id
      WHERE pp.group_id = p_group AND a.created_at BETWEEN r.starts_at AND r.ends_at),
    (SELECT count(*) FROM sos_requests s JOIN pilgrims pp ON pp.id = s.pilgrim_id
      WHERE pp.group_id = p_group AND s.triggered_at BETWEEN r.starts_at AND r.ends_at),
    (SELECT round(avg(extract(epoch FROM a.resolved_at - a.created_at) / 60)::numeric, 1) FROM alerts a JOIN pilgrims pp ON pp.id = a.pilgrim_id
      WHERE pp.group_id = p_group AND a.resolved_at IS NOT NULL AND a.created_at BETWEEN r.starts_at AND r.ends_at),
    (SELECT round(avg(c.rating)::numeric, 2) FROM comments c WHERE c.ritual_id = p_ritual AND c.group_id = p_group AND c.kind = 'PILGRIM_FEEDBACK'),
    p_comment,
    json_build_object(
      'gatherings', (SELECT coalesce(json_agg(json_build_object('title', gt.title, 'scheduled_at', gt.scheduled_at,
          'location', l.name, 'present', (SELECT count(*) FROM attendance a WHERE a.gathering_id = gt.id AND a.status = 'PRESENT'),
          'late', (SELECT count(*) FROM attendance a WHERE a.gathering_id = gt.id AND a.status = 'LATE'),
          'absent', (SELECT count(*) FROM attendance a WHERE a.gathering_id = gt.id AND a.status = 'ABSENT')) ORDER BY gt.scheduled_at), '[]'::json)
          FROM gatherings gt JOIN locations l ON l.id = gt.location_id WHERE gt.id = ANY (v_gath)),
      'issues', (SELECT coalesce(json_agg(json_build_object('name', w2.full_name, 'status', w2.st, 'priority', w2.priority_level)), '[]'::json)
          FROM (SELECT us.full_name, pp.priority_level,
                  (SELECT a.status FROM attendance a WHERE a.pilgrim_id = pp.id AND a.gathering_id = ANY (v_gath)
                    ORDER BY CASE a.status WHEN 'ABSENT' THEN 1 WHEN 'OUT_OF_RANGE' THEN 2 WHEN 'LATE' THEN 3 ELSE 4 END LIMIT 1) AS st
                  FROM pilgrims pp JOIN users us ON us.id = pp.user_id WHERE pp.group_id = p_group) w2
         WHERE w2.st IS DISTINCT FROM 'PRESENT'),
      'feedback', (SELECT coalesce(json_agg(json_build_object('rating', c.rating, 'body', c.body)), '[]'::json)
          FROM comments c WHERE c.ritual_id = p_ritual AND c.group_id = p_group AND c.kind = 'PILGRIM_FEEDBACK' AND c.body <> '')
    )::jsonb,
    p_actor
  FROM (SELECT pp.id,
          coalesce((SELECT a.status FROM attendance a WHERE a.pilgrim_id = pp.id AND a.gathering_id = ANY (v_gath)
                     ORDER BY CASE a.status WHEN 'ABSENT' THEN 1 WHEN 'OUT_OF_RANGE' THEN 2 WHEN 'LATE' THEN 3 ELSE 4 END LIMIT 1),
                   CASE WHEN cardinality(v_gath) > 0 THEN 'ABSENT'::attendance_status END) AS st
          FROM pilgrims pp WHERE pp.group_id = p_group) w
  ON CONFLICT (ritual_id, group_id) DO UPDATE SET
    total_count = EXCLUDED.total_count, present_count = EXCLUDED.present_count, late_count = EXCLUDED.late_count,
    absent_count = EXCLUDED.absent_count, out_of_range_count = EXCLUDED.out_of_range_count,
    alerts_count = EXCLUDED.alerts_count, sos_count = EXCLUDED.sos_count, avg_response_min = EXCLUDED.avg_response_min,
    avg_rating = EXCLUDED.avg_rating, summary = EXCLUDED.summary,
    supervisor_comment = coalesce(EXCLUDED.supervisor_comment, rr.supervisor_comment),
    created_by = coalesce(EXCLUDED.created_by, rr.created_by), updated_at = now()
  RETURNING id INTO v_id;
  RETURN v_id;
END $$;

-- إغلاق التجمع: من لم يسجّل يُسجَّل غائباً + تنبيه غياب + تحديث تقرير المنسك
CREATE OR REPLACE FUNCTION app_close_gathering(p_token UUID, p_gathering_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; g gatherings; v_absent INT; v_report BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN']::user_role[]);
  SELECT * INTO g FROM gatherings WHERE id = p_gathering_id;
  IF g.id IS NULL OR NOT _can_manage_group(u, g.group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;

  INSERT INTO attendance (pilgrim_id, location_id, gathering_id, status, source, recorded_by)
  SELECT pp.id, g.location_id, g.id, 'ABSENT', 'MANUAL', u.id FROM pilgrims pp
   WHERE pp.group_id = g.group_id AND NOT EXISTS (SELECT 1 FROM attendance a WHERE a.gathering_id = g.id AND a.pilgrim_id = pp.id);
  GET DIAGNOSTICS v_absent = ROW_COUNT;

  INSERT INTO alerts (pilgrim_id, location_id, gathering_id, ritual_id, type, severity, note)
  SELECT a.pilgrim_id, g.location_id, g.id, g.ritual_id, 'ABSENCE', _severity('MEDIUM', pp.priority_level), 'غائب عند إغلاق «' || g.title || '»'
    FROM attendance a JOIN pilgrims pp ON pp.id = a.pilgrim_id WHERE a.gathering_id = g.id AND a.status = 'ABSENT'
  ON CONFLICT (pilgrim_id, gathering_id, type) WHERE gathering_id IS NOT NULL DO NOTHING;

  UPDATE gatherings SET status = 'CLOSED', closed_at = now() WHERE id = g.id;
  IF g.ritual_id IS NOT NULL THEN v_report := _build_ritual_report(g.ritual_id, g.group_id, u.id, NULL); END IF;
  PERFORM _log(u.id, 'CLOSE_GATHERING', 'gathering', g.id, g.group_id,
    'أغلق تجمع «' || g.title || '» — غائبون: ' || v_absent);
  RETURN json_build_object('absent', v_absent, 'report_id', v_report);
END $$;

-- إنهاء المنسك لمجموعة + تعليق المشرف → تقرير المنسك النهائي
CREATE OR REPLACE FUNCTION app_finish_ritual(p_token UUID, p_ritual_id BIGINT, p_group_id BIGINT, p_comment TEXT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_id BIGINT; rec RECORD; v_rname TEXT; v_gname TEXT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN']::user_role[]);
  IF NOT _can_manage_group(u, p_group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  FOR rec IN SELECT id FROM gatherings WHERE ritual_id = p_ritual_id AND group_id = p_group_id AND status <> 'CLOSED' LOOP
    PERFORM app_close_gathering(p_token, rec.id);
  END LOOP;
  v_id := _build_ritual_report(p_ritual_id, p_group_id, u.id, nullif(btrim(p_comment), ''));
  IF nullif(btrim(p_comment), '') IS NOT NULL THEN
    INSERT INTO comments (author_id, kind, ritual_id, group_id, body) VALUES (u.id, 'SUPERVISOR_NOTE', p_ritual_id, p_group_id, btrim(p_comment));
  END IF;
  SELECT name INTO v_rname FROM rituals WHERE id = p_ritual_id;
  SELECT name INTO v_gname FROM groups WHERE id = p_group_id;
  PERFORM _log(u.id, 'FINISH_RITUAL', 'ritual_report', v_id, p_group_id, 'أصدر تقرير منسك «' || v_rname || '» لـ' || v_gname);
  -- دعوة الحجاج لتقييم المنسك
  FOR rec IN SELECT user_id FROM pilgrims WHERE group_id = p_group_id LOOP
    PERFORM _notify(rec.user_id, NULL, NULL, 'قيّم تجربتك في ' || v_rname, 'رأيك يساعدنا نحسّن الخدمة في المنسك القادم');
  END LOOP;
  RETURN v_id;
END $$;

-- تعليق مشرف (على منسك/حاج/تنبيه) أو رد الإدارة على تعليق
CREATE OR REPLACE FUNCTION app_add_comment(p_token UUID, p_body TEXT, p_ritual_id BIGINT DEFAULT NULL, p_group_id BIGINT DEFAULT NULL,
    p_pilgrim_id BIGINT DEFAULT NULL, p_alert_id BIGINT DEFAULT NULL, p_parent_id BIGINT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_id BIGINT; v_group BIGINT; v_parent comments;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  IF p_parent_id IS NOT NULL THEN
    SELECT * INTO v_parent FROM comments WHERE id = p_parent_id;
    v_group := v_parent.group_id;
    p_ritual_id := coalesce(p_ritual_id, v_parent.ritual_id);
  ELSE
    v_group := coalesce(p_group_id, (SELECT group_id FROM pilgrims WHERE id = p_pilgrim_id),
                        (SELECT pp.group_id FROM alerts a JOIN pilgrims pp ON pp.id = a.pilgrim_id WHERE a.id = p_alert_id));
  END IF;
  IF u.role = 'SUPERVISOR' AND (v_group IS NULL OR NOT _can_manage_group(u, v_group)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  INSERT INTO comments (author_id, kind, ritual_id, group_id, pilgrim_id, alert_id, parent_id, body)
  VALUES (u.id, CASE WHEN u.role = 'SUPERVISOR' THEN 'SUPERVISOR_NOTE' ELSE 'ADMIN_REPLY' END::comment_kind,
          p_ritual_id, v_group, p_pilgrim_id, p_alert_id, p_parent_id, btrim(p_body))
  RETURNING id INTO v_id;
  IF p_parent_id IS NOT NULL AND v_parent.author_id <> u.id THEN
    PERFORM _notify(v_parent.author_id, NULL, NULL, 'رد من ' || u.full_name, left(btrim(p_body), 140));
  END IF;
  IF u.role = 'SUPERVISOR' THEN
    PERFORM _log(u.id, 'COMMENT', 'comment', v_id, v_group, 'كتب تعليقاً: ' || left(btrim(p_body), 80));
  END IF;
  RETURN v_id;
END $$;

-- رسالة جماعية (المشرف لمجموعته / الإدارة لأي مجموعة أو للحملة كاملة)
CREATE OR REPLACE FUNCTION app_send_broadcast(p_token UUID, p_group_id BIGINT, p_title TEXT, p_body TEXT, p_urgent BOOLEAN DEFAULT FALSE)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_id BIGINT; v_campaign BIGINT; v_n INT := 0; rec RECORD;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  IF p_group_id IS NULL AND u.role = 'SUPERVISOR' THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF p_group_id IS NOT NULL AND NOT _can_manage_group(u, p_group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  v_campaign := coalesce((SELECT campaign_id FROM groups WHERE id = p_group_id),
                         (SELECT id FROM campaigns ORDER BY (status = 'ACTIVE') DESC, id LIMIT 1));
  INSERT INTO broadcasts (campaign_id, group_id, sender_id, title, body, is_urgent)
  VALUES (v_campaign, p_group_id, u.id, btrim(p_title), btrim(p_body), coalesce(p_urgent, FALSE)) RETURNING id INTO v_id;
  FOR rec IN SELECT user_id FROM pilgrims WHERE (p_group_id IS NULL AND campaign_id = v_campaign) OR group_id = p_group_id LOOP
    PERFORM _notify(rec.user_id, NULL, v_id, btrim(p_title), btrim(p_body)); v_n := v_n + 1;
  END LOOP;
  PERFORM _log(u.id, 'BROADCAST', 'broadcast', v_id, p_group_id,
    'أرسل رسالة جماعية «' || btrim(p_title) || '» إلى ' || v_n || ' حاجاً');
  RETURN json_build_object('broadcast_id', v_id, 'recipients', v_n);
END $$;

CREATE OR REPLACE FUNCTION app_set_priority(p_token UUID, p_pilgrim_id BIGINT, p_level priority_level, p_reason TEXT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_group BIGINT; v_name TEXT;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN']::user_role[]);
  SELECT group_id INTO v_group FROM pilgrims WHERE id = p_pilgrim_id;
  IF NOT _can_manage_group(u, v_group) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  UPDATE pilgrims SET priority_manual = TRUE, priority_level = p_level, priority_reason = nullif(btrim(p_reason), '')
   WHERE id = p_pilgrim_id;
  SELECT us.full_name INTO v_name FROM pilgrims pp JOIN users us ON us.id = pp.user_id WHERE pp.id = p_pilgrim_id;
  PERFORM _log(u.id, 'SET_PRIORITY', 'pilgrim', p_pilgrim_id, v_group, 'غيّر أولوية ' || v_name || ' إلى ' || p_level);
END $$;

-- =====================================================================
-- 8) الاستجابة للتنبيهات و SOS (المشرف + الإدارة/مركز العمليات)
-- =====================================================================
CREATE OR REPLACE FUNCTION app_update_alert(p_token UUID, p_alert_id BIGINT, p_status alert_status, p_note TEXT DEFAULT NULL)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; a RECORD;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  SELECT al.*, pp.group_id, us.full_name INTO a FROM alerts al
    LEFT JOIN pilgrims pp ON pp.id = al.pilgrim_id LEFT JOIN users us ON us.id = pp.user_id WHERE al.id = p_alert_id;
  IF a.id IS NULL OR NOT _can_manage_group(u, a.group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  UPDATE alerts SET status = p_status,
    resolved_by = CASE WHEN p_status = 'RESOLVED' THEN u.id ELSE resolved_by END,
    resolved_at = CASE WHEN p_status = 'RESOLVED' THEN now() ELSE NULL END,
    note = coalesce(nullif(btrim(p_note), ''), note)
   WHERE id = p_alert_id;
  UPDATE sos_requests SET
    status = CASE p_status WHEN 'RESOLVED' THEN 'RESOLVED' WHEN 'IN_PROGRESS' THEN 'IN_PROGRESS' ELSE 'PENDING' END::sos_status,
    responder_id = coalesce(responder_id, u.id),
    acknowledged_at = coalesce(acknowledged_at, CASE WHEN p_status <> 'OPEN' THEN now() END),
    resolved_at = CASE WHEN p_status = 'RESOLVED' THEN now() END
   WHERE alert_id = p_alert_id;
  IF p_status = 'RESOLVED' AND a.pilgrim_id IS NOT NULL THEN
    PERFORM _notify((SELECT user_id FROM pilgrims WHERE id = a.pilgrim_id), p_alert_id, NULL, 'تم التعامل مع بلاغك', 'نحن معك — تم إغلاق الحالة');
  ELSIF p_status = 'IN_PROGRESS' AND a.type IN ('SOS', 'LOST') THEN
    PERFORM _notify((SELECT user_id FROM pilgrims WHERE id = a.pilgrim_id), p_alert_id, NULL, 'المساعدة في الطريق', u.full_name || ' يتعامل مع بلاغك الآن');
  END IF;
  PERFORM _log(u.id, CASE WHEN p_status = 'RESOLVED' THEN 'RESOLVE_ALERT' ELSE 'RESPOND_ALERT' END, 'alert', p_alert_id, a.group_id,
    CASE WHEN p_status = 'RESOLVED' THEN 'أغلق تنبيه ' ELSE 'بدأ الاستجابة لتنبيه ' END || _alert_label(a.type) || ' — ' || coalesce(a.full_name, '')
    || coalesce(' (' || nullif(btrim(p_note), '') || ')', ''));
END $$;

-- أقرب المستجيبين (مشرفون) لموقع بلاغ
CREATE OR REPLACE FUNCTION app_nearest_responders(p_token UUID, p_alert_id BIGINT)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; a alerts;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  SELECT * INTO a FROM alerts WHERE id = p_alert_id;
  RETURN (SELECT coalesce(json_agg(x ORDER BY x.distance_m NULLS LAST), '[]'::json) FROM (
    SELECT us.id, us.full_name, us.phone, s.job_title,
           _dist_m(a.latitude, a.longitude, lp.latitude, lp.longitude) AS distance_m, lp.client_recorded_at AS seen_at
      FROM supervisors s JOIN users us ON us.id = s.user_id
      LEFT JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = us.id ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
     WHERE us.is_active LIMIT 10) x);
END $$;

-- =====================================================================
-- 9) خدمات الإدارة
-- =====================================================================
CREATE OR REPLACE FUNCTION app_create_pilgrim(p_token UUID, p_full_name TEXT, p_national_id TEXT, p_phone TEXT, p_password TEXT,
    p_group_id BIGINT, p_birth_date DATE DEFAULT NULL, p_nationality TEXT DEFAULT NULL, p_language TEXT DEFAULT 'ar',
    p_passport_no TEXT DEFAULT NULL, p_blood_type TEXT DEFAULT NULL, p_medical_notes TEXT DEFAULT NULL)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, extensions AS $$
DECLARE u users; v_user BIGINT; v_pid BIGINT; v_campaign BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['ADMIN','SUPERVISOR']::user_role[]);
  IF NOT _can_manage_group(u, p_group_id) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  SELECT campaign_id INTO v_campaign FROM groups WHERE id = p_group_id;
  INSERT INTO users (full_name, national_id, phone, password_hash, role)
  VALUES (btrim(p_full_name), btrim(p_national_id), regexp_replace(p_phone, '[^0-9+]', '', 'g'), crypt(p_password, gen_salt('bf')), 'PILGRIM')
  RETURNING id INTO v_user;
  INSERT INTO pilgrims (user_id, campaign_id, group_id, birth_date, nationality, preferred_language, passport_no, blood_type, medical_notes)
  VALUES (v_user, v_campaign, p_group_id, p_birth_date, nullif(btrim(p_nationality), ''), coalesce(p_language, 'ar'),
          nullif(btrim(p_passport_no), ''), nullif(btrim(p_blood_type), ''), nullif(btrim(p_medical_notes), ''))
  RETURNING id INTO v_pid;
  PERFORM _log(u.id, 'CREATE_PILGRIM', 'pilgrim', v_pid, p_group_id, 'أضاف الحاج ' || btrim(p_full_name));
  RETURN v_pid;
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'DUPLICATE_ID' USING HINT = 'رقم الهوية مُسجَّل مسبقاً';
END $$;

CREATE OR REPLACE FUNCTION app_save_group(p_token UUID, p_id BIGINT, p_name TEXT, p_capacity INT, p_supervisor_id BIGINT)
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_id BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['ADMIN']::user_role[]);
  IF p_id IS NULL THEN
    INSERT INTO groups (campaign_id, name, capacity, supervisor_id)
    VALUES ((SELECT id FROM campaigns ORDER BY (status = 'ACTIVE') DESC, id LIMIT 1), btrim(p_name), p_capacity, p_supervisor_id)
    RETURNING id INTO v_id;
  ELSE
    IF p_capacity < (SELECT count(*) FROM pilgrims WHERE group_id = p_id) THEN
      RAISE EXCEPTION 'CAPACITY_TOO_SMALL' USING HINT = 'السعة أقل من عدد الحجاج الحاليين';
    END IF;
    UPDATE groups SET name = btrim(p_name), capacity = p_capacity, supervisor_id = p_supervisor_id WHERE id = p_id RETURNING id INTO v_id;
  END IF;
  PERFORM _log(u.id, 'SAVE_GROUP', 'group', v_id, v_id, 'حفظ بيانات المجموعة ' || btrim(p_name));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION app_save_trip(p_token UUID, p_id BIGINT, p_vehicle TEXT, p_driver TEXT, p_from BIGINT, p_to BIGINT,
    p_departure TIMESTAMPTZ, p_group_ids BIGINT[])
RETURNS BIGINT LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_id BIGINT;
BEGIN
  u := _auth(p_token, ARRAY['ADMIN']::user_role[]);
  IF p_id IS NULL THEN
    INSERT INTO trips (vehicle_no, driver_name, route_from_id, route_to_id, departure_time)
    VALUES (btrim(p_vehicle), btrim(p_driver), p_from, p_to, p_departure) RETURNING id INTO v_id;
  ELSE
    UPDATE trips SET vehicle_no = btrim(p_vehicle), driver_name = btrim(p_driver), route_from_id = p_from, route_to_id = p_to,
           departure_time = p_departure WHERE id = p_id RETURNING id INTO v_id;
    DELETE FROM trip_groups WHERE trip_id = v_id;
  END IF;
  INSERT INTO trip_groups (trip_id, group_id) SELECT v_id, unnest(coalesce(p_group_ids, '{}')) ON CONFLICT DO NOTHING;
  PERFORM _log(u.id, 'SAVE_TRIP', 'trip', v_id, NULL, 'حفظ رحلة الحافلة ' || btrim(p_vehicle));
  RETURN v_id;
END $$;

CREATE OR REPLACE FUNCTION app_set_trip_status(p_token UUID, p_trip_id BIGINT, p_status trip_status)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_ok BOOLEAN; v_vehicle TEXT;
BEGIN
  u := _auth(p_token, ARRAY['ADMIN','SUPERVISOR','OPERATIONS_CENTER']::user_role[]);
  SELECT bool_or(_can_manage_group(u, tg.group_id)) INTO v_ok FROM trip_groups tg WHERE tg.trip_id = p_trip_id;
  IF NOT coalesce(v_ok, u.role = 'ADMIN') THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  UPDATE trips SET status = p_status,
    departure_time = CASE WHEN p_status = 'IN_PROGRESS' THEN coalesce(departure_time, now()) ELSE departure_time END,
    arrival_time   = CASE WHEN p_status = 'COMPLETED' THEN now() ELSE arrival_time END
   WHERE id = p_trip_id RETURNING vehicle_no INTO v_vehicle;
  PERFORM _log(u.id, 'TRIP_STATUS', 'trip', p_trip_id, NULL, 'حالة الحافلة ' || v_vehicle || ' ← ' || p_status);
END $$;

CREATE OR REPLACE FUNCTION app_set_ritual_status(p_token UUID, p_ritual_id BIGINT, p_status ritual_status)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_name TEXT; rec RECORD;
BEGIN
  u := _auth(p_token, ARRAY['ADMIN']::user_role[]);
  UPDATE rituals SET status = p_status WHERE id = p_ritual_id RETURNING name INTO v_name;
  IF p_status = 'COMPLETED' THEN   -- تقرير لكل مجموعة لم يُصدر لها تقرير بعد
    FOR rec IN SELECT g.id FROM groups g WHERE g.campaign_id = (SELECT campaign_id FROM rituals WHERE id = p_ritual_id) LOOP
      PERFORM _build_ritual_report(p_ritual_id, rec.id, NULL, NULL);
    END LOOP;
  END IF;
  PERFORM _log(u.id, 'RITUAL_STATUS', 'ritual', p_ritual_id, NULL, 'حالة منسك «' || v_name || '» ← ' || p_status);
END $$;

-- مؤشرات الأداء
CREATE OR REPLACE FUNCTION app_kpis(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_groups BIGINT[];
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  v_groups := _visible_groups(u);
  RETURN (
    WITH pg AS (SELECT * FROM pilgrims WHERE group_id = ANY (v_groups)),
         al AS (SELECT a.* FROM alerts a JOIN pg ON pg.id = a.pilgrim_id),
         att AS (SELECT a.* FROM attendance a JOIN gatherings gt ON gt.id = a.gathering_id WHERE gt.group_id = ANY (v_groups))
    SELECT json_build_object(
      'pilgrims', (SELECT count(*) FROM pg),
      'groups', cardinality(v_groups),
      'high_priority', (SELECT count(*) FROM pg WHERE priority_level <> 'NORMAL'),
      'non_arabic', (SELECT count(*) FROM pg WHERE preferred_language <> 'ar'),
      'open_alerts', (SELECT count(*) FROM al WHERE status <> 'RESOLVED'),
      'open_sos', (SELECT count(*) FROM al WHERE status <> 'RESOLVED' AND type IN ('SOS','LOST')),
      'escalated', (SELECT count(*) FROM al WHERE status <> 'RESOLVED' AND escalated_at IS NOT NULL),
      'attendance_rate', (SELECT round(100.0 * count(*) FILTER (WHERE status IN ('PRESENT','LATE')) / nullif(count(*), 0)) FROM att),
      'on_time_rate', (SELECT round(100.0 * count(*) FILTER (WHERE status = 'PRESENT') / nullif(count(*), 0)) FROM att),
      'avg_response_min', (SELECT round(avg(extract(epoch FROM resolved_at - created_at) / 60)::numeric, 1)
                             FROM al WHERE type IN ('SOS','LOST') AND resolved_at IS NOT NULL),
      'avg_rating', (SELECT round(avg(rating)::numeric, 1) FROM comments WHERE kind = 'PILGRIM_FEEDBACK' AND group_id = ANY (v_groups)),
      'tracked_now', (SELECT count(DISTINCT lp.user_id) FROM location_pings lp JOIN pg ON pg.user_id = lp.user_id
                        WHERE lp.client_recorded_at > now() - interval '30 minutes'),
      'alerts_by_type', (SELECT coalesce(json_object_agg(type, n), '{}'::json) FROM (SELECT type, count(*) n FROM al GROUP BY type) t),
      'by_group', (SELECT coalesce(json_agg(json_build_object('group', g.name,
          'rate', (SELECT round(100.0 * count(*) FILTER (WHERE a.status IN ('PRESENT','LATE')) / nullif(count(*), 0))
                     FROM att a JOIN gatherings gt ON gt.id = a.gathering_id WHERE gt.group_id = g.id),
          'open', (SELECT count(*) FROM al JOIN pilgrims p2 ON p2.id = al.pilgrim_id WHERE p2.group_id = g.id AND al.status <> 'RESOLVED'))
          ORDER BY g.id), '[]'::json) FROM groups g WHERE g.id = ANY (v_groups))
    ));
END $$;

-- آخر المواقع للخريطة الحية (المشرف: مجموعته فقط)
CREATE OR REPLACE FUNCTION app_live_positions(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_groups BIGINT[];
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  v_groups := _visible_groups(u);
  RETURN json_build_object(
    'pilgrims', (SELECT coalesce(json_agg(json_build_object('pilgrim_id', pp.id, 'name', us.full_name, 'group', g.name,
        'priority', pp.priority_level, 'lat', lp.latitude, 'lng', lp.longitude, 'at', lp.client_recorded_at, 'battery', lp.battery_pct,
        'status', (SELECT a.status FROM attendance a WHERE a.pilgrim_id = pp.id ORDER BY a.checkpoint_time DESC LIMIT 1),
        'open_alert', (SELECT a.type FROM alerts a WHERE a.pilgrim_id = pp.id AND a.status <> 'RESOLVED' ORDER BY a.created_at DESC LIMIT 1))), '[]'::json)
      FROM pilgrims pp JOIN users us ON us.id = pp.user_id LEFT JOIN groups g ON g.id = pp.group_id
      JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = pp.user_id ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
     WHERE pp.group_id = ANY (v_groups)),
    'supervisors', (SELECT coalesce(json_agg(json_build_object('name', us.full_name, 'lat', lp.latitude, 'lng', lp.longitude,
        'at', lp.client_recorded_at)), '[]'::json)
      FROM supervisors s JOIN users us ON us.id = s.user_id
      JOIN LATERAL (SELECT * FROM location_pings l WHERE l.user_id = us.id ORDER BY l.client_recorded_at DESC LIMIT 1) lp ON TRUE
     WHERE u.role <> 'SUPERVISOR' OR s.user_id = u.id)
  );
END $$;

-- نبضة دورية من لوحة التحكم: فتح التجمعات القريبة، تنبيه الغياب بعد المهلة، تصعيد البلاغات المتأخرة
CREATE OR REPLACE FUNCTION app_tick(p_token UUID)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; v_opened INT; v_absence INT; v_escalated INT; rec RECORD;
BEGIN
  u := _auth(p_token, ARRAY['SUPERVISOR','ADMIN','OPERATIONS_CENTER']::user_role[]);
  UPDATE gatherings SET status = 'OPEN' WHERE status = 'SCHEDULED' AND scheduled_at <= now() + interval '90 minutes';
  GET DIAGNOSTICS v_opened = ROW_COUNT;

  -- انتهت المهلة ولم يسجّل → تنبيه غياب فوري (يُغلق تلقائياً إن سجّل لاحقاً)
  WITH ins AS (
    INSERT INTO alerts (pilgrim_id, location_id, gathering_id, ritual_id, type, severity, note)
    SELECT pp.id, gt.location_id, gt.id, gt.ritual_id, 'ABSENCE', _severity('MEDIUM', pp.priority_level),
           'لم يسجّل حضوره في «' || gt.title || '» بعد انتهاء المهلة'
      FROM gatherings gt JOIN pilgrims pp ON pp.group_id = gt.group_id
     WHERE gt.status = 'OPEN' AND now() > gt.scheduled_at + make_interval(mins => gt.deadline_minutes)
       AND NOT EXISTS (SELECT 1 FROM attendance a WHERE a.gathering_id = gt.id AND a.pilgrim_id = pp.id)
    ON CONFLICT (pilgrim_id, gathering_id, type) WHERE gathering_id IS NOT NULL DO NOTHING
    RETURNING id, pilgrim_id)
  SELECT count(*) INTO v_absence FROM ins;

  FOR rec IN SELECT a.id, us.full_name, _group_supervisor_user(pp.group_id) AS sup FROM alerts a
       JOIN pilgrims pp ON pp.id = a.pilgrim_id JOIN users us ON us.id = pp.user_id
      WHERE a.type = 'ABSENCE' AND a.status = 'OPEN' AND a.created_at > now() - interval '2 minutes'
        AND NOT EXISTS (SELECT 1 FROM notifications n WHERE n.alert_id = a.id) LOOP
    IF rec.sup IS NOT NULL THEN PERFORM _notify(rec.sup, rec.id, NULL, 'غياب بعد المهلة', rec.full_name || ' لم يسجّل حضوره'); END IF;
  END LOOP;

  -- SOS / تائه بدون استجابة لأكثر من دقيقتين → تصعيد للإدارة
  WITH esc AS (
    UPDATE alerts SET escalated_at = now()
     WHERE type IN ('SOS','LOST') AND status = 'OPEN' AND escalated_at IS NULL AND created_at < now() - interval '2 minutes'
    RETURNING id)
  SELECT count(*) INTO v_escalated FROM esc;
  IF v_escalated > 0 THEN
    FOR rec IN SELECT id FROM users WHERE role = 'ADMIN' AND is_active LOOP
      PERFORM _notify(rec.id, NULL, NULL, 'تصعيد', v_escalated || ' بلاغ بدون استجابة لأكثر من دقيقتين');
    END LOOP;
  END IF;

  UPDATE rituals SET status = 'IN_PROGRESS' WHERE status = 'UPCOMING' AND starts_at <= now() AND ends_at > now();
  RETURN json_build_object('opened', v_opened, 'absence_alerts', v_absence, 'escalated', v_escalated,
                           'unread', (SELECT count(*) FROM notifications WHERE user_id = u.id AND read_at IS NULL));
END $$;

-- =====================================================================
-- 10) الصلاحيات: القراءة التشغيلية مفتوحة، والحساس والكتابة عبر الدوال فقط
-- =====================================================================
DO $$
DECLARE t TEXT;
BEGIN
  FOREACH t IN ARRAY ARRAY['users','campaigns','supervisors','groups','pilgrims','locations','attendance','trips','trip_groups',
                           'alerts','sos_requests','emergency_contacts','notifications','rituals','gatherings','location_pings',
                           'ritual_reports','broadcasts','comments','activity_log','app_sessions'] LOOP
    EXECUTE format('ALTER TABLE public.%I ENABLE ROW LEVEL SECURITY', t);
    EXECUTE format('DROP POLICY IF EXISTS app_read   ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS app_insert ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS app_update ON public.%I', t);
    EXECUTE format('DROP POLICY IF EXISTS app_delete ON public.%I', t);
    EXECUTE format('REVOKE ALL ON public.%I FROM anon, authenticated', t);
  END LOOP;
  -- جداول تشغيلية تُقرأ مباشرة من لوحة التحكم
  FOREACH t IN ARRAY ARRAY['campaigns','supervisors','groups','locations','attendance','trips','trip_groups','alerts',
                           'sos_requests','rituals','gatherings','ritual_reports','broadcasts','comments','activity_log'] LOOP
    EXECUTE format('GRANT SELECT ON public.%I TO anon, authenticated', t);
    EXECUTE format('CREATE POLICY app_read ON public.%I FOR SELECT TO anon, authenticated USING (true)', t);
  END LOOP;
END $$;

-- users: بدون كلمة المرور. pilgrims: بدون البيانات الطبية والجواز وتاريخ الميلاد
GRANT SELECT (id, full_name, national_id, phone, role, is_active, created_at) ON users TO anon, authenticated;
CREATE POLICY app_read ON users FOR SELECT TO anon, authenticated USING (true);
GRANT SELECT (id, user_id, campaign_id, group_id, nationality, preferred_language, large_text, priority_level, priority_reason, created_at)
  ON pilgrims TO anon, authenticated;
CREATE POLICY app_read ON pilgrims FOR SELECT TO anon, authenticated USING (true);
-- emergency_contacts / notifications / location_pings / app_sessions: لا قراءة مباشرة إطلاقاً (عبر الدوال فقط)

-- الدوال الداخلية مغلقة، ودوال app_* متاحة (كل منها يتحقق من الجلسة والدور)
DO $$
DECLARE f RECORD;
BEGIN
  FOR f IN SELECT p.oid::regprocedure AS sig, p.proname FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'public' AND (p.proname LIKE 'app\_%' OR p.proname LIKE '\_%' OR p.proname IN ('create_pilgrim','verify_login')) LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated', f.sig);
    IF f.proname LIKE 'app\_%' OR f.proname = 'verify_login' THEN
      EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO anon, authenticated', f.sig);
    END IF;
  END LOOP;
END $$;
-- (create_pilgrim القديمة أُغلقت: كانت تسمح لأي زائر بإضافة حاج. البديل app_create_pilgrim)

-- تحقق: يجب أن يظهر 21 جدولاً
SELECT count(*) AS tables_count FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';
