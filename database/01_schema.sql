-- =====================================================================
-- عين الحملة — قاعدة بيانات منصة إدارة وتتبع حجاج الحملات
-- PostgreSQL 16 — schema.sql
-- 13 جدولاً موزعة على 4 مجموعات وظيفية، مطابقة لمخطط ERD على dbdiagram.io
-- (نسخة بدون هاردوير: لا أجهزة NFC/QR/BLE — الحضور والتتبع بالكامل عبر التطبيق)
-- =====================================================================

BEGIN;

-- ---------------------------------------------------------------------
-- ENUM types
-- ---------------------------------------------------------------------
CREATE TYPE user_role            AS ENUM ('ADMIN', 'SUPERVISOR', 'PILGRIM', 'OPERATIONS_CENTER');
CREATE TYPE campaign_status      AS ENUM ('UPCOMING', 'ACTIVE', 'COMPLETED');
CREATE TYPE location_type        AS ENUM ('CHECKPOINT', 'SAFE_ZONE');
CREATE TYPE attendance_status    AS ENUM ('PRESENT', 'LATE', 'ABSENT', 'OUT_OF_RANGE');
CREATE TYPE attendance_source    AS ENUM ('APP_CHECKIN', 'GPS', 'MANUAL');
CREATE TYPE trip_status          AS ENUM ('SCHEDULED', 'IN_PROGRESS', 'COMPLETED');
CREATE TYPE alert_type           AS ENUM ('ABSENCE', 'DELAY', 'GEOFENCE_BREACH', 'SOS');
CREATE TYPE alert_severity       AS ENUM ('LOW', 'MEDIUM', 'CRITICAL');
CREATE TYPE alert_status         AS ENUM ('OPEN', 'IN_PROGRESS', 'RESOLVED');
CREATE TYPE sos_status           AS ENUM ('PENDING', 'IN_PROGRESS', 'RESOLVED');
CREATE TYPE notification_channel AS ENUM ('PUSH', 'SMS');

-- =====================================================================
-- المجموعة 1: الهوية والمستخدمون
-- =====================================================================

CREATE TABLE users (
      id              BIGSERIAL PRIMARY KEY,
      full_name       VARCHAR(150)    NOT NULL,
      national_id     VARCHAR(20)     NOT NULL UNIQUE,
      phone           VARCHAR(20)     NOT NULL,
      password_hash   TEXT            NOT NULL,
      role            user_role       NOT NULL,
      is_active       BOOLEAN         NOT NULL DEFAULT TRUE,
      created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
      updated_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
      CONSTRAINT chk_users_national_id_len CHECK (length(national_id) BETWEEN 5 AND 20),
      CONSTRAINT chk_users_phone_format    CHECK (phone ~ '^\+?[0-9]{7,15}$')
  );

CREATE TABLE campaigns (
      id              BIGSERIAL PRIMARY KEY,
      name            VARCHAR(200)    NOT NULL,
      license_no      VARCHAR(50)     NOT NULL UNIQUE,
      start_date      DATE            NOT NULL,
      end_date        DATE            NOT NULL,
      admin_id        BIGINT          REFERENCES users(id),
      status          campaign_status NOT NULL DEFAULT 'UPCOMING',
      CONSTRAINT chk_campaign_dates CHECK (end_date >= start_date)
  );

CREATE TABLE supervisors (
      id              BIGSERIAL PRIMARY KEY,
      user_id         BIGINT          NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
      campaign_id     BIGINT          REFERENCES campaigns(id) ON DELETE SET NULL,
      job_title       VARCHAR(150),
      created_at      TIMESTAMPTZ     NOT NULL DEFAULT now()
  );

CREATE TABLE groups (
      id              BIGSERIAL PRIMARY KEY,
      campaign_id     BIGINT          NOT NULL REFERENCES campaigns(id) ON DELETE CASCADE,
      name            VARCHAR(150)    NOT NULL,
      supervisor_id   BIGINT          REFERENCES supervisors(id) ON DELETE SET NULL,
      capacity        INT             NOT NULL CHECK (capacity > 0)
  );

CREATE TABLE pilgrims (
      id              BIGSERIAL PRIMARY KEY,
      user_id         BIGINT          NOT NULL UNIQUE REFERENCES users(id) ON DELETE CASCADE,
      campaign_id     BIGINT          REFERENCES campaigns(id) ON DELETE SET NULL,
      group_id        BIGINT          REFERENCES groups(id) ON DELETE SET NULL,
      passport_no     VARCHAR(30),
      blood_type      VARCHAR(5),
      medical_notes   TEXT,
      created_at      TIMESTAMPTZ     NOT NULL DEFAULT now()
  );

-- =====================================================================
-- المجموعة 2: التتبع والموقع والتنقلات
-- =====================================================================

