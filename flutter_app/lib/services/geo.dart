import 'dart:math' as math;

/// حسابات جغرافية تعمل داخل الجوال بدون إنترنت (نفس معادلات الخادم _dist_m و _bearing).
class Geo {
  Geo._();

  static const double _earthRadius = 6371000;

  static double _rad(num d) => d * math.pi / 180;

  /// المسافة بالمتر بين نقطتين (Haversine)
  static int distanceM(num lat1, num lng1, num lat2, num lng2) {
    final dLat = _rad(lat2 - lat1);
    final dLng = _rad(lng2 - lng1);
    final a = math.pow(math.sin(dLat / 2), 2) +
        math.cos(_rad(lat1)) * math.cos(_rad(lat2)) * math.pow(math.sin(dLng / 2), 2);
    return (2 * _earthRadius * math.asin(math.sqrt(a))).round();
  }

  /// اتجاه البوصلة بالدرجات من النقطة 1 إلى النقطة 2 (0 = شمال)
  static int bearing(num lat1, num lng1, num lat2, num lng2) {
    final dLng = _rad(lng2 - lng1);
    final y = math.sin(dLng) * math.cos(_rad(lat2));
    final x = math.cos(_rad(lat1)) * math.sin(_rad(lat2)) - math.sin(_rad(lat1)) * math.cos(_rad(lat2)) * math.cos(dLng);
    final deg = math.atan2(y, x) * 180 / math.pi;
    return ((deg.round() % 360) + 360) % 360;
  }

  /// زمن المشي التقريبي بالدقائق (سرعة مشي متوسطة في الزحام ≈ 4 كم/س)
  static int walkMinutes(num meters) => math.max(1, (meters / 66.7).round());

  /// رقم البلاطة (tile) في خرائط OSM لإحداثية وزوم
  static int tileX(double lng, int z) => ((lng + 180) / 360 * (1 << z)).floor();
  static int tileY(double lat, int z) {
    final r = _rad(lat);
    return ((1 - math.log(math.tan(r) + 1 / math.cos(r)) / math.pi) / 2 * (1 << z)).floor();
  }

  /// إزاحة إحداثية بعدد أمتار (لتكوين مربع حول نقطة)
  static double metersToLat(num m) => m / 111320;
  static double metersToLng(num m, num atLat) => m / (111320 * math.cos(_rad(atLat)));
}

/// يحوّل قيمة JSON (رقم أو نص) إلى double
double? asDouble(dynamic v) => v == null ? null : (v is num ? v.toDouble() : double.tryParse('$v'));
