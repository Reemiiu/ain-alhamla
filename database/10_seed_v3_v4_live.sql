-- =====================================================================
-- عين الحملة — بيانات العرض لمميزات v3 وv4 على القاعدة الحية
-- يُشغَّل بعد migration_v4_1_dashboard.sql. آمن لإعادة التشغيل (لا يكرر البيانات).
-- مبني على الحجاج الموجودين أصلًا (حسب رقم الهوية في 05_seed_v2.sql).
-- ملاحظة: حدود المشاعر ونقاط اللقاء إحداثيات تقريبية للعرض فقط.
-- =====================================================================

-- ---------- نقاط اللقاء ----------
INSERT INTO meeting_points (campaign_id, name, latitude, longitude, is_open, landmark)
SELECT 1, x.name, x.lat, x.lng, x.open, x.landmark FROM (VALUES
  ('نقطة لقاء A · البوابة الشمالية للمخيم', 21.415000, 39.890800, TRUE,  'بجانب لوحة الحملة الخضراء'),
  ('نقطة لقاء B · مستوصف منى',              21.417000, 39.886000, TRUE,  'أمام المدخل الرئيسي (موقع تقريبي)'),
  ('نقطة لقاء C · مدخل جسر الجمرات',        21.420000, 39.874500, TRUE,  'الدور الأرضي، عند لوحة المدخل'),
  ('نقطة لقاء D · محطة قطار المشاعر',       21.410500, 39.896000, FALSE, 'مغلقة مؤقتًا بسبب الزحام'),
  ('نقطة لقاء E · بوابة مخيم الحملة بعرفة', 21.356000, 39.985000, TRUE,  'البوابة رقم ٣')
) AS x(name, lat, lng, open, landmark)
WHERE NOT EXISTS (SELECT 1 FROM meeting_points m WHERE m.name = x.name);

-- ---------- حدود المشاعر (تقريبية للعرض) ----------
INSERT INTO sacred_sites (key, name, boundary, note) VALUES
 ('ARAFAH', 'عرفة', '[[21.3720,39.9640],[21.3700,39.9980],[21.3530,40.0100],[21.3380,39.9950],[21.3400,39.9700],[21.3560,39.9600]]', 'حد تقريبي للعرض'),
 ('MUZDALIFAH', 'مزدلفة', '[[21.3960,39.9180],[21.3920,39.9500],[21.3760,39.9560],[21.3740,39.9260]]', 'حد تقريبي للعرض'),
 ('MINA', 'منى', '[[21.4240,39.8690],[21.4220,39.9080],[21.4060,39.9120],[21.4030,39.8720]]', 'حد تقريبي للعرض')
ON CONFLICT DO NOTHING;

-- ---------- الرفاق ----------
INSERT INTO buddy_pairs (pilgrim_a_id, pilgrim_b_id, max_distance_m)
SELECT least(a.id, b.id), greatest(a.id, b.id), 150
  FROM (VALUES ('1030303030','1030303031'), ('2040404040','2040404041'), ('1030303033','1030303034'), ('1030303035','2040404042')) v(na, nb)
  JOIN users ua ON ua.national_id = v.na JOIN pilgrims a ON a.user_id = ua.id
  JOIN users ub ON ub.national_id = v.nb JOIN pilgrims b ON b.user_id = ub.id
 WHERE NOT EXISTS (SELECT 1 FROM buddy_pairs bp WHERE a.id IN (bp.pilgrim_a_id, bp.pilgrim_b_id) OR b.id IN (bp.pilgrim_a_id, bp.pilgrim_b_id));

-- ---------- الحساسية والأدوية ----------
UPDATE pilgrims SET allergies = 'البنسلين' WHERE user_id = (SELECT id FROM users WHERE national_id = '1030303031') AND allergies IS NULL;

INSERT INTO medications (pilgrim_id, name, condition, schedule_times, needs_fridge)
SELECT p.id, x.name, x.cond, x.times::time[], x.fridge FROM (VALUES
  ('1030303033', 'إنسولين قاعدي', 'سكري', '{08:00,20:00}', TRUE),
  ('1030303033', 'ميتفورمين ٥٠٠ ملغ', 'سكري', '{13:00}', FALSE),
  ('1030303035', 'أملوديبين ٥ ملغ', 'ضغط', '{09:00}', FALSE),
  ('1030303034', 'أسبرين ٨١ ملغ', 'قلب', '{09:00}', FALSE),
  ('2040404041', 'بخاخ سالبوتامول', 'ربو', '{}', FALSE)
) AS x(nid, name, cond, times, fridge)
JOIN users us ON us.national_id = x.nid JOIN pilgrims p ON p.user_id = us.id
WHERE NOT EXISTS (SELECT 1 FROM medications m WHERE m.pilgrim_id = p.id AND m.name = x.name);

