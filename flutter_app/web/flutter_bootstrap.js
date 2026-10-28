{{flutter_js}}
{{flutter_build_config}}

// عين الحملة: بدون service worker القديم من Flutter (يحذف نفسه).
// التطبيق يستخدم ain_sw.js بدلاً منه ليفتح بدون إنترنت.
_flutter.loader.load();
