-- =====================================================================
-- عين الحملة — بيانات تجريبية (seed.sql)
-- يُنفَّذ فوق schema.sql — يغطي جميع الجداول الـ13 بسيناريو واقعي متكامل
-- (نسخة بدون هاردوير: لا جدول devices — الحضور مصدره APP_CHECKIN/GPS/MANUAL)
-- =====================================================================

BEGIN;

INSERT INTO users (id, full_name, national_id, phone, password_hash, role, is_active) VALUES
 (1,  'علي الحربي',       '1010101010', '0500000001', '$2b$12$dummyhash0000000000000000000000000000000001', 'ADMIN',             TRUE),
 (2,  'مركز العمليات',     '1010101011', '0500000002', '$2b$12$dummyhash0000000000000000000000000000000002', 'OPERATIONS_CENTER', TRUE),
 (3,  'خالد العتيبي',      '1020202020', '0500000003', '$2b$12$dummyhash0000000000000000000000000000000003', 'SUPERVISOR',        TRUE),
 (4,  'سعيد الزهراني',     '1020202021', '0500000004', '$2b$12$dummyhash0000000000000000000000000000000004', 'SUPERVISOR',        TRUE),
 (5,  'محمد أحمد',         '1030303030', '0500000005', '$2b$12$dummyhash0000000000000000000000000000000005', 'PILGRIM',           TRUE),
 (6,  'عبدالله سالم',      '1030303031', '0500000006', '$2b$12$dummyhash0000000000000000000000000000000006', 'PILGRIM',           TRUE),
 (7,  'يوسف ناصر',         '1030303032', '0500000007', '$2b$12$dummyhash0000000000000000000000000000000007', 'PILGRIM',           TRUE),
 (8,  'فيصل عمر',          '1030303033', '0500000008', '$2b$12$dummyhash0000000000000000000000000000000008', 'PILGRIM',           TRUE),
 (9,  'ماجد راشد',         '1030303034', '0500000009', '$2b$12$dummyhash0000000000000000000000000000000009', 'PILGRIM',           TRUE),
 (10, 'طارق حمزة',         '1030303035', '0500000010', '$2b$12$dummyhash0000000000000000000000000000000010', 'PILGRIM',           FALSE);

SELECT setval('users_id_seq', 10);

INSERT INTO campaigns (id, name, license_no, start_date, end_date, admin_id, status) VALUES
 (1, 'حملة الرحمة للحج 1447هـ', 'LIC-1447-0001', '2026-05-20', '2026-06-05', 1, 'ACTIVE');

SELECT setval('campaigns_id_seq', 1);

INSERT INTO supervisors (id, user_id, campaign_id, job_title) VALUES
 (1, 3, 1, 'مشرف ميداني - الفوج الأول'),
 (2, 4, 1, 'مشرف ميداني - الفوج الثاني');

SELECT setval('supervisors_id_seq', 2);

INSERT INTO groups (id, campaign_id, name, supervisor_id, capacity) VALUES
 (1, 1, 'الفوج الأول', 1, 5),
 (2, 1, 'الفوج الثاني', 2, 5);

SELECT setval('groups_id_seq', 2);

INSERT INTO pilgrims (id, user_id, campaign_id, group_id, passport_no, blood_type, medical_notes) VALUES
 (1, 5,  1, 1, 'A1234567', 'O+',  NULL),
 (2, 6,  1, 1, 'A1234568', 'A+',  'حساسية من البنسلين'),
 (3, 7,  1, 1, 'A1234569', 'B+',  NULL),
 (4, 8,  1, 2, 'A1234570', 'AB+', 'مريض سكري - يحتاج جرعة أنسولين دورية'),
 (5, 9,  1, 2, 'A1234571', 'O-',  NULL),
 (6, 10, 1, 2, 'A1234572', 'A-',  'ضغط دم مرتفع');

SELECT setval('pilgrims_id_seq', 6);

INSERT INTO locations (id, campaign_id, name, type, latitude, longitude, radius_meters) VALUES
 (1, 1, 'المسجد الحرام', 'CHECKPOINT', 21.422487, 39.826206, 300),
 (2, 1, 'منى',           'SAFE_ZONE',  21.413249, 39.893315, 500),
 (3, 1, 'عرفات',         'SAFE_ZONE',  21.355461, 39.984702, 800),
 (4, 1, 'مزدلفة',        'SAFE_ZONE',  21.383700, 39.936800, 600);