CREATE TABLE locations (
      id              BIGSERIAL PRIMARY KEY,
      campaign_id     BIGINT          REFERENCES campaigns(id) ON DELETE CASCADE,
      name            VARCHAR(150)    NOT NULL,
      type            location_type   NOT NULL,
      latitude        NUMERIC(9,6)    NOT NULL CHECK (latitude  BETWEEN -90  AND 90),
      longitude       NUMERIC(9,6)    NOT NULL CHECK (longitude BETWEEN -180 AND 180),
      radius_meters   INT             NOT NULL DEFAULT 100 CHECK (radius_meters > 0)
  );

CREATE TABLE attendance (
      id              BIGSERIAL PRIMARY KEY,
      pilgrim_id      BIGINT          NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
      location_id     BIGINT          REFERENCES locations(id) ON DELETE SET NULL,
      checkpoint_time TIMESTAMPTZ     NOT NULL DEFAULT now(),
      status          attendance_status NOT NULL,
      source          attendance_source NOT NULL
  );

CREATE TABLE trips (
      id              BIGSERIAL PRIMARY KEY,
      vehicle_no      VARCHAR(30)     NOT NULL,
      driver_name     VARCHAR(150)    NOT NULL,
      route_from_id   BIGINT          REFERENCES locations(id),
      route_to_id     BIGINT          REFERENCES locations(id),
      departure_time  TIMESTAMPTZ,
      arrival_time    TIMESTAMPTZ,
      status          trip_status     NOT NULL DEFAULT 'SCHEDULED'
  );

-- جدول ربط Many-to-Many بين الرحلات والمجموعات
CREATE TABLE trip_groups (
      trip_id         BIGINT          NOT NULL REFERENCES trips(id) ON DELETE CASCADE,
      group_id        BIGINT          NOT NULL REFERENCES groups(id) ON DELETE CASCADE,
      PRIMARY KEY (trip_id, group_id)
  );

-- =====================================================================
-- المجموعة 3: السلامة والتنبيهات
-- =====================================================================

CREATE TABLE alerts (
      id              BIGSERIAL PRIMARY KEY,
      pilgrim_id      BIGINT          REFERENCES pilgrims(id) ON DELETE CASCADE,
      location_id     BIGINT          REFERENCES locations(id) ON DELETE SET NULL,
      type            alert_type      NOT NULL,
      severity        alert_severity  NOT NULL,
      status          alert_status    NOT NULL DEFAULT 'OPEN',
      resolved_by     BIGINT          REFERENCES users(id),
      created_at      TIMESTAMPTZ     NOT NULL DEFAULT now(),
      resolved_at     TIMESTAMPTZ
  );

CREATE TABLE sos_requests (
      id              BIGSERIAL PRIMARY KEY,
      alert_id        BIGINT          UNIQUE REFERENCES alerts(id) ON DELETE CASCADE,
      pilgrim_id      BIGINT          NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
      latitude        NUMERIC(9,6)    CHECK (latitude  IS NULL OR latitude  BETWEEN -90  AND 90),
      longitude       NUMERIC(9,6)    CHECK (longitude IS NULL OR longitude BETWEEN -180 AND 180),
      responder_id    BIGINT          REFERENCES users(id),
      status          sos_status      NOT NULL DEFAULT 'PENDING',
      triggered_at    TIMESTAMPTZ     NOT NULL DEFAULT now(),
      resolved_at     TIMESTAMPTZ
  );

CREATE TABLE emergency_contacts (
      id              BIGSERIAL PRIMARY KEY,
      pilgrim_id      BIGINT          NOT NULL REFERENCES pilgrims(id) ON DELETE CASCADE,
      name            VARCHAR(150)    NOT NULL,
      relation        VARCHAR(50),
      phone           VARCHAR(20)     NOT NULL,
      is_primary      BOOLEAN         NOT NULL DEFAULT FALSE,
      CONSTRAINT chk_emergency_contacts_phone_format CHECK (phone ~ '^\+?[0-9]{7,15}$')
  );

CREATE TABLE notifications (
      id              BIGSERIAL PRIMARY KEY,
      user_id         BIGINT          NOT NULL REFERENCES users(id) ON DELETE CASCADE,
      alert_id        BIGINT          REFERENCES alerts(id) ON DELETE SET NULL,
      channel         notification_channel NOT NULL,
      sent_at         TIMESTAMPTZ     NOT NULL DEFAULT now(),
      read_at         TIMESTAMPTZ
  );

COMMIT;

-- =====================================================================
-- الفهارس (Indexes)
-- =====================================================================

CREATE INDEX idx_alerts_pilgrim_created       ON alerts (pilgrim_id, created_at);
CREATE INDEX idx_attendance_pilgrim_checkpoint ON attendance (pilgrim_id, checkpoint_time);
CREATE INDEX idx_locations_lat_lng            ON locations (latitude, longitude);

-- فهارس جزئية للحالات المفتوحة/النشطة (تسريع لوحات التحكم اللحظية)
CREATE INDEX idx_alerts_open        ON alerts (status)        WHERE status <> 'RESOLVED';
CREATE INDEX idx_sos_requests_open  ON sos_requests (status)  WHERE status <> 'RESOLVED';

