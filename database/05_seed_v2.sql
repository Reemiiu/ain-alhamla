-- =====================================================================
-- عين الحملة — بيانات تجريبية للإصدار v2 (تُشغَّل مرة واحدة بعد 04_migration_v2.sql)
-- سيناريو حي: الحملة الآن في "يوم النحر — رمي جمرة العقبة"
--  • منسكان مكتملان بتقارير (التروية، عرفة) + مزدلفة مكتملة
--  • تجمع مفتوح للفوج الأول انتهت مهلته (يظهر الغائبون)، وتجمع قادم للفوج الثاني
--  • بلاغ SOS مفتوح، وحاج ضغط «أنا تائه»، وحاج خارج النطاق، وبطارية منخفضة
--  • 3 حجاج غير ناطقين بالعربية (إندونيسي، باكستاني، نيجيري)
-- كلمة المرور لكل الحسابات التجريبية: Demo@1234
-- =====================================================================
DO $$ BEGIN
  IF EXISTS (SELECT 1 FROM rituals) THEN
    RAISE EXCEPTION 'seed_v2 مُطبَّق مسبقاً (جدول rituals فيه بيانات)';
  END IF;
END $$;

BEGIN;

-- 1) بيانات الحجاج الحاليين (العمر/الجنسية) → الأولوية تُحسب تلقائياً
UPDATE pilgrims SET birth_date = '1980-03-11', nationality = 'سعودي' WHERE id = 1;
UPDATE pilgrims SET birth_date = '1954-07-02', nationality = 'سعودي' WHERE id = 2;
UPDATE pilgrims SET birth_date = '1990-01-20', nationality = 'سعودي' WHERE id = 3;
UPDATE pilgrims SET birth_date = '1958-10-05', nationality = 'سعودي' WHERE id = 4;
UPDATE pilgrims SET birth_date = '1948-05-15', nationality = 'سعودي' WHERE id = 5;
UPDATE pilgrims SET birth_date = '1970-12-01', nationality = 'سعودي' WHERE id = 6;

-- 2) حجاج غير ناطقين بالعربية
INSERT INTO users (id, full_name, national_id, phone, password_hash, role) VALUES
 (11, 'بودي سانتوسو',  '2040404040', '0500000011', extensions.crypt('Demo@1234', extensions.gen_salt('bf')), 'PILGRIM'),
 (12, 'محمد عمران',    '2040404041', '0500000012', extensions.crypt('Demo@1234', extensions.gen_salt('bf')), 'PILGRIM'),
 (13, 'إبراهيم أوكافور', '2040404042', '0500000013', extensions.crypt('Demo@1234', extensions.gen_salt('bf')), 'PILGRIM');
SELECT setval('users_id_seq', greatest(13, (SELECT max(id) FROM users)));

INSERT INTO pilgrims (id, user_id, campaign_id, group_id, passport_no, blood_type, medical_notes, birth_date, nationality, preferred_language) VALUES
 (7, 11, 1, 1, 'B9876543', 'B+', NULL,                 '1962-04-09', 'إندونيسي', 'id'),
 (8, 12, 1, 1, 'C1122334', 'O+', 'ربو — يحمل بخاخاً', '1956-02-17', 'باكستاني', 'ur'),
 (9, 13, 1, 2, 'D5566778', 'A+', NULL,                 '1975-09-30', 'نيجيري',  'en');
SELECT setval('pilgrims_id_seq', greatest(9, (SELECT max(id) FROM pilgrims)));

INSERT INTO emergency_contacts (pilgrim_id, name, relation, phone, is_primary) VALUES
 (7, 'Siti Santoso',  'الزوجة', '+6281234567890', TRUE),
 (8, 'Ayesha Imran',  'الابنة', '+923001234567',  TRUE),
 (9, 'Grace Okafor',  'الزوجة', '+2348012345678', TRUE);

-- 3) مواقع إضافية في منى
INSERT INTO locations (id, campaign_id, name, type, latitude, longitude, radius_meters) VALUES
 (5, 1, 'مخيم الحملة — منى', 'SAFE_ZONE',  21.413500, 39.890500, 250),
 (6, 1, 'الجمرات',            'CHECKPOINT', 21.420700, 39.872400, 400);
SELECT setval('locations_id_seq', greatest(6, (SELECT max(id) FROM locations)));

