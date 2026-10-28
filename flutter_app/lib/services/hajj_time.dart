import 'dart:math' as math;

/// أدوات زمن الحج، تعمل على الجوال بدون إنترنت:
/// - التاريخ الهجري (التقويم الجدولي، قد يختلف يوماً عن إعلان الرؤية)
/// - مواقيت الصلاة بطريقة أم القرى (الفجر 18.5°، العشاء = المغرب + 90 دقيقة، و120 في رمضان)
/// - اتجاه القبلة من موقع الحاج
class HajjTime {
  HajjTime._();

  static const double kaabaLat = 21.422487;
  static const double kaabaLng = 39.826206;

  /// ترتيب الصلوات كما تظهر في الشاشة
  static const prayers = ['fajr', 'sunrise', 'dhuhr', 'asr', 'maghrib', 'isha'];

  static int _jd(int y, int m, int d) {
    final a = (14 - m) ~/ 12;
    final yy = y + 4800 - a;
    final mm = m + 12 * a - 3;
    return d + (153 * mm + 2) ~/ 5 + 365 * yy + yy ~/ 4 - yy ~/ 100 + yy ~/ 400 - 32045;
  }

  /// الوقت الحالي بتوقيت مكة (UTC+3) — المناسك والجرعات كلها بتوقيت مكة
  static DateTime meccaNow() => DateTime.now().toUtc().add(const Duration(hours: 3));

  /// [السنة، الشهر، اليوم] بالهجري لتاريخ ميلادي
  static List<int> hijri(DateTime date) {
    var l = _jd(date.year, date.month, date.day) - 1948440 + 10632;
    final n = (l - 1) ~/ 10631;
    l = l - 10631 * n + 354;
    final j = ((10985 - l) ~/ 5316) * ((50 * l) ~/ 17719) + (l ~/ 5670) * ((43 * l) ~/ 15238);
    l = l - ((30 - j) ~/ 15) * ((17719 * j) ~/ 50) - (j ~/ 16) * ((15238 * j) ~/ 43) + 29;
    final m = (24 * l) ~/ 709;
    final d = l - (709 * m) ~/ 24;
    final y = 30 * n + j - 30;
    return [y, m, d];
  }

  /// يوم ذي الحجة اليوم (من 8 إلى 13)، أو null خارج أيام الحج
  static int? hajjDayToday() {
    final h = hijri(meccaNow());
    if (h[1] == 12 && h[2] >= 8 && h[2] <= 13) return h[2];
    return null;
  }

  /// مواقيت يوم كامل (أوقات UTC). الافتراضي: مكة المكرمة.
  static Map<String, DateTime> prayerTimes(DateTime meccaDay, {double lat = 21.4225, double lng = 39.8262}) {
    double rad(double d) => d * math.pi / 180;
    double deg(double r) => r * 180 / math.pi;
    final d = _jd(meccaDay.year, meccaDay.month, meccaDay.day) - 0.5 - 2451545.0;
    final g = rad((357.529 + 0.98560028 * d) % 360);
    final q = (280.459 + 0.98564736 * d) % 360;
    final lam = rad((q + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) % 360);
    final e = rad(23.439 - 0.00000036 * d);
    var ra = deg(math.atan2(math.cos(e) * math.sin(lam), math.cos(lam))) / 15;
    ra = (ra + 24) % 24;
    final decl = math.asin(math.sin(e) * math.sin(lam));
    var eqt = q / 15 - ra;
    eqt = (eqt + 12) % 24 - 12;
    final noon = 12 + 3 - lng / 15 - eqt;
    final la = rad(lat);
    double hourAngle(double altitude) {
      final c = (math.sin(altitude) - math.sin(decl) * math.sin(la)) / (math.cos(decl) * math.cos(la));
      return deg(math.acos(c.clamp(-1.0, 1.0))) / 15;
    }

    final sun = hourAngle(rad(-0.833));
    final asrAlt = math.atan(1 / (1 + math.tan((la - decl).abs())));
    final ramadan = hijri(meccaDay)[1] == 9;
    final maghrib = noon + sun;
    final hours = <String, double>{
      'fajr': noon - hourAngle(rad(-18.5)),
      'sunrise': noon - sun,
      'dhuhr': noon,
      'asr': noon + hourAngle(asrAlt),
      'maghrib': maghrib,
      'isha': maghrib + (ramadan ? 2.0 : 1.5),
    };
    final base = DateTime.utc(meccaDay.year, meccaDay.month, meccaDay.day);
    return hours.map((k, h) => MapEntry(k, base.add(Duration(minutes: ((h - 3) * 60).round()))));
  }

  /// الصلاة القادمة اليوم أو فجر الغد: (المفتاح، الوقت UTC)
  static MapEntry<String, DateTime> nextPrayer({double lat = 21.4225, double lng = 39.8262}) {
    final now = DateTime.now().toUtc();
    final today = meccaNow();
    final t = prayerTimes(today, lat: lat, lng: lng);
    for (final k in prayers) {
      if (k == 'sunrise') continue;
      if (t[k]!.isAfter(now)) return MapEntry(k, t[k]!);
    }
    final tomorrow = prayerTimes(today.add(const Duration(days: 1)), lat: lat, lng: lng);
    return MapEntry('fajr', tomorrow['fajr']!);
  }

  /// اتجاه القبلة بالدرجات من الشمال
  static int qibla(double lat, double lng) {
    final p = lat * math.pi / 180;
    final k = kaabaLat * math.pi / 180;
    final dl = (kaabaLng - lng) * math.pi / 180;
    final b = math.atan2(math.sin(dl), math.cos(p) * math.tan(k) - math.sin(p) * math.cos(dl));
    return ((b * 180 / math.pi).round() + 360) % 360;
  }

  /// HH:MM بتوقيت مكة
  static String clock(DateTime utc) {
    final m = utc.toUtc().add(const Duration(hours: 3));
    return '${m.hour.toString().padLeft(2, '0')}:${m.minute.toString().padLeft(2, '0')}';
  }
}
