import 'package:flutter_test/flutter_test.dart';

import 'package:ain_alhamla/l10n/strings.dart';
import 'package:ain_alhamla/services/geo.dart';
import 'package:ain_alhamla/services/map_cache.dart';
import 'package:ain_alhamla/services/offline_tiles.dart';

/// اختبارات الخريطة بدون إنترنت — نفس قيم دوال الخادم _dist_m و _bearing.
void main() {
  test('المسافة والاتجاه تُحسب داخل الجوال بنفس نتيجة الخادم', () {
    // من مخيم منى إلى الجمرات
    expect(Geo.distanceM(21.4135, 39.8905, 21.4207, 39.8724), 2038);
    expect(Geo.bearing(21.4135, 39.8905, 21.4207, 39.8724), 293);
    // من مخيم منى إلى عرفات
    expect(Geo.distanceM(21.4135, 39.8905, 21.3555, 39.9847), 11693);
    expect(Geo.bearing(21.4135, 39.8905, 21.3555, 39.9847), 123);
  });

  test('مؤشر القرب بدون إنترنت من البيانات المحفوظة', () {
    final data = {
      'generated_at': DateTime.now().toUtc().toIso8601String(),
      'locations': [
        {'id': 5, 'name': 'مخيم الحملة — منى', 'type': 'SAFE_ZONE', 'lat': 21.4135, 'lng': 39.8905, 'radius_m': 250},
        {'id': 6, 'name': 'الجمرات', 'type': 'CHECKPOINT', 'lat': 21.4207, 'lng': 39.8724, 'radius_m': 400},
      ],
      'gatherings': [
        {
          'id': 3, 'title': 'التجمع عند المخيم', 'group_id': 1, 'status': 'OPEN', 'location': 'مخيم الحملة — منى',
          'scheduled_at': DateTime.now().toUtc().add(const Duration(minutes: 20)).toIso8601String(),
          'deadline_minutes': 15, 'lat': 21.4135, 'lng': 39.8905, 'radius_m': 250,
        },
      ],
      'supervisors': [
        {'name': 'خالد', 'lat': 21.4136, 'lng': 39.8903, 'at': DateTime.now().toUtc().toIso8601String()},
      ],
    };
    // الحاج عند الجمرات بدون إنترنت
    final p = MapCache.localProximity(data, 21.4207, 39.8724, groupId: 1)!;
    expect(p['offline'], true);
    expect((p['zone'] as Map)['name'], 'الجمرات');
    expect((p['zone'] as Map)['inside'], true);
    expect((p['gathering'] as Map)['distance_m'], 2038);
    expect((p['gathering'] as Map)['bearing'], 113); // عكس اتجاه 293 تقريباً
    expect((p['supervisor'] as Map)['distance_m'], greaterThan(2000));
  });

  test('صور الخريطة المحفوظة محصورة حول مواقع الحملة فقط', () {
    final tiles = OfflineTiles.tilesAround([
      (lat: 21.4135, lng: 39.8905, radius: 250),
      (lat: 21.4207, lng: 39.8724, radius: 400),
    ]);
    expect(tiles.length, greaterThan(20));
    expect(tiles.length, lessThan(400));
    expect(tiles.every((t) => t.z >= 11 && t.z <= 17), true);
  });

  test('نصوص الخريطة متوفرة بالأربع لغات', () {
    for (final lang in S.supported) {
      final s = S(lang);
      for (final k in ['tab_map', 'map_offline', 'map_save', 'last_known', 'walk_min', 'gps_off']) {
        expect(s.t(k) != k, true, reason: '$lang/$k');
      }
    }
  });
}
