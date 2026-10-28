import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';

/// تخزين صور الخريطة على الجوال (أندرويد / iOS / سطح المكتب).
/// كل صورة تُحفظ في ملف داخل مجلد التطبيق، وتُقرأ منه عند انقطاع الإنترنت.
class TileStore {
  TileStore._();

  static const bool supported = true;
  static Directory? _dir;

  static Future<Directory> _root() async {
    if (_dir != null) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}${Platform.pathSeparator}map_tiles');
    if (!await d.exists()) await d.create(recursive: true);
    return _dir = d;
  }

  static Future<File> _file(int z, int x, int y) async =>
      File('${(await _root()).path}${Platform.pathSeparator}${z}_${x}_$y.png');

  static Future<Uint8List?> read(int z, int x, int y) async {
    try {
      final f = await _file(z, x, y);
      if (await f.exists()) return await f.readAsBytes();
    } catch (_) {}
    return null;
  }

  static Future<bool> has(int z, int x, int y) async {
    try {
      return await (await _file(z, x, y)).exists();
    } catch (_) {
      return false;
    }
  }

  static Future<void> write(int z, int x, int y, Uint8List bytes) async {
    try {
      await (await _file(z, x, y)).writeAsBytes(bytes);
    } catch (_) {}
  }

  /// عدد الصور المحفوظة وحجمها بالبايت
  static Future<({int count, int bytes})> stats() async {
    var count = 0, bytes = 0;
    try {
      await for (final e in (await _root()).list()) {
        if (e is File) {
          count++;
          bytes += await e.length();
        }
      }
    } catch (_) {}
    return (count: count, bytes: bytes);
  }

  static Future<void> clear() async {
    try {
      final d = await _root();
      if (await d.exists()) await d.delete(recursive: true);
      _dir = null;
    } catch (_) {}
  }
}