-- ---------- تجهيز ما قبل السفر ----------
INSERT INTO prep_tasks (campaign_id, key, name, seq)
SELECT 1, t.key, t.name, t.seq FROM (VALUES
 ('VISA','تصريح الحج سارٍ',1),('VACCINE','التطعيمات (الحمى الشوكية، الإنفلونزا)',2),('MED','تعبئة الملف الطبي والأدوية',3),
 ('CONTACT','إضافة جهة اتصال طارئة',4),('BUDDY','التعرّف على الرفيق',5),('OFFLINE','تحميل الخريطة بدون إنترنت',6),
 ('IHRAM','لبس الإحرام والحقيبة',7),('TRAIN','مشاهدة شرح التطبيق (٣ دقائق)',8)) t(key, name, seq)
ON CONFLICT (campaign_id, key) DO NOTHING;

-- كل الحجاج أنجزوا أغلب المهام، وبعضهم ناقص (للعرض)
INSERT INTO prep_progress (pilgrim_id, task_id)
SELECT p.id, t.id FROM pilgrims p JOIN users us ON us.id = p.user_id CROSS JOIN prep_tasks t
 WHERE t.campaign_id = 1
   AND NOT (us.national_id = '2040404041' AND t.key IN ('OFFLINE','TRAIN','MED'))
   AND NOT (us.national_id = '1030303034' AND t.key IN ('OFFLINE','BUDDY'))
   AND NOT (us.national_id = '1030303032' AND t.key = 'TRAIN')
ON CONFLICT DO NOTHING;

-- ---------- دليل المناسك (العربية + الإنجليزية + الأردية + الإندونيسية ليوم عرفة) ----------
INSERT INTO ritual_guides (hajj_day, lang, title, steps, dua, tip) VALUES
 (8,  'ar', 'يوم التروية · منى', '["الإحرام بالحج ضحى لمن كان متمتعًا، من مكانه","التوجه إلى منى","صلاة الظهر والعصر والمغرب والعشاء والفجر قصرًا بلا جمع، كل صلاة في وقتها","المبيت في منى"]', 'لبيك اللهم لبيك، لبيك لا شريك لك لبيك، إن الحمد والنعمة لك والملك، لا شريك لك', 'أكثر من التلبية، والحافلة إلى عرفة بعد شروق الشمس'),
 (9,  'ar', 'يوم عرفة', '["التوجه إلى عرفة بعد طلوع الشمس","صلاة الظهر والعصر جمع تقديم وقصرًا","الوقوف والإكثار من الدعاء حتى غروب الشمس","تأكد أنك داخل حدود عرفة، والتطبيق ينبهك لو كنت خارجها"]', 'لا إله إلا الله وحده لا شريك له، له الملك وله الحمد، وهو على كل شيء قدير', 'لا تخرج من عرفة قبل غروب الشمس، واشرب ماءً كثيرًا'),
 (10, 'ar', 'يوم النحر', '["رمي جمرة العقبة بسبع حصيات مع التكبير","ذبح الهدي للمتمتع والقارن","الحلق أو التقصير","طواف الإفاضة والسعي لمن عليه سعي"]', 'الله أكبر', 'استخدم عدّاد الجمرات وعدّاد الطواف'),
 (11, 'ar', 'أول أيام التشريق', '["رمي الجمرات الثلاث بعد الزوال: الصغرى ثم الوسطى ثم العقبة، سبع حصيات لكل جمرة","المبيت بمنى أكثر الليل"]', NULL, 'التطبيق يقترح أقل وقت زحمة للرمي'),
 (12, 'ar', 'ثاني أيام التشريق', '["رمي الجمرات الثلاث بعد الزوال","من تعجّل يخرج من منى قبل غروب الشمس","طواف الوداع آخر ما يفعله الحاج قبل مغادرة مكة"]', NULL, 'قيّم تجربتك في التطبيق بعد المنسك'),
 (9,  'en', 'Day of Arafah', '["Head to Arafah after sunrise","Pray Dhuhr and Asr combined and shortened","Stand in supplication until sunset","Make sure you are inside the boundary of Arafah"]', NULL, 'Do not leave Arafah before sunset'),
 (9,  'ur', 'یومِ عرفہ', '["طلوعِ آفتاب کے بعد عرفات روانہ ہوں","ظہر اور عصر جمع اور قصر کے ساتھ پڑھیں","غروبِ آفتاب تک وقوف اور دعا کریں","یقینی بنائیں کہ آپ عرفات کی حدود کے اندر ہیں"]', NULL, 'غروب سے پہلے عرفات سے نہ نکلیں'),
 (9,  'id', 'Hari Arafah', '["Berangkat ke Arafah setelah matahari terbit","Shalat Zuhur dan Asar dijamak dan diqasar","Wukuf dan perbanyak doa hingga matahari terbenam","Pastikan Anda berada di dalam batas Arafah"]', NULL, 'Jangan meninggalkan Arafah sebelum matahari terbenam')