-- فهرس فريد جزئي: جهة اتصال طارئة رئيسية واحدة فقط لكل حاج
CREATE UNIQUE INDEX uq_emergency_contacts_primary
    ON emergency_contacts (pilgrim_id)
    WHERE is_primary = TRUE;

CREATE INDEX idx_campaigns_admin_id        ON campaigns (admin_id);
CREATE INDEX idx_supervisors_campaign_id   ON supervisors (campaign_id);
CREATE INDEX idx_groups_campaign_id        ON groups (campaign_id);
CREATE INDEX idx_groups_supervisor_id      ON groups (supervisor_id);
CREATE INDEX idx_pilgrims_campaign_id      ON pilgrims (campaign_id);
CREATE INDEX idx_pilgrims_group_id         ON pilgrims (group_id);
CREATE INDEX idx_locations_campaign_id     ON locations (campaign_id);
CREATE INDEX idx_attendance_location_id    ON attendance (location_id);
CREATE INDEX idx_trips_route_from_id       ON trips (route_from_id);
CREATE INDEX idx_trips_route_to_id         ON trips (route_to_id);
CREATE INDEX idx_trip_groups_group_id      ON trip_groups (group_id);
CREATE INDEX idx_alerts_location_id        ON alerts (location_id);
CREATE INDEX idx_alerts_resolved_by        ON alerts (resolved_by);
CREATE INDEX idx_sos_requests_pilgrim_id   ON sos_requests (pilgrim_id);
CREATE INDEX idx_sos_requests_responder_id ON sos_requests (responder_id);
CREATE INDEX idx_emergency_contacts_pilgrim_id ON emergency_contacts (pilgrim_id);
CREATE INDEX idx_notifications_user_id     ON notifications (user_id);
CREATE INDEX idx_notifications_alert_id    ON notifications (alert_id);

CREATE INDEX idx_users_role       ON users (role);
CREATE INDEX idx_campaigns_status ON campaigns (status);
CREATE INDEX idx_trips_status     ON trips (status);

-- =====================================================================
-- Triggers
-- =====================================================================

CREATE OR REPLACE FUNCTION trg_set_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER users_set_updated_at
    BEFORE UPDATE ON users
    FOR EACH ROW
    EXECUTE FUNCTION trg_set_updated_at();

CREATE OR REPLACE FUNCTION trg_check_group_capacity()
RETURNS TRIGGER AS $$
DECLARE
    v_capacity  INT;
    v_current   INT;
BEGIN
    IF NEW.group_id IS NULL THEN
        RETURN NEW;
    END IF;

    IF TG_OP = 'UPDATE' AND NEW.group_id IS NOT DISTINCT FROM OLD.group_id THEN
        RETURN NEW;
    END IF;

    SELECT capacity INTO v_capacity FROM groups WHERE id = NEW.group_id;
    IF v_capacity IS NULL THEN
        RAISE EXCEPTION 'المجموعة % غير موجودة', NEW.group_id;
    END IF;

    SELECT COUNT(*) INTO v_current FROM pilgrims WHERE group_id = NEW.group_id;

    IF v_current >= v_capacity THEN
        RAISE EXCEPTION 'تجاوز السعة القصوى للمجموعة % (السعة: %، الحالي: %)',
            NEW.group_id, v_capacity, v_current;
    END IF;

    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER pilgrims_check_group_capacity
    BEFORE INSERT OR UPDATE OF group_id ON pilgrims
    FOR EACH ROW
    EXECUTE FUNCTION trg_check_group_capacity();

-- =====================================================================
-- Row Level Security — يُفعَّل على جميع الجداول الـ13
-- =====================================================================
-- ملاحظة: لا سياسات (policies) مضافة هنا عمداً. بدون سياسات، تصبح كل
-- الجداول مقفلة أمام anon/authenticated، ولا يستثنى منها إلا service_role.
-- سياسات الوصول الفعلية تُضاف لاحقاً بعد اعتماد نموذج المصادقة بالتطبيق.

ALTER TABLE users               ENABLE ROW LEVEL SECURITY;
ALTER TABLE campaigns           ENABLE ROW LEVEL SECURITY;
ALTER TABLE supervisors         ENABLE ROW LEVEL SECURITY;
ALTER TABLE groups              ENABLE ROW LEVEL SECURITY;
ALTER TABLE pilgrims            ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations           ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance          ENABLE ROW LEVEL SECURITY;
ALTER TABLE trips               ENABLE ROW LEVEL SECURITY;
ALTER TABLE trip_groups         ENABLE ROW LEVEL SECURITY;
ALTER TABLE alerts              ENABLE ROW LEVEL SECURITY;
ALTER TABLE sos_requests        ENABLE ROW LEVEL SECURITY;
ALTER TABLE emergency_contacts  ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications       ENABLE ROW LEVEL SECURITY;

-- ملاحظة مستقبلية: دعم PostGIS اختياري لاستعلامات جغرافية دقيقة
-- CREATE EXTENSION IF NOT EXISTS postgis;
-- ALTER TABLE locations ADD COLUMN geog geography(Point, 4326);
-- ALTER TABLE sos_requests ADD COLUMN geog geography(Point, 4326);