-- 4) المناسك (نسبةً إلى الآن: نحن في يوم النحر)
INSERT INTO rituals (id, campaign_id, name, hajj_day, seq, location_id, starts_at, ends_at, status) VALUES
 (1, 1, 'يوم التروية — المبيت بمنى',  8,  1, 2, now() - interval '3 days',  now() - interval '2 days 6 hours', 'COMPLETED'),
 (2, 1, 'الوقوف بعرفة',               9,  2, 3, now() - interval '2 days',  now() - interval '1 day 12 hours',  'COMPLETED'),
 (3, 1, 'المبيت بمزدلفة',             9,  3, 4, now() - interval '1 day 11 hours', now() - interval '6 hours', 'COMPLETED'),
 (4, 1, 'رمي جمرة العقبة',            10, 4, 6, now() - interval '3 hours', now() + interval '5 hours',   'IN_PROGRESS'),
 (5, 1, 'طواف الإفاضة والسعي',        10, 5, 1, now() + interval '6 hours', now() + interval '1 day',     'UPCOMING'),
 (6, 1, 'طواف الوداع',                13, 6, 1, now() + interval '3 days',  now() + interval '3 days 6 hours', 'UPCOMING');
SELECT setval('rituals_id_seq', 6);

-- 5) رحلة جديدة: المخيم → الجمرات للفوج الأول
INSERT INTO trips (id, vehicle_no, driver_name, route_from_id, route_to_id, departure_time, status) VALUES
 (3, 'BUS-103', 'ناصر الشهري', 5, 6, now() + interval '20 minutes', 'SCHEDULED');
SELECT setval('trips_id_seq', greatest(3, (SELECT max(id) FROM trips)));
INSERT INTO trip_groups (trip_id, group_id) VALUES (3, 1);

-- 6) التجمعات
INSERT INTO gatherings (id, campaign_id, group_id, ritual_id, trip_id, location_id, title, scheduled_at, deadline_minutes, status, created_by, created_at, closed_at) VALUES
 (1, 1, 1, 2, 1,    3, 'تجمع الصعود إلى عرفة',          now() - interval '2 days',            15, 'CLOSED', 3, now() - interval '2 days 2 hours', now() - interval '2 days' + interval '40 minutes'),
 (2, 1, 2, 2, 1,    3, 'تجمع الصعود إلى عرفة',          now() - interval '2 days',            15, 'CLOSED', 4, now() - interval '2 days 2 hours', now() - interval '2 days' + interval '40 minutes'),
 (3, 1, 1, 4, 3,    5, 'التجمع عند المخيم للتوجه للجمرات', now() - interval '25 minutes',     15, 'OPEN',   3, now() - interval '2 hours', NULL),
 (4, 1, 2, 4, NULL, 5, 'التجمع عند المخيم للتوجه للجمرات', now() + interval '40 minutes',     20, 'OPEN',   4, now() - interval '1 hour', NULL),
 (5, 1, 1, 1, NULL, 2, 'التجمع للانطلاق إلى منى',          now() - interval '3 days',            20, 'CLOSED', 3, now() - interval '3 days 3 hours', now() - interval '3 days' + interval '45 minutes'),
 (6, 1, 2, 1, NULL, 2, 'التجمع للانطلاق إلى منى',          now() - interval '3 days',            20, 'CLOSED', 4, now() - interval '3 days 3 hours', now() - interval '3 days' + interval '45 minutes'),
 (7, 1, 1, 3, 2,    4, 'التجمع للنفرة إلى مزدلفة',         now() - interval '1 day 11 hours',    15, 'CLOSED', 3, now() - interval '1 day 13 hours', now() - interval '1 day 10 hours'),
 (8, 1, 2, 3, 2,    4, 'التجمع للنفرة إلى مزدلفة',         now() - interval '1 day 11 hours',    15, 'CLOSED', 4, now() - interval '1 day 13 hours', now() - interval '1 day 10 hours');
SELECT setval('gatherings_id_seq', 8);

-- حضور التروية ومزدلفة (الجميع حاضر عدا حالتين متأخرتين)
INSERT INTO attendance (pilgrim_id, location_id, gathering_id, checkpoint_time, status, source, distance_m)
SELECT pp.id, gt.location_id, gt.id,
       gt.scheduled_at + CASE WHEN (pp.id, gt.id) IN ((5, 8), (8, 7)) THEN interval '25 minutes' ELSE interval '-6 minutes' END,
       CASE WHEN (pp.id, gt.id) IN ((5, 8), (8, 7)) THEN 'LATE' ELSE 'PRESENT' END::attendance_status,
       'APP_CHECKIN', 40 + (pp.id * 13) % 90
  FROM gatherings gt JOIN pilgrims pp ON pp.group_id = gt.group_id
 WHERE gt.id IN (5, 6, 7, 8);

