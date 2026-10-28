-- =====================================================================
-- عين الحملة — v4.3: شاشة «حجّي» في تطبيق الحاج + إضافة الأدوية (آمن لإعادة التشغيل)
-- يُشغَّل بعد 11_migration_v4_2_fixes.sql. لا يضيف جداول.
--   app_my_hajj         : كل ما تحتاجه شاشة «حجّي» في طلب واحد (الدليل، العدّادات، الأدوية،
--                         رسائل المشرف بلغة الحاج، قائمة التجهيز، المفقودات، سؤال «أنت بخير؟» المفتوح)
--   app_add_medication  : إضافة دواء (الحاج لنفسه، أو المشرف/الإدارة لحاج) وتوليد جرعات اليوم القادمة
--   app_stop_medication : إيقاف دواء (تُترك جرعات اليوم القادمة)
-- =====================================================================

CREATE OR REPLACE FUNCTION app_my_hajj(p_token UUID, p_day INT DEFAULT 9)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_lang TEXT; v_today DATE := (now() AT TIME ZONE 'Asia/Riyadh')::date;
BEGIN
  u := _auth(p_token, ARRAY['PILGRIM']::user_role[]);
  SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  IF p.id IS NULL THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  v_lang := coalesce(p.preferred_language, 'ar');
  RETURN json_build_object(
    'day', p_day,
    'lang', v_lang,
    'guide', (SELECT row_to_json(g) FROM (SELECT hajj_day, lang, title, steps, dua, tip FROM ritual_guides
               WHERE hajj_day = p_day AND lang IN (v_lang, 'ar') ORDER BY (lang = v_lang) DESC LIMIT 1) g),
    'counters', (SELECT coalesce(json_object_agg(kind, count), '{}'::json) FROM ritual_counters
                  WHERE pilgrim_id = p.id AND hajj_day = p_day),
    'doses', (SELECT coalesce(json_agg(json_build_object('dose_id', d.id, 'name', m.name, 'condition', m.condition,
                'scheduled_at', d.scheduled_at, 'status', d.status, 'needs_fridge', m.needs_fridge) ORDER BY d.scheduled_at), '[]'::json)
                FROM medication_doses d JOIN medications m ON m.id = d.medication_id
               WHERE m.pilgrim_id = p.id AND (d.scheduled_at AT TIME ZONE 'Asia/Riyadh')::date = v_today),
    'medications', (SELECT coalesce(json_agg(json_build_object('id', m.id, 'name', m.name, 'condition', m.condition,
                'times', (SELECT coalesce(json_agg(to_char(t, 'HH24:MI') ORDER BY t), '[]'::json) FROM unnest(m.schedule_times) t),
                'needs_fridge', m.needs_fridge) ORDER BY m.created_at), '[]'::json)
                FROM medications m WHERE m.pilgrim_id = p.id AND m.is_active),
    'prep', (SELECT coalesce(json_agg(json_build_object('id', t.id, 'name', t.name, 'done', pr.task_id IS NOT NULL) ORDER BY t.seq), '[]'::json)
               FROM prep_tasks t LEFT JOIN prep_progress pr ON pr.task_id = t.id AND pr.pilgrim_id = p.id
              WHERE t.campaign_id = p.campaign_id),
    'voice', (SELECT coalesce(json_agg(x ORDER BY x.created_at DESC), '[]'::json) FROM (
               SELECT vm.id, us.full_name AS sender, vm.created_at, vm.is_urgent, vm.audio_url,
                      coalesce(tr.text, vm.transcript_ar) AS text,
                      CASE WHEN tr.text IS NULL THEN 'ar' ELSE v_lang END AS lang,
                      EXISTS (SELECT 1 FROM voice_message_receipts r WHERE r.voice_id = vm.id AND r.pilgrim_id = p.id) AS heard
                 FROM voice_messages vm
                 JOIN users us ON us.id = vm.sender_id
                 LEFT JOIN broadcasts b ON b.id = vm.broadcast_id
                 LEFT JOIN voice_message_translations tr ON tr.voice_id = vm.id AND tr.lang = v_lang AND v_lang <> 'ar'
                WHERE vm.group_id = p.group_id OR (vm.group_id IS NULL AND (b.campaign_id = p.campaign_id OR b.id IS NULL))
                ORDER BY vm.created_at DESC LIMIT 10) x),
    'lost', (SELECT coalesce(json_agg(json_build_object('id', l.id, 'category', l.category, 'description', l.description,
               'place', l.last_seen_place, 'status', l.status, 'is_urgent', l.is_urgent, 'created_at', l.created_at,
               'found_at', l.found_at, 'finder', f.full_name) ORDER BY l.created_at DESC), '[]'::json)
               FROM lost_items l LEFT JOIN users f ON f.id = l.found_by
              WHERE l.owner_pilgrim_id = p.id OR l.reporter_id = u.id),
    'wellness', (SELECT json_build_object('check_id', w.id, 'still_minutes', w.still_minutes, 'sent_at', w.sent_at)
                   FROM wellness_checks w WHERE w.pilgrim_id = p.id AND w.status = 'SENT' ORDER BY w.sent_at DESC LIMIT 1)
  );
