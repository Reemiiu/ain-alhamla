import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../l10n/strings.dart';
import '../services/api.dart';
import '../services/geo.dart';
import '../services/location_service.dart';
import '../services/map_cache.dart';
import '../services/offline_tiles.dart';

/// حالة التطبيق: المستخدم ودوره، ملفه، اللغة والخط الكبير، مؤشر القرب، والتتبع الدوري.
/// + بيانات الخريطة المحفوظة على الجوال: عند انقطاع الإنترنت يُحسب مؤشر القرب محلياً.
class SessionProvider extends ChangeNotifier {
  Map<String, dynamic>? user;
  Map<String, dynamic>? me;
  Map<String, dynamic>? proximity;
  bool restoring = true;

  /// آخر بيانات خريطة (app_map_data) — محفوظة على الجوال
  Map<String, dynamic>? mapData;

  /// آخر موقع GPS للجوال (يعمل بدون إنترنت)
  double? myLat, myLng;
  DateTime? myFixAt;

  String lang = 'ar';

  /// سؤال «أنت بخير؟» المفتوح — تعرضه واجهة الحاج فوق أي شاشة
  final ValueNotifier<Map<String, dynamic>?> wellness = ValueNotifier<Map<String, dynamic>?>(null);
  double? _stillLat, _stillLng;
  DateTime? _stillSince, _lastWellnessAt;
  bool largeText = false;

  Timer? _pingTimer;
  Timer? _flushTimer;
  Timer? _mapTimer;

  String get role => (user?['role'] as String?) ?? '';
  bool get isPilgrim => role == 'PILGRIM';
  bool get isStaff => role == 'SUPERVISOR' || role == 'ADMIN' || role == 'OPERATIONS_CENTER';
  bool get loggedIn => user != null;

  Map<String, dynamic>? get pilgrim => _m(me?['pilgrim']);
  Map<String, dynamic>? get group => _m(me?['group']);
  Map<String, dynamic>? get campaign => _m(me?['campaign']);
  List<Map<String, dynamic>> get contacts => _list(me?['contacts']);
  List<Map<String, dynamic>> get staffGroups => _list(me?['groups']);

