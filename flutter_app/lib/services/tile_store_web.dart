import 'dart:js_interop';
import 'dart:typed_data';

import 'package:web/web.dart' as web;

/// نسخة الويب (التطبيق المنشور في website/app): تُحفظ صور الخريطة في
/// Cache Storage داخل المتصفح، فتبقى متاحة بعد انقطاع الإنترنت.
class TileStore {
  TileStore._();

  static const bool supported = true;
  static const _cacheName = 'ain-map-tiles-v1';
  static web.Cache? _cache;
  static bool _failed = false;

  static Future<web.Cache?> _open() async {
    if (_cache != null || _failed) return _cache;
    try {
      _cache = await web.window.caches.open(_cacheName).toDart;
    } catch (_) {
      _failed = true; // تصفح خاص أو متصفح لا يدعم Cache Storage
    }
    return _cache;
  }

  static String _key(int z, int x, int y) => '/__ain_tiles/$z/$x/$y.png';

  static Future<Uint8List?> read(int z, int x, int y) async {
    try {
      final c = await _open();
      if (c == null) return null;
      final r = await c.match(_key(z, x, y).toJS).toDart;
      if (r == null) return null;
      final buf = await r.arrayBuffer().toDart;
      return buf.toDart.asUint8List();
    } catch (_) {
      return null;
    }
  }

  static Future<bool> has(int z, int x, int y) async {
    try {
      final c = await _open();
      if (c == null) return false;
      return (await c.match(_key(z, x, y).toJS).toDart) != null;
    } catch (_) {
      return false;
    }
  }

  static Future<void> write(int z, int x, int y, Uint8List bytes) async {
    try {
      final c = await _open();
      if (c == null) return;
      await c.put(_key(z, x, y).toJS, web.Response(bytes.toJS)).toDart;
    } catch (_) {}
  }

  /// عدد الصور المحفوظة (الحجم غير متاح في المتصفح بدقة: -1)
  static Future<({int count, int bytes})> stats() async {
    try {
      final c = await _open();
      if (c == null) return (count: 0, bytes: -1);
      final keys = await c.keys().toDart;
      return (count: keys.toDart.length, bytes: -1);
    } catch (_) {
      return (count: 0, bytes: -1);
    }
  }

  static Future<void> clear() async {
    try {
      await web.window.caches.delete(_cacheName).toDart;
      _cache = null;
    } catch (_) {}
  }
}
