import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;

import 'geo.dart';
import 'tile_store_stub.dart'
    if (dart.library.io) 'tile_store_io.dart'
    if (dart.library.js_interop) 'tile_store_web.dart';

export 'tile_store_stub.dart'
    if (dart.library.io) 'tile_store_io.dart'
    if (dart.library.js_interop) 'tile_store_web.dart' show TileStore;

/// خريطة تعمل بدون إنترنت:
/// 1) كل صورة خريطة تُعرض مرة تُحفظ على الجوال (أو في متصفح نسخة الويب) وتُقرأ منه لاحقاً.
/// 2) «حفظ خريطة المشاعر»: تنزيل مسبق لصور منطقة صغيرة حول مواقع الحملة فقط
///    (المخيم، الجمرات، عرفات، مزدلفة، الحرم...) وهو على شبكة جيدة.
/// GPS نفسه لا يحتاج إنترنت، فيظهر موقع الحاج على الخريطة المحفوظة.
class OfflineTiles {
  OfflineTiles._();

  /// مصدر صور الخريطة. OpenStreetMap مجاني للمشروع.
  /// للتشغيل الفعلي بأعداد كبيرة يُستبدل بمزوّد خرائط تجاري (MapTiler / Stadia) بنفس الصيغة.
  static const String urlTemplate = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
  static const String userAgentPackage = 'sa.edu.tvtc.ain_alhamla';
  static const String attribution = '© OpenStreetMap contributors';

  static final http.Client client = http.Client();
  static final CachedTileProvider provider = CachedTileProvider();

  /// تقدم التنزيل المسبق (للعرض في الواجهة)
  static final ValueNotifier<({int done, int total})?> progress = ValueNotifier(null);
  static bool _cancel = false;

  static String urlFor(int z, int x, int y) =>
      urlTemplate.replaceAll('{z}', '$z').replaceAll('{x}', '$x').replaceAll('{y}', '$y');

  /// يحسب صور الخريطة المطلوبة حول نقاط الحملة.
  /// لكل نقطة: هامش = 1.5 × نصف قطر النطاق (500 م على الأقل) بزوم 14–17،
  /// ونظرة عامة على كل المشاعر بزوم 11–13.
  static List<({int z, int x, int y})> tilesAround(List<({double lat, double lng, int radius})> points,
      {int minZoom = 14, int maxZoom = 17, int limit = 1500}) {
    final set = <String>{};
    final out = <({int z, int x, int y})>[];
    void add(int z, int x, int y) {
      if (set.add('$z/$x/$y')) out.add((z: z, x: x, y: y));
    }

    void box(double s, double w, double n, double e, int z) {
      final x0 = Geo.tileX(w, z), x1 = Geo.tileX(e, z);
      final y0 = Geo.tileY(n, z), y1 = Geo.tileY(s, z);
      for (var x = x0; x <= x1; x++) {
        for (var y = y0; y <= y1; y++) {
          add(z, x, y);
        }
      }
    }

    if (points.isEmpty) return out;
    // نظرة عامة
    final lats = points.map((p) => p.lat), lngs = points.map((p) => p.lng);
    final s = lats.reduce(math.min), n = lats.reduce(math.max);
    final w = lngs.reduce(math.min), e = lngs.reduce(math.max);
    for (var z = 11; z <= 13; z++) {
      box(s - 0.01, w - 0.01, n + 0.01, e + 0.01, z);
    }
    // تفاصيل حول كل موقع
    for (final p in points) {
      final m = math.max(500, (p.radius * 1.5).round());
      final dLat = Geo.metersToLat(m), dLng = Geo.metersToLng(m, p.lat);
      for (var z = minZoom; z <= maxZoom; z++) {
        box(p.lat - dLat, p.lng - dLng, p.lat + dLat, p.lng + dLng, z);
      }
    }
    return out.length > limit ? out.sublist(0, limit) : out;
  }

  /// ينزّل الصور غير المحفوظة واحدة واحدة (بهدوء حتى لا يُثقل على خادم الخرائط).
  /// يعيد true إذا اكتملت كل الصور، و false إذا انقطعت الشبكة أو أُلغي (يكمل في المرة القادمة).
  static Future<bool> prefetch(List<({double lat, double lng, int radius})> points) async {
    if (!TileStore.supported || progress.value != null) return false;
    final tiles = tilesAround(points);
    _cancel = false;
    var complete = true;
    progress.value = (done: 0, total: tiles.length);
    try {
      for (var i = 0; i < tiles.length; i++) {
        if (_cancel) {
          complete = false;
          break;
        }
        final t = tiles[i];
        if (!await TileStore.has(t.z, t.x, t.y)) {
          try {
            final res = await client
                .get(Uri.parse(urlFor(t.z, t.x, t.y)), headers: kIsWeb ? null : {'User-Agent': 'flutter_map ($userAgentPackage)'})
                .timeout(const Duration(seconds: 15));
            if (res.statusCode == 200 && res.bodyBytes.isNotEmpty) {
              await TileStore.write(t.z, t.x, t.y, res.bodyBytes);
            } else {
              complete = false;
            }
          } catch (_) {
            // انقطعت الشبكة: نتوقف ونكمل لاحقاً من حيث وقفنا
            complete = false;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 60));
        }
        progress.value = (done: i + 1, total: tiles.length);
      }
    } finally {
      progress.value = null;
    }
    return complete;
  }

  static void cancel() => _cancel = true;
}

/// مزوّد صور الخريطة: يقرأ من الجوال أولاً، وإن لم توجد الصورة ينزّلها ويحفظها.
class CachedTileProvider extends TileProvider {
  CachedTileProvider() : super();

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) {
    final url = getTileUrl(coordinates, options);
    if (!TileStore.supported) return NetworkImage(url);
    return CachedTileImage(z: coordinates.z, x: coordinates.x, y: coordinates.y, url: url, headers: headers);
  }
}

@immutable
class CachedTileImage extends ImageProvider<CachedTileImage> {
  final int z, x, y;
  final String url;
  final Map<String, String> headers;
  const CachedTileImage({required this.z, required this.x, required this.y, required this.url, required this.headers});

  @override
  Future<CachedTileImage> obtainKey(ImageConfiguration configuration) => SynchronousFuture<CachedTileImage>(this);

  @override
  ImageStreamCompleter loadImage(CachedTileImage key, ImageDecoderCallback decode) =>
      MultiFrameImageStreamCompleter(codec: _load(decode), scale: 1.0, debugLabel: url);

  Future<ui.Codec> _load(ImageDecoderCallback decode) async {
    var bytes = await TileStore.read(z, x, y);
    if (bytes == null) {
      final res = await OfflineTiles.client.get(Uri.parse(url), headers: kIsWeb ? null : headers).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200 || res.bodyBytes.isEmpty) {
        throw StateError('tile $z/$x/$y: HTTP ${res.statusCode}');
      }
      bytes = res.bodyBytes;
      unawaited(TileStore.write(z, x, y, bytes));
    }
    return decode(await ui.ImmutableBuffer.fromUint8List(bytes));
  }

  @override
  bool operator ==(Object other) => other is CachedTileImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}
