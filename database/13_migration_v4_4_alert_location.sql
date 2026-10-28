-- =====================================================================
-- عين الحملة — v4.4: كل تنبيه يحمل آخر موقع معروف للحاج (آمن لإعادة التشغيل)
-- تنبيهات «خارج حدود المشعر» و«انفصال الرفيق» و«الإجهاد الحراري» و«لا حركة» و«الغياب»
-- كانت تُنشأ بدون إحداثيات، فلا تظهر خريطة في صفحة الاستجابة. هذا المُشغِّل يملؤها
-- من آخر نبضة GPS للحاج خلال ٣ ساعات (إن لم يرسل البلاغُ موقعَه بنفسه).
-- =====================================================================
CREATE OR REPLACE FUNCTION _alert_fill_location()
RETURNS trigger LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_lat NUMERIC; v_lng NUMERIC;
BEGIN
  IF NEW.latitude IS NULL AND NEW.pilgrim_id IS NOT NULL THEN
    SELECT l.latitude, l.longitude INTO v_lat, v_lng
      FROM location_pings l JOIN pilgrims p ON p.user_id = l.user_id
     WHERE p.id = NEW.pilgrim_id AND l.client_recorded_at > now() - interval '3 hours'
     ORDER BY l.client_recorded_at DESC LIMIT 1;
    NEW.latitude := v_lat;
    NEW.longitude := v_lng;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS trg_alert_fill_location ON alerts;
CREATE TRIGGER trg_alert_fill_location BEFORE INSERT ON alerts
  FOR EACH ROW EXECUTE FUNCTION _alert_fill_location();

-- التنبيهات المفتوحة الحالية: آخر موقع قبل وقت التنبيه
UPDATE alerts a SET latitude = x.latitude, longitude = x.longitude
  FROM (SELECT DISTINCT ON (a2.id) a2.id, l.latitude, l.longitude
          FROM alerts a2 JOIN pilgrims p ON p.id = a2.pilgrim_id JOIN location_pings l ON l.user_id = p.user_id
         WHERE a2.status <> 'RESOLVED' AND a2.latitude IS NULL
           AND l.client_recorded_at BETWEEN a2.created_at - interval '3 hours' AND a2.created_at + interval '5 minutes'
         ORDER BY a2.id, l.client_recorded_at DESC) x
 WHERE a.id = x.id;

SELECT 'v4.4 ok' AS status,
       (SELECT count(*) FROM alerts WHERE status <> 'RESOLVED' AND latitude IS NOT NULL) AS open_alerts_with_location,
       (SELECT count(*) FROM alerts WHERE status <> 'RESOLVED' AND latitude IS NULL) AS open_alerts_without_location;
