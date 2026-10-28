import 'dart:convert';

import 'api.dart';
import 'geo.dart';

/// آخر نسخة من بيانات الخريطة (app_map_data) محفوظة على الجوال:
/// نقاط التجمع والنطاقات الآمنة، التجمعات القادمة، آخر موقع معروف للمشرف، ومركز المجموعة.
/// منها يُحسب مؤشر القرب (المسافة والسهم) داخل الجوال عند انقطاع الإنترنت.
class MapCache {
  MapCache._();

  static const _kData = 'ain_map_data';

  static Map<String, dynamic>? load() {
    final raw = Api.prefs.getString(_kData);
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(Map<String, dynamic> data) => Api.prefs.setString(_kData, jsonEncode(data));

  static Future<void> clear() => Api.prefs.remove(_kData);

  static List<Map<String, dynamic>> list(Map<String, dynamic>? data, String key) {
    final v = data?[key];
    if (v is! List) return [];
    return v.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// نقاط الحملة (للتنزيل المسبق لصور الخريطة)
  static List<({double lat, double lng, int radius})> points(Map<String, dynamic>? data) => [
        for (final l in list(data, 'locations'))
          if (asDouble(l['lat']) != null && asDouble(l['lng']) != null)
            (lat: asDouble(l['lat'])!, lng: asDouble(l['lng'])!, radius: (l['radius_m'] as num?)?.toInt() ?? 200),
      ];

  /// مفتاح يتغيّر إذا تغيّرت مواقع الحملة (لإعادة تنزيل صور الخريطة)
  static String pointsKey(List<({double lat, double lng, int radius})> points) =>
      points.map((p) => '${p.lat},${p.lng},${p.radius}').join('|');

  /// التجمع الحالي/القادم (نفس منطق الخادم: غير مغلق، ومن آخر 6 ساعات فأحدث، الأقرب موعداً)
  static Map<String, dynamic>? nextGathering(Map<String, dynamic>? data, {int? groupId}) {
    final now = DateTime.now();
    final gs = list(data, 'gatherings').where((g) {
      if (groupId != null && g['group_id'] != groupId) return false;
      if (g['status'] == 'CLOSED') return false;
      final at = DateTime.tryParse('${g['scheduled_at']}');
      return at != null && at.isAfter(now.subtract(const Duration(hours: 6)));
    }).toList()
      ..sort((a, b) => '${a['scheduled_at']}'.compareTo('${b['scheduled_at']}'));
    return gs.isEmpty ? null : gs.first;
  }

  /// مؤشر القرب محسوباً على الجوال — بنفس شكل نتيجة app_proximity حتى تعمل الشاشات كما هي.
  /// [previous]: آخر نتيجة من الخادم (للاحتفاظ بحالة الحضور وأقرب فرد).
  static Map<String, dynamic>? localProximity(Map<String, dynamic>? data, double lat, double lng,
      {DateTime? at, int? groupId, Map<String, dynamic>? previous}) {
    if (data == null) return null;

    Map<String, dynamic>? target(dynamic tLat, dynamic tLng) {
      final a = asDouble(tLat), b = asDouble(tLng);
      if (a == null || b == null) return null;
      return {'distance_m': Geo.distanceM(lat, lng, a, b), 'bearing': Geo.bearing(lat, lng, a, b)};
    }

    final sups = list(data, 'supervisors');
    final sup = sups.isEmpty ? null : sups.first;

    Map<String, dynamic>? zone;
    for (final l in list(data, 'locations')) {
      final la = asDouble(l['lat']), lo = asDouble(l['lng']);
      if (la == null || lo == null) continue;
      final d = Geo.distanceM(lat, lng, la, lo);
      if (zone == null || d < (zone['distance_m'] as int)) {
        final r = (l['radius_m'] as num?)?.toInt() ?? 0;
        zone = {'name': l['name'], 'distance_m': d, 'radius_m': r, 'inside': d <= r};
      }
    }

    final g = nextGathering(data, groupId: groupId);
    Map<String, dynamic>? gathering;
    if (g != null) {
      final prevG = previous?['gathering'] is Map ? Map<String, dynamic>.from(previous!['gathering'] as Map) : null;
      gathering = {
        'id': g['id'],
        'title': g['title'],
        'location': g['location'],
        'scheduled_at': g['scheduled_at'],
        'deadline_minutes': g['deadline_minutes'],
        'status': g['status'],
        'lat': g['lat'],
        'lng': g['lng'],
        'radius_m': g['radius_m'],
        ...?target(g['lat'], g['lng']),
        'checked_in': (prevG != null && prevG['id'] == g['id']) ? prevG['checked_in'] : g['checked_in'],
      };
    }

    final center = data['group_center'] is Map ? Map<String, dynamic>.from(data['group_center'] as Map) : null;

    return {
      'offline': true,
      'data_at': data['generated_at'],
      'me': {'lat': lat, 'lng': lng, 'at': (at ?? DateTime.now()).toUtc().toIso8601String()},
      'supervisor': sup == null ? null : {...?target(sup['lat'], sup['lng']), 'at': sup['at'], 'name': sup['name']},
      'nearest_member': null,
      'group_center': center == null ? null : {...?target(center['lat'], center['lng']), 'members': center['members'], 'at': center['at']},
      'zone': zone,
      'gathering': gathering,
    };
  }
}