SELECT setval('locations_id_seq', 4);

INSERT INTO attendance (pilgrim_id, location_id, checkpoint_time, status, source) VALUES
 (1, 1, now() - interval '2 days', 'PRESENT',      'APP_CHECKIN'),
 (2, 1, now() - interval '2 days', 'PRESENT',      'APP_CHECKIN'),
 (3, 1, now() - interval '2 days', 'LATE',         'APP_CHECKIN'),
 (4, 1, now() - interval '2 days', 'PRESENT',      'APP_CHECKIN'),
 (5, 1, now() - interval '2 days', 'ABSENT',       'MANUAL'),
 (6, 1, now() - interval '2 days', 'PRESENT',      'APP_CHECKIN'),
 (1, 2, now() - interval '1 days', 'PRESENT',      'APP_CHECKIN'),
 (2, 2, now() - interval '1 days', 'OUT_OF_RANGE', 'GPS'),
 (3, 2, now() - interval '1 days', 'PRESENT',      'APP_CHECKIN'),
 (4, 3, now() - interval '5 hours','PRESENT',      'APP_CHECKIN'),
 (5, 3, now() - interval '5 hours','LATE',         'APP_CHECKIN');

INSERT INTO trips (id, vehicle_no, driver_name, route_from_id, route_to_id, departure_time, arrival_time, status) VALUES
 (1, 'BUS-101', 'سالم القحطاني', 2, 3, now() - interval '6 hours', now() - interval '4 hours', 'COMPLETED'),
 (2, 'BUS-102', 'فهد الدوسري',   3, 4, now() - interval '1 hours', NULL,                        'IN_PROGRESS');

SELECT setval('trips_id_seq', 2);

INSERT INTO trip_groups (trip_id, group_id) VALUES
 (1, 1),
 (1, 2),
 (2, 2);

INSERT INTO alerts (id, pilgrim_id, location_id, type, severity, status, resolved_by, created_at, resolved_at) VALUES
 (1, 5, 1, 'ABSENCE', 'MEDIUM',   'RESOLVED', 1,    now() - interval '2 days', now() - interval '2 days' + interval '20 minutes'),
 (2, 3, 2, 'DELAY',   'LOW',      'OPEN',     NULL,  now() - interval '1 days', NULL),
 (3, 4, 3, 'SOS',     'CRITICAL', 'RESOLVED', 2,    now() - interval '3 hours', now() - interval '3 hours' + interval '15 minutes');

SELECT setval('alerts_id_seq', 3);

INSERT INTO sos_requests (id, alert_id, pilgrim_id, latitude, longitude, responder_id, status, triggered_at, resolved_at) VALUES
 (1, 3, 4, 21.355900, 39.985100, 2, 'RESOLVED', now() - interval '3 hours', now() - interval '3 hours' + interval '15 minutes');

SELECT setval('sos_requests_id_seq', 1);
INSERT INTO emergency_contacts (pilgrim_id, name, relation, phone, is_primary) VALUES
 (1, 'أحمد إبراهيم',  'الأب',   '0511111111', TRUE),
 (2, 'سالم عبدالله',   'الأب',   '0511111112', TRUE),
 (3, 'ناصر يوسف',      'الأخ',   '0511111113', TRUE),
 (4, 'عمر فيصل',       'الأب',   '0511111114', TRUE),
 (4, 'هند فيصل',       'الزوجة', '0511111115', FALSE),
 (5, 'راشد ماجد',      'الأب',   '0511111116', TRUE),
 (6, 'حمزة طارق',      'الأب',   '0511111117', TRUE);

INSERT INTO notifications (user_id, alert_id, channel, sent_at, read_at) VALUES
 (3, 1, 'PUSH', now() - interval '2 days', now() - interval '2 days' + interval '5 minutes'),
 (4, 2, 'SMS',  now() - interval '1 days', NULL),
 (1, 3, 'PUSH', now() - interval '3 hours', now() - interval '3 hours' + interval '2 minutes');

COMMIT;
