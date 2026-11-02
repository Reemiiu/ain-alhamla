import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'api.dart';

/// v4.5 «عائلتي ورفقتي»: آخر حالة لدائرة الحاج (app_circle_status) مشتركة بين بطاقة الرئيسية وشاشة الدائرة،
/// ومحفوظة على الجوال حتى تبقى آخر مواقع الأفراد متاحة بدون إنترنت.
class CircleStore {
  CircleStore._();

  static const _kCircle = 'ain_circle';
  static final ValueNotifier<Map<String, dynamic>?> data = ValueNotifier<Map<String, dynamic>?>(null);
  static bool _cacheLoaded = false;

  /// يقرأ آخر حالة محفوظة (مرة واحدة)
  static void loadCached() {
    if (_cacheLoaded) return;
    _cacheLoaded = true;
    final raw = Api.prefs.getString(_kCircle);
    if (raw == null) return;
    try {
      data.value = Map<String, dynamic>.from(jsonDecode(raw) as Map);
    } catch (_) {}
  }

  /// يجلب الحالة من الخادم ويحفظها. عند انقطاع الشبكة تبقى آخر حالة محفوظة ويعيد false.
  static Future<bool> refresh() async {
    loadCached();
    try {
      await set(await Api.call('app_circle_status'));
      return true;
    } on ApiException catch (e) {
      if (e.network) return false;
      rethrow;
    }
  }

  static Future<void> set(dynamic r) async {
    if (r == null) return;
    final m = Map<String, dynamic>.from(r as Map);
    data.value = m;
    await Api.prefs.setString(_kCircle, jsonEncode(m));
  }

  static Future<void> clear() async {
    data.value = null;
    _cacheLoaded = false;
    await Api.prefs.remove(_kCircle);
  }

  static Map<String, dynamic>? get circle {
    final c = data.value?['circle'];
    return c == null ? null : Map<String, dynamic>.from(c as Map);
  }

  static List<Map<String, dynamic>> get members {
    final l = data.value?['members'];
    return l == null ? [] : (l as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }
}
