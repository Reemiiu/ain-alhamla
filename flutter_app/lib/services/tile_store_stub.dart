import 'dart:typed_data';

/// نسخة الويب: المتصفح يحفظ صور الخريطة في ذاكرته المؤقتة تلقائياً،
/// فلا يوجد تخزين ملفات هنا.
class TileStore {
  TileStore._();

  static const bool supported = false;

  static Future<Uint8List?> read(int z, int x, int y) async => null;
  static Future<bool> has(int z, int x, int y) async => false;
  static Future<void> write(int z, int x, int y, Uint8List bytes) async {}
  static Future<({int count, int bytes})> stats() async => (count: 0, bytes: 0);
  static Future<void> clear() async {}
}