-- حضور عرفة (مكتمل)
INSERT INTO attendance (pilgrim_id, location_id, gathering_id, checkpoint_time, status, source, distance_m) VALUES
 (1, 3, 1, now() - interval '2 days' - interval '5 minutes', 'PRESENT', 'APP_CHECKIN', 40),
 (2, 3, 1, now() - interval '2 days' + interval '2 minutes', 'PRESENT', 'APP_CHECKIN', 85),
 (3, 3, 1, now() - interval '2 days' + interval '22 minutes', 'LATE',   'APP_CHECKIN', 120),
 (7, 3, 1, now() - interval '2 days' - interval '1 minutes', 'PRESENT', 'APP_CHECKIN', 60),
 (8, 3, 1, now() - interval '2 days' + interval '35 minutes', 'PRESENT', 'MANUAL', NULL),
 (4, 3, 2, now() - interval '2 days' - interval '8 minutes', 'PRESENT', 'APP_CHECKIN', 30),
 (5, 3, 2, now() - interval '2 days' + interval '40 minutes', 'ABSENT',  'MANUAL', NULL),
 (6, 3, 2, now() - interval '2 days' + interval '3 minutes', 'PRESENT', 'APP_CHECKIN', 200),
 (9, 3, 2, now() - interval '2 days' + interval '18 minutes', 'LATE',   'APP_CHECKIN', 90);
-- حضور الجمرات الحالي (الفوج الأول: 3 من 5 سجّلوا)
INSERT INTO attendance (pilgrim_id, location_id, gathering_id, checkpoint_time, status, source, distance_m) VALUES
 (1, 5, 3, now() - interval '30 minutes', 'PRESENT', 'APP_CHECKIN', 35),
 (2, 5, 3, now() - interval '24 minutes', 'PRESENT', 'APP_CHECKIN', 70),
 (3, 5, 3, now() - interval '5 minutes',  'LATE',    'APP_CHECKIN', 110);

INSERT INTO alerts (pilgrim_id, location_id, gathering_id, ritual_id, type, severity, status, resolved_by, created_at, resolved_at, note) VALUES
 (3, 3, 1, 2, 'DELAY',   'LOW',      'RESOLVED', 3, now() - interval '2 days' + interval '22 minutes', now() - interval '2 days' + interval '30 minutes', 'تأخر 7 دقائق عن المهلة'),
 (5, 3, 2, 2, 'ABSENCE', 'CRITICAL', 'RESOLVED', 4, now() - interval '2 days' + interval '16 minutes', now() - interval '2 days' + interval '55 minutes', 'وُجد في مخيم مجاور وأُعيد للمجموعة'),
 (3, 5, 3, 4, 'DELAY',   'LOW',      'OPEN',     NULL, now() - interval '5 minutes', NULL, 'تأخر 5 دقائق عن المهلة');

-- 7) مواقع حية (آخر 10 دقائق) — حجاج ومشرفون حول مخيم منى
INSERT INTO location_pings (user_id, latitude, longitude, accuracy_m, battery_pct, client_recorded_at) VALUES
 (3,  21.413600, 39.890300, 8,  76, now() - interval '1 minutes'),   -- المشرف خالد
 (4,  21.413900, 39.891200, 10, 64, now() - interval '2 minutes'),   -- المشرف سعيد
 (5,  21.413450, 39.890650, 12, 81, now() - interval '2 minutes'),
 (6,  21.413700, 39.890100, 9,  58, now() - interval '3 minutes'),
 (7,  21.413300, 39.889900, 15, 44, now() - interval '4 minutes'),
 (8,  21.414100, 39.891500, 11, 67, now() - interval '1 minutes'),
 (9,  21.413200, 39.891900, 14, 12, now() - interval '3 minutes'),   -- بطارية منخفضة
 (11, 21.418900, 39.881000, 20, 39, now() - interval '2 minutes'),   -- بودي: خارج النطاق باتجاه الجمرات
 (12, 21.416800, 39.886200, 25, 52, now() - interval '3 minutes'),   -- محمد عمران: تائه
 (13, 21.413800, 39.891000, 10, 71, now() - interval '5 minutes'),
 (10, 21.413550, 39.890800, 9,  90, now() - interval '6 minutes');

