import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// خطأ موحّد: code من الخادم (FORBIDDEN, SESSION_EXPIRED...) أو NETWORK عند انقطاع الشبكة.
class ApiException implements Exception {
  final String code;
  final String message;
  final bool network;
  ApiException(this.code, this.message, {this.network = false});
  @override
  String toString() => message;
}

/// طبقة الاتصال بالقاعدة: كل العمليات عبر دوال app_* التي تتحقق من الجلسة والدور داخل الخادم،
/// مع طابور لعدم الاتصال (ضعف الشبكة في المشاعر): ما لم يُرسل يُحفظ ويُرسل لاحقاً بوقت الجهاز الأصلي.
class Api {
  Api._();

  static SupabaseClient get _c => Supabase.instance.client;
  static late SharedPreferences prefs;
  static String? token;

  static final ValueNotifier<int> pending = ValueNotifier<int>(0);
  static final ValueNotifier<bool> online = ValueNotifier<bool>(true);

  static const _kToken = 'ain_token';
  static const _kQueue = 'ain_queue';

  static Future<void> init() async {
    prefs = await SharedPreferences.getInstance();
    token = prefs.getString(_kToken);
    pending.value = _queue().length;
  }

  static Future<void> saveToken(String? t) async {
    token = t;
    if (t == null) {
      await prefs.remove(_kToken);
    } else {
      await prefs.setString(_kToken, t);
    }
  }

  /// يستدعي دالة app_* مع رمز الجلسة.
  static Future<dynamic> call(String fn, [Map<String, dynamic> params = const {}]) async {
    try {
      final res = await _c.rpc(fn, params: {'p_token': token, ...params});
      online.value = true;
      return res;
    } on PostgrestException catch (e) {
      online.value = true;
      throw ApiException(e.message, e.hint ?? e.message);
    } catch (e) {
      online.value = false;
      throw ApiException('NETWORK', 'network', network: true);
    }
  }

  /// تسجيل الدخول — يعيد {token, user} أو null إن كانت البيانات خاطئة.
  static Future<Map<String, dynamic>?> login(String nationalId, String password) async {
    try {
      final res = await _c.rpc('app_login', params: {'p_national_id': nationalId, 'p_password': password});
      online.value = true;
      if (res == null) return null;
      return Map<String, dynamic>.from(res as Map);
    } on PostgrestException catch (e) {
      throw ApiException(e.message, e.hint ?? e.message);
    } catch (e) {
      online.value = false;
      throw ApiException('NETWORK', 'network', network: true);
    }
  }

  // ------------------------- طابور عدم الاتصال -------------------------
  static List<Map<String, dynamic>> _queue() {
    final raw = prefs.getString(_kQueue);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> _saveQueue(List<Map<String, dynamic>> q) async {
    await prefs.setString(_kQueue, jsonEncode(q));
    pending.value = q.length;
  }

  /// يحاول الإرسال فوراً؛ إن انقطعت الشبكة يُحفظ في الطابور ويعيد null.
  /// (الحضور ونبضات الموقع وSOS تحمل وقت الجهاز p_recorded_at فتُحتسب بدقة عند الإرسال لاحقاً)
  static Future<dynamic> callOrQueue(String fn, Map<String, dynamic> params) async {
    try {
      final r = await call(fn, params);
      flush();
      return r;
    } on ApiException catch (e) {
      if (!e.network) rethrow;
      final q = _queue();
      // نبضات الموقع: نحتفظ بآخر 20 فقط حتى لا يتضخم الطابور
      if (fn == 'app_record_ping' && q.where((x) => x['fn'] == fn).length >= 20) {
        q.removeAt(q.indexWhere((x) => x['fn'] == fn));
      }
      q.add({'fn': fn, 'params': params});
      await _saveQueue(q);
      return null;
    }
  }

  static bool _flushing = false;

  /// يرسل ما في الطابور بالترتيب، ويتوقف عند أول انقطاع.
  static Future<int> flush() async {
    if (_flushing || token == null) return 0;
    _flushing = true;
    var sent = 0;
    try {
      final q = _queue();
      while (q.isNotEmpty) {
        final item = q.first;
        try {
          await call(item['fn'] as String, Map<String, dynamic>.from(item['params'] as Map));
          sent++;
        } on ApiException catch (e) {
          if (e.network) break;
          // خطأ منطقي (مثل تجمع أُغلق): لا فائدة من إعادة المحاولة
        }
        q.removeAt(0);
        await _saveQueue(q);
      }
    } finally {
      _flushing = false;
    }
    return sent;
  }

  static Future<void> clearQueue() => _saveQueue([]);
}