  static Map<String, dynamic>? _m(dynamic v) => v == null ? null : Map<String, dynamic>.from(v as Map);
  static List<Map<String, dynamic>> _list(dynamic v) =>
      v == null ? [] : (v as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<void> restore() async {
    lang = Api.prefs.getString('ain_lang') ?? 'ar';
    largeText = Api.prefs.getBool('ain_large') ?? false;
    mapData = MapCache.load();
    if (Api.token != null) {
      try {
        await refreshMe();
        user = _m(me?['user']);
        _startTimers();
      } on ApiException catch (e) {
        if (!e.network) await Api.saveToken(null);
        // بدون شبكة: نُبقي الجلسة ونعرض آخر ملف محفوظ (رقم المشرف، بطاقة الطوارئ، المجموعة)
        if (e.network) {
          me = _savedMe();
          user = _m(me?['user']) ??
              {'role': Api.prefs.getString('ain_role') ?? 'PILGRIM', 'full_name': Api.prefs.getString('ain_name') ?? ''};
          _startTimers();
        }
      }
    }
    restoring = false;
    notifyListeners();
  }

  Future<bool> login(String nationalId, String password) async {
    final res = await Api.login(nationalId, password);
    if (res == null) return false;
    await Api.saveToken(res['token'] as String);
    user = _m(res['user']);
    await Api.prefs.setString('ain_role', role);
    await Api.prefs.setString('ain_name', (user?['full_name'] as String?) ?? '');
    await refreshMe();
    final pl = pilgrim?['preferred_language'] as String?;
    if (pl != null && S.supported.contains(pl)) {
      lang = pl;
      largeText = (pilgrim?['large_text'] as bool?) ?? largeText;
      await Api.prefs.setString('ain_lang', lang);
      await Api.prefs.setBool('ain_large', largeText);
    }
    _startTimers();
    notifyListeners();
    return true;
  }

  /// يجلب بيانات الخريطة ويحفظها على الجوال. أول مرة: يبدأ حفظ صور خريطة مواقع الحملة.
  Future<bool> refreshMapData() async {
    try {
      final r = await Api.call('app_map_data');
      if (r == null) return false;
      mapData = Map<String, dynamic>.from(r as Map);
      await MapCache.save(mapData!);
      notifyListeners();
      // أول مرة (أو إذا تغيّرت مواقع الحملة): تنزيل هادئ في الخلفية لصور المنطقة حول المواقع فقط
      final points = MapCache.points(mapData);
      final key = MapCache.pointsKey(points);
      if (points.isNotEmpty && Api.prefs.getString('ain_tiles_key') != key) {
        OfflineTiles.prefetch(points).then((complete) {
          if (complete) Api.prefs.setString('ain_tiles_key', key);
        });
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// مؤشر القرب من البيانات المحفوظة (بدون إنترنت)
  void _applyLocalProximity() {
    if (myLat == null || myLng == null || mapData == null) return;
    final local = MapCache.localProximity(mapData, myLat!, myLng!,
        at: myFixAt, groupId: group?['id'] as int?, previous: proximity);
    if (local != null) {
      proximity = local;
      notifyListeners();
    }
  }

  /// تحديث موقعي من الخريطة (بث GPS مباشر) — بدون انتظار دورة الإرسال
  void updateMyPosition(double lat, double lng) {
    myLat = lat;
    myLng = lng;
    myFixAt = DateTime.now();
    if (proximity == null || proximity?['offline'] == true || !Api.online.value) {
      _applyLocalProximity();
    } else {
      notifyListeners();
    }
  }

  Future<void> refreshMe() async {
    final r = await Api.call('app_me');
    me = _m(r);
    if (r != null) await Api.prefs.setString('ain_me', jsonEncode(r));
    notifyListeners();
  }

  /// آخر ملف للمستخدم محفوظ على الجوال (يُستخدم عند فتح التطبيق بدون إنترنت)
  static Map<String, dynamic>? _savedMe() {
    final raw = Api.prefs.getString('ain_me');
    if (raw == null) return null;
    try {
      return Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {
      return null;
    }
  }

  Future<void> logout() async {
    _pingTimer?.cancel();
    _flushTimer?.cancel();
    _mapTimer?.cancel();
    OfflineTiles.cancel();
    await MapCache.clear();
    await Api.prefs.remove('ain_me');
    mapData = null;
    myLat = null;
    myLng = null;
    try {
      await Api.call('app_logout');
    } catch (_) {}
    await Api.saveToken(null);
    await Api.clearQueue();
    user = null;
    me = null;
    proximity = null;
    wellness.value = null;
    _stillLat = null;
    _stillSince = null;
    notifyListeners();
  }

  Future<void> setLanguage(String l) async {
    lang = l;
    await Api.prefs.setString('ain_lang', l);
    notifyListeners();
    if (isPilgrim) {
      try {
        await Api.call('app_update_preferences', {'p_language': l, 'p_large_text': largeText});
      } catch (_) {}
    }
  }

  Future<void> setLargeText(bool v) async {
    largeText = v;
    await Api.prefs.setBool('ain_large', v);
    notifyListeners();
    if (isPilgrim) {
      try {
        await Api.call('app_update_preferences', {'p_language': lang, 'p_large_text': v});
      } catch (_) {}
    }
  }

  // ------------------------- التتبع الدوري -------------------------
  void _startTimers() {
    _pingTimer?.cancel();
    _flushTimer?.cancel();
    _mapTimer?.cancel();
    refreshMapData().whenComplete(() => sendPing(askPermission: true));
    _pingTimer = Timer.periodic(const Duration(seconds: 60), (_) => sendPing());
    _flushTimer = Timer.periodic(const Duration(seconds: 30), (_) => Api.flush());
    _mapTimer = Timer.periodic(const Duration(minutes: 5), (_) => refreshMapData());
  }

  /// يرسل الموقع الحالي + البطارية، ويحدّث مؤشر القرب.
  Future<void> sendPing({bool askPermission = false}) async {
    if (Api.token == null) return;
    final pos = await LocationService.current(askPermission: askPermission);
    if (pos == null) {
      await refreshProximity();
      return;
    }
    myLat = pos.latitude;
    myLng = pos.longitude;
    myFixAt = DateTime.now();
    _trackStillness(pos.latitude, pos.longitude);
    final battery = await LocationService.battery();
    try {
      final r = await Api.callOrQueue('app_record_ping', {
        'p_lat': pos.latitude,
        'p_lng': pos.longitude,
        'p_accuracy': pos.accuracy.round(),
        'p_battery': battery,
        'p_recorded_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (r != null) {
        proximity = _m(r);
        notifyListeners();
      } else {
        // لا يوجد إنترنت: حُفظ الموقع في الطابور، ونحسب المسافة والسهم من الخريطة المحفوظة
        _applyLocalProximity();
      }
    } catch (_) {}
  }

  /// يرصد توقف الحركة: إن بقي الحاج في نفس المكان (أقل من 40 م) 25 دقيقة يسأل الخادم،
  /// والخادم يقرر: داخل المخيم = لا سؤال، خارجه = «أنت بخير؟» وإن لم يرد خلال دقيقة يُبلَّغ المشرف.
  Future<void> _trackStillness(double lat, double lng) async {
    if (!isPilgrim) return;
    final now = DateTime.now();
    if (_stillLat == null || _stillLng == null || _stillSince == null ||
        Geo.distanceM(_stillLat!, _stillLng!, lat, lng) > 40) {
      _stillLat = lat;
      _stillLng = lng;
      _stillSince = now;
      return;
    }
    final minutes = now.difference(_stillSince!).inMinutes;
    if (minutes < 25) return;
    if (_lastWellnessAt != null && now.difference(_lastWellnessAt!).inMinutes < 30) return;
    _lastWellnessAt = now;
    try {
      final r = _m(await Api.call('app_wellness_report', {'p_still_minutes': minutes, 'p_lat': lat, 'p_lng': lng}));
      if (r != null && r['ask'] == true) {
        r['still_minutes'] = minutes;
        wellness.value = r;
      }
    } catch (_) {}
  }

  Future<void> refreshProximity() async {
    try {
      proximity = _m(await Api.call('app_proximity'));
      notifyListeners();
    } on ApiException catch (e) {
      if (e.network) _applyLocalProximity();
    } catch (_) {}
  }

  @override
  void dispose() {
    _pingTimer?.cancel();
    _flushTimer?.cancel();
    _mapTimer?.cancel();
    super.dispose();
  }
}