-- 8) بلاغات مفتوحة الآن
INSERT INTO alerts (id, pilgrim_id, location_id, type, severity, status, created_at, latitude, longitude, note) VALUES
 (100, 7, 5, 'GEOFENCE_BREACH', 'MEDIUM',   'OPEN', now() - interval '2 minutes', 21.418900, 39.881000, 'على بعد 1050 م من مخيم الحملة — منى'),
 (101, 8, NULL, 'LOST',         'MEDIUM',   'OPEN', now() - interval '3 minutes', 21.416800, 39.886200, 'الحاج أبلغ أنه تائه'),
 (102, 4, NULL, 'SOS',          'CRITICAL', 'OPEN', now() - interval '1 minutes', 21.413900, 39.891200, NULL),
 (103, 6, NULL, 'LOW_BATTERY',  'MEDIUM',   'OPEN', now() - interval '3 minutes', 21.413200, 39.891900, 'البطارية 12٪');
INSERT INTO sos_requests (alert_id, pilgrim_id, latitude, longitude, status, triggered_at)
VALUES (102, 4, 21.413900, 39.891200, 'PENDING', now() - interval '1 minutes');
SELECT setval('alerts_id_seq', greatest(103, (SELECT max(id) FROM alerts)));

-- 9) رسائل جماعية + إشعارات
INSERT INTO broadcasts (id, campaign_id, group_id, sender_id, title, body, is_urgent, created_at) VALUES
 (1, 1, 1,    3, 'موعد التوجه للجمرات', 'التجمع عند بوابة المخيم الشمالية، الحافلة BUS-103. احملوا الماء والمظلات.', FALSE, now() - interval '2 hours'),
 (2, 1, NULL, 1, 'تنبيه حرارة',          'درجة الحرارة مرتفعة اليوم — اشربوا الماء باستمرار وتجنّبوا الشمس المباشرة.', TRUE,  now() - interval '5 hours');
SELECT setval('broadcasts_id_seq', 2);
INSERT INTO notifications (user_id, broadcast_id, channel, title, body, sent_at)
SELECT pp.user_id, b.id, 'IN_APP', b.title, b.body, b.created_at
  FROM broadcasts b JOIN pilgrims pp ON (b.group_id IS NULL OR pp.group_id = b.group_id);
INSERT INTO notifications (user_id, alert_id, channel, title, body, sent_at) VALUES
 (4, 102, 'IN_APP', 'طلب نجدة SOS', 'فيصل عمر يطلب مساعدة فورية', now() - interval '1 minutes'),
 (2, 102, 'IN_APP', 'طلب نجدة SOS', 'فيصل عمر يطلب مساعدة فورية', now() - interval '1 minutes'),
 (3, 101, 'IN_APP', 'حاج تائه', 'محمد عمران ضغط «أنا تائه» ويحتاج توجيهاً', now() - interval '3 minutes'),
 (2, 101, 'IN_APP', 'حاج تائه', 'محمد عمران ضغط «أنا تائه» ويحتاج توجيهاً', now() - interval '3 minutes'),
 (3, 100, 'IN_APP', 'خروج عن النطاق', 'بودي سانتوسو على بعد 1050 م من مخيم الحملة', now() - interval '2 minutes'),
 (4, 103, 'IN_APP', 'بطارية منخفضة', 'طارق حمزة: 12٪ — قد ينقطع تتبعه قريباً', now() - interval '3 minutes');

-- 10) التعليقات: ملاحظات المشرفين، رد الإدارة، تقييم الحجاج
INSERT INTO comments (id, author_id, kind, ritual_id, group_id, pilgrim_id, parent_id, rating, body, created_at) VALUES
 (1, 3,  'SUPERVISOR_NOTE', 2, 1, NULL, NULL, NULL, 'الصعود لعرفة تم بانتظام. تأخر يوسف ناصر بسبب الزحام عند البوابة، نقترح تجمعاً أبكر بربع ساعة.', now() - interval '1 day 20 hours'),
 (2, 4,  'SUPERVISOR_NOTE', 2, 2, 5,    NULL, NULL, 'ماجد راشد (78 سنة) ضاع 40 دقيقة في المخيمات المجاورة. نحتاج مرافقاً دائماً لكبار السن.', now() - interval '1 day 19 hours'),
 (3, 1,  'ADMIN_REPLY',     2, 2, NULL, 2,    NULL, 'تم اعتماد مرافق لكل حاج أولويته حرجة ابتداءً من مزدلفة. شكراً سعيد.', now() - interval '1 day 15 hours'),
 (4, 5,  'PILGRIM_FEEDBACK', 2, 1, 1,   NULL, 5, 'التنظيم ممتاز والتنبيهات وصلت في وقتها', now() - interval '1 day 18 hours'),
 (5, 6,  'PILGRIM_FEEDBACK', 2, 1, 2,   NULL, 4, '', now() - interval '1 day 18 hours'),
 (6, 11, 'PILGRIM_FEEDBACK', 2, 1, 7,   NULL, 5, 'Aplikasinya membantu, terima kasih', now() - interval '1 day 17 hours'),
 (7, 8,  'PILGRIM_FEEDBACK', 2, 2, 4,   NULL, 3, 'الحافلة تأخرت قليلاً', now() - interval '1 day 17 hours'),
 (8, 3,  'SUPERVISOR_NOTE', 4, 1, NULL, NULL, NULL, 'الزحام شديد عند جسر الجمرات، سنرمي على دفعتين.', now() - interval '40 minutes');
