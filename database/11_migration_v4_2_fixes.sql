-- =====================================================================
-- عين الحملة — v4.2: إصلاح صغير بعد الربط بلوحة التحكم (آمن لإعادة التشغيل)
-- app_report_found: حساب الإدارة (بدون حملة مشرف) يستطيع تسجيل غرض موجود
-- =====================================================================
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


REVOKE ALL ON FUNCTION app_report_found(uuid, bigint, text, text, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION app_report_found(uuid, bigint, text, text, bigint) TO anon, authenticated;
SELECT 'v4.2 ok' AS status;