END $$;

-- إضافة دواء: الحاج لنفسه (p_pilgrim_id فارغ) أو المشرف/الإدارة لحاج في مجموعاته.
-- p_times مثل {'08:00','20:00'}؛ فارغة = عند الحاجة. تُولَّد جرعات اليوم التي لم يحن وقتها بعد.
CREATE OR REPLACE FUNCTION app_add_medication(p_token UUID, p_name TEXT, p_pilgrim_id BIGINT DEFAULT NULL,
    p_condition TEXT DEFAULT NULL, p_times TEXT[] DEFAULT '{}', p_needs_fridge BOOLEAN DEFAULT FALSE)
RETURNS JSON LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims; v_id BIGINT; v_times TIME[]; v_today DATE := (now() AT TIME ZONE 'Asia/Riyadh')::date; v_n INT;
BEGIN
  u := _auth(p_token);
  IF p_pilgrim_id IS NULL THEN
    SELECT * INTO p FROM pilgrims WHERE user_id = u.id;
  ELSE
    SELECT * INTO p FROM pilgrims WHERE id = p_pilgrim_id;
  END IF;
  IF p.id IS NULL OR NOT (p.user_id = u.id OR _can_manage_group(u, p.group_id)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  IF coalesce(btrim(p_name), '') = '' THEN RAISE EXCEPTION 'NAME_REQUIRED' USING HINT = 'اكتب اسم الدواء'; END IF;
  BEGIN
    SELECT coalesce(array_agg(DISTINCT x::time ORDER BY x::time), '{}') INTO v_times
      FROM unnest(coalesce(p_times, '{}')) x WHERE btrim(x) <> '';
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'BAD_TIME' USING HINT = 'اكتب الأوقات بصيغة 08:00';
  END;
  INSERT INTO medications (pilgrim_id, name, condition, schedule_times, needs_fridge)
  VALUES (p.id, left(btrim(p_name), 120), nullif(left(btrim(coalesce(p_condition, '')), 80), ''), v_times, coalesce(p_needs_fridge, FALSE))
  RETURNING id INTO v_id;
  INSERT INTO medication_doses (medication_id, scheduled_at)
  SELECT v_id, (v_today + t) AT TIME ZONE 'Asia/Riyadh' FROM unnest(v_times) t
   WHERE (v_today + t) AT TIME ZONE 'Asia/Riyadh' > now()
  ON CONFLICT (medication_id, scheduled_at) DO NOTHING;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  PERFORM _log(u.id, 'ADD_MEDICATION', 'medications', v_id, p.group_id, 'أضاف دواء ' || btrim(p_name) || ' للحاج #' || p.id);
  RETURN json_build_object('medication_id', v_id, 'doses_today', v_n);
END $$;

CREATE OR REPLACE FUNCTION app_stop_medication(p_token UUID, p_medication_id BIGINT)
RETURNS VOID LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE u users; p pilgrims;
BEGIN
  u := _auth(p_token);
  SELECT pp.* INTO p FROM medications m JOIN pilgrims pp ON pp.id = m.pilgrim_id WHERE m.id = p_medication_id;
  IF p.id IS NULL OR NOT (p.user_id = u.id OR _can_manage_group(u, p.group_id)) THEN RAISE EXCEPTION 'FORBIDDEN'; END IF;
  UPDATE medications SET is_active = FALSE WHERE id = p_medication_id;
  UPDATE medication_doses SET status = 'SKIPPED' WHERE medication_id = p_medication_id AND status = 'DUE';
  PERFORM _log(u.id, 'STOP_MEDICATION', 'medications', p_medication_id, p.group_id, 'أوقف دواء #' || p_medication_id);
END $$;

REVOKE ALL ON FUNCTION app_my_hajj(uuid, int) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION app_add_medication(uuid, text, bigint, text, text[], boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION app_stop_medication(uuid, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_my_hajj(uuid, int) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION app_add_medication(uuid, text, bigint, text, text[], boolean) TO anon, authenticated;
GRANT EXECUTE ON FUNCTION app_stop_medication(uuid, bigint) TO anon, authenticated;
SELECT 'v4.3 ok' AS status;
