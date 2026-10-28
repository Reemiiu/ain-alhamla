import 'package:battery_plus/battery_plus.dart';
import 'package:geolocator/geolocator.dart';

/// موقع GPS من جوال الحاج/المشرف — بدون أي هاردوير إضافي.
class LocationService {
  LocationService._();

  static final Battery _battery = Battery();

  /// يعيد الموقع الحالي، أو null إذا كانت الخدمة مطفأة أو الإذن مرفوضاً أو تأخر.
  static Future<Position?> current({bool askPermission = true}) async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return null;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied && askPermission) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        return null;
      }
      return await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 10));
    } catch (_) {
      try {
        return await Geolocator.getLastKnownPosition();
      } catch (_) {
        return null;
      }
    }
  }

  /// نسبة بطارية الجوال (لتنبيه المشرف قبل أن ينقطع تتبّع الحاج).
  static Future<int?> battery() async {
    try {
      return await _battery.batteryLevel;
    } catch (_) {
      return null;
    }
  }
}