SELECT setval('comments_id_seq', 8);

-- 11) سجل الشغل
INSERT INTO activity_log (actor_id, action, entity, entity_id, group_id, description, created_at) VALUES
 (3, 'CREATE_GATHERING', 'gathering', 1, 1, 'فتح تجمع «تجمع الصعود إلى عرفة» للفوج الأول', now() - interval '2 days 2 hours'),
 (4, 'CREATE_GATHERING', 'gathering', 2, 2, 'فتح تجمع «تجمع الصعود إلى عرفة» للفوج الثاني', now() - interval '2 days 2 hours'),
 (3, 'MANUAL_ATTENDANCE', 'attendance', 8, 1, 'سجّل محمد عمران «حاضر» في «تجمع الصعود إلى عرفة»', now() - interval '2 days' + interval '35 minutes'),
 (4, 'RESOLVE_ALERT', 'alert', 2, 2, 'أغلق تنبيه غياب — ماجد راشد (وُجد في مخيم مجاور)', now() - interval '2 days' + interval '55 minutes'),
 (3, 'CLOSE_GATHERING', 'gathering', 1, 1, 'أغلق تجمع «تجمع الصعود إلى عرفة» — غائبون: 0', now() - interval '2 days' + interval '40 minutes'),
 (4, 'CLOSE_GATHERING', 'gathering', 2, 2, 'أغلق تجمع «تجمع الصعود إلى عرفة» — غائبون: 1', now() - interval '2 days' + interval '40 minutes'),
 (3, 'FINISH_RITUAL', 'ritual_report', NULL, 1, 'أصدر تقرير منسك «الوقوف بعرفة» للفوج الأول', now() - interval '1 day 20 hours'),
 (4, 'FINISH_RITUAL', 'ritual_report', NULL, 2, 'أصدر تقرير منسك «الوقوف بعرفة» للفوج الثاني', now() - interval '1 day 19 hours'),
 (3, 'BROADCAST', 'broadcast', 1, 1, 'أرسل رسالة جماعية «موعد التوجه للجمرات» إلى 5 حجاج', now() - interval '2 hours'),
 (3, 'CREATE_GATHERING', 'gathering', 3, 1, 'فتح تجمع «التجمع عند المخيم للتوجه للجمرات» للفوج الأول', now() - interval '2 hours'),
 (4, 'CREATE_GATHERING', 'gathering', 4, 2, 'فتح تجمع «التجمع عند المخيم للتوجه للجمرات» للفوج الثاني', now() - interval '1 hour'),
 (3, 'COMMENT', 'comment', 8, 1, 'كتب تعليقاً: الزحام شديد عند جسر الجمرات، سنرمي على دفعتين.', now() - interval '40 minutes');

COMMIT;

-- 12) تقارير المناسك المكتملة (تُبنى من البيانات أعلاه)
SELECT _build_ritual_report(2, 1, 3, 'الصعود لعرفة تم بانتظام. تأخر يوسف ناصر بسبب الزحام عند البوابة، نقترح تجمعاً أبكر بربع ساعة.');
SELECT _build_ritual_report(2, 2, 4, 'ماجد راشد (78 سنة) ضاع 40 دقيقة في المخيمات المجاورة. نحتاج مرافقاً دائماً لكبار السن.');
SELECT _build_ritual_report(1, 1, NULL, 'المبيت بمنى بدون ملاحظات.');
SELECT _build_ritual_report(1, 2, NULL, 'المبيت بمنى بدون ملاحظات.');
SELECT _build_ritual_report(3, 1, NULL, NULL);
SELECT _build_ritual_report(3, 2, NULL, NULL);

SELECT 'rituals' t, count(*) FROM rituals UNION ALL SELECT 'gatherings', count(*) FROM gatherings
UNION ALL SELECT 'ritual_reports', count(*) FROM ritual_reports UNION ALL SELECT 'pilgrims', count(*) FROM pilgrims;