ON CONFLICT (hajj_day, lang) DO NOTHING;

-- ---------- رابطان للأهل ----------
INSERT INTO family_links (pilgrim_id, contact_id, expires_at, created_by)
SELECT p.id, (SELECT id FROM emergency_contacts e WHERE e.pilgrim_id = p.id ORDER BY is_primary DESC LIMIT 1), now() + interval '14 days',
       (SELECT id FROM users WHERE national_id = '1020202020')
  FROM pilgrims p JOIN users us ON us.id = p.user_id
 WHERE us.national_id IN ('1030303031', '2040404041')
   AND NOT EXISTS (SELECT 1 FROM family_links f WHERE f.pilgrim_id = p.id);

-- ---------- مفقودات ----------
INSERT INTO lost_items (campaign_id, reporter_id, owner_pilgrim_id, category, description, last_seen_place, status, is_urgent, found_by, found_at)
SELECT 1, ru.id, p.id, x.cat::lost_category, x.descr, x.place, x.st::lost_status, x.urgent,
       CASE WHEN x.st = 'FOUND' THEN (SELECT id FROM users WHERE national_id = '1020202021') END,
       CASE WHEN x.st = 'FOUND' THEN now() - interval '40 minutes' END
  FROM (VALUES
    ('2040404040', 'GLASSES',  'نظارة طبية بإطار بني', 'الحافلة رقم ٣', 'OPEN', FALSE),
    ('2040404042', 'PASSPORT', 'جواز سفر نيجيري داخل محفظة سوداء', 'مخيم منى · الخيمة ٢', 'OPEN', TRUE),
    ('1030303035', 'PHONE',    'شاحن جوال أبيض', 'دورات المياه · البوابة ٢', 'FOUND', FALSE)
  ) AS x(nid, cat, descr, place, st, urgent)
  JOIN users ru ON ru.national_id = x.nid JOIN pilgrims p ON p.user_id = ru.id
 WHERE NOT EXISTS (SELECT 1 FROM lost_items l WHERE l.description = x.descr);

-- ---------- رسالة صوتية مترجمة ----------
DO $$
DECLARE v_sup BIGINT; v_b BIGINT; v_id BIGINT;
BEGIN
  IF EXISTS (SELECT 1 FROM voice_messages) THEN RETURN; END IF;
  SELECT id INTO v_sup FROM users WHERE national_id = '1020202020';
  INSERT INTO broadcasts (campaign_id, group_id, sender_id, title, body, is_urgent)
  VALUES (1, 1, v_sup, 'رسالة صوتية من خالد العتيبي', 'التجمع عند البوابة الشمالية للمخيم الساعة الرابعة عصرًا للتوجه إلى الجمرات. خذوا معكم الماء والمظلة.', FALSE)
  RETURNING id INTO v_b;
  INSERT INTO voice_messages (broadcast_id, sender_id, group_id, duration_sec, transcript_ar)
  VALUES (v_b, v_sup, 1, 21, 'التجمع عند البوابة الشمالية للمخيم الساعة الرابعة عصرًا للتوجه إلى الجمرات. خذوا معكم الماء والمظلة.')
  RETURNING id INTO v_id;
  INSERT INTO voice_message_translations (voice_id, lang, text) VALUES
    (v_id, 'en', 'Gather at the north gate of the camp at 4 pm to go to the Jamarat. Bring water and an umbrella.'),
    (v_id, 'ur', 'جمرات جانے کے لیے شام چار بجے کیمپ کے شمالی دروازے پر جمع ہوں۔ پانی اور چھتری ساتھ رکھیں۔'),
    (v_id, 'id', 'Berkumpul di gerbang utara tenda pukul 16.00 untuk berangkat ke Jamarat. Bawa air dan payung.');
  INSERT INTO notifications (user_id, broadcast_id, channel, title, body)
  SELECT p.user_id, v_b, 'IN_APP', 'رسالة صوتية من خالد العتيبي', 'التجمع عند البوابة الشمالية للمخيم الساعة الرابعة عصرًا'
    FROM pilgrims p WHERE p.group_id = 1;
  INSERT INTO voice_message_receipts (voice_id, pilgrim_id)
  SELECT v_id, p.id FROM pilgrims p JOIN users us ON us.id = p.user_id WHERE us.national_id IN ('1030303030', '2040404040');
END $$;

-- تحقق
SELECT (SELECT count(*) FROM meeting_points) AS meeting_points, (SELECT count(*) FROM sacred_sites) AS sites,
       (SELECT count(*) FROM buddy_pairs) AS buddies, (SELECT count(*) FROM medications) AS meds,
       (SELECT count(*) FROM prep_tasks) AS prep_tasks, (SELECT count(*) FROM ritual_guides) AS guides,
       (SELECT count(*) FROM family_links) AS family_links, (SELECT count(*) FROM lost_items) AS lost, (SELECT count(*) FROM voice_messages) AS voice;
