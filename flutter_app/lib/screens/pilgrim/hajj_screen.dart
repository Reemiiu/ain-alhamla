import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../services/api.dart';
import '../../services/hajj_time.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// شاشة «حجّي»: كل ما يحتاجه الحاج في يومه، وكل ضغطة تُحفظ في قاعدة البيانات فوراً:
/// دليل اليوم بلغته، عدّاد الطواف والسعي والجمرات (app_counter_step)، مواقيت الصلاة والقبلة،
/// أدويته وجرعات اليوم (app_take_dose / app_add_medication)، رسائل المشرف المترجمة (app_voice_heard)،
/// قائمة التجهيز (app_prep_toggle)، والمفقودات (app_report_lost). البيانات كلها من app_my_hajj.
class HajjScreen extends StatefulWidget {
  const HajjScreen({super.key});

  @override
  State<HajjScreen> createState() => _HajjScreenState();
}

class _HajjScreenState extends State<HajjScreen> {
  late int _day;
  late bool _outside;
  Map<String, dynamic>? _data;
  bool _loading = true;
  String? _error;
  final Set<String> _busy = {};
  Timer? _clock;
  late final SessionProvider _session;

  @override
  void initState() {
    super.initState();
    _session = context.read<SessionProvider>();
    _session.wellness.addListener(_load);
    final today = HajjTime.hajjDayToday();
    _outside = today == null;
    _day = today ?? 9;
    _load();
    _clock = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _clock?.cancel();
    _session.wellness.removeListener(_load);
    super.dispose();
  }

  static Map<String, dynamic> _map(dynamic v) => v == null ? <String, dynamic>{} : Map<String, dynamic>.from(v as Map);
  static List<Map<String, dynamic>> _list(dynamic v) =>
      v == null ? <Map<String, dynamic>>[] : (v as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<void> _load() async {
    try {
      final r = await Api.call('app_my_hajj', {'p_day': _day});
      if (!mounted) return;
      setState(() {
        _data = _map(r);
        _loading = false;
        _error = null;
      });
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.network ? S.of(context).t('network_error') : e.message;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = '$e';
      });
    }
  }

  /// ينفّذ عملية على القاعدة مع منع الضغط المزدوج وإظهار الخطأ برسالة مفهومة
  Future<dynamic> _run(String key, Future<dynamic> Function() action) async {
    if (_busy.contains(key)) return null;
    setState(() => _busy.add(key));
    final s = S.of(context);
    try {
      return await action();
    } on ApiException catch (e) {
      if (mounted) {
        final local = s.t('h_err_${e.code}');
        final msg = e.network ? s.t('network_error') : (local.startsWith('h_err_') ? e.message : local);
        showSnack(context, msg, color: AppColors.danger);
      }
      return null;
    } finally {
      if (mounted) setState(() => _busy.remove(key));
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(s.t('h_title'))),
      body: _loading
          ? Center(child: Text(s.t('loading')))
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 32), children: [
                if (_error != null)
                  Panel(
                    border: AppColors.danger,
                    child: Row(children: [
                      Expanded(child: Text(_error!, style: const TextStyle(color: AppColors.danger))),
                      TextButton(onPressed: _load, child: Text(s.t('retry'))),
                    ]),
                  ),
                _dayHeader(s),
                if (_data?['wellness'] != null) ...[const SizedBox(height: 12), _wellnessCard(s)],
                const SizedBox(height: 12),
                _prayerCard(s),
                const SizedBox(height: 12),
                _guideCard(s),
                const SizedBox(height: 12),
                _countersCard(s),
                const SizedBox(height: 12),
                _medsCard(s),
                const SizedBox(height: 12),
                _voiceCard(s),
                const SizedBox(height: 12),
                _prepCard(s),
                const SizedBox(height: 12),
                _lostCard(s),
                const SizedBox(height: 8),
                // للعرض: يحاكي توقف الحركة ٣٠ دقيقة بدل الانتظار الفعلي (نفس دالة الخادم التي يستدعيها الجوال تلقائياً)
                TextButton.icon(
                  onPressed: _busy.contains('demo_well') ? null : _demoWellness,
                  icon: const Icon(Icons.science_outlined, size: 18),
                  label: Text(s.t('h_demo_wellness')),
                ),
              ]),
            ),
    );
  }

  // ------------------------------------------------------------ اليوم
  Widget _dayHeader(S s) {
    final h = HajjTime.hijri(HajjTime.meccaNow());
    final hijriText = h[1] == 12
        ? s.t('h_hijri', {'d': h[2], 'y': h[0]})
        : s.t('h_hijri_other', {'d': h[2], 'm': h[1], 'y': h[0]});
    return Panel(
      color: AppColors.green,
      border: AppColors.green,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(hijriText, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15)),
        if (_outside)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(s.t('h_outside'), style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        const SizedBox(height: 10),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (var d = 8; d <= 13; d++)
            ChoiceChip(
              label: Text(s.t('h_day_$d')),
              selected: _day == d,
              selectedColor: AppColors.gold,
              backgroundColor: Colors.white,
              labelStyle: TextStyle(
                  color: _day == d ? AppColors.green : AppColors.text, fontWeight: FontWeight.w700, fontSize: 12.5),
              onSelected: (_) {
                setState(() => _day = d);
                _load();
              },
            ),
        ]),
      ]),
    );
  }

  // ------------------------------------------------------------ أنت بخير؟
  Widget _wellnessCard(S s) {
    final w = _map(_data!['wellness']);
    return Panel(
      border: AppColors.danger,
      color: AppColors.danger.withValues(alpha: 0.06),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(s.t('h_wellness_q'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.danger)),
        const SizedBox(height: 4),
        Text(s.t('h_wellness_body', {'n': w['still_minutes']}), style: const TextStyle(height: 1.6)),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(
            child: ElevatedButton(
              onPressed: () => _answerWellness(w['check_id'] as int, true),
              child: Text(s.t('h_im_ok')),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, side: const BorderSide(color: AppColors.danger)),
              onPressed: () => _answerWellness(w['check_id'] as int, false),
              child: Text(s.t('h_need_help')),
            ),
          ),
        ]),
      ]),
    );
  }

  Future<void> _answerWellness(int checkId, bool ok) async {
    final s = S.of(context);
    final r = await _run('well', () async {
      await Api.call('app_wellness_answer', {'p_check_id': checkId, 'p_ok': ok});
      return true;
    });
    if (r == true && mounted) {
      showSnack(context, s.t(ok ? 'h_ok_thanks' : 'h_help_sent'), color: ok ? AppColors.success : AppColors.warning);
      _session.wellness.value = null;
      _load();
    }
  }

  Future<void> _demoWellness() async {
    final s = S.of(context);
    final session = _session;
    final r = await _run('demo_well', () => Api.call('app_wellness_report',
        {'p_still_minutes': 30, 'p_lat': session.myLat, 'p_lng': session.myLng}));
    if (r == null || !mounted) return;
    final m = _map(r);
    if (m['ask'] == true) {
      m['still_minutes'] = 30;
      session.wellness.value = m;
    } else {
      showSnack(context, s.t(m['status'] == 'ALREADY_ASKED' ? 'h_already_asked' : 'h_suppressed'));
    }
  }

  // ------------------------------------------------------------ المواقيت والقبلة
  Widget _prayerCard(S s) {
    final session = context.watch<SessionProvider>();
    final times = HajjTime.prayerTimes(HajjTime.meccaNow());
    final next = HajjTime.nextPrayer();
    final left = next.value.difference(DateTime.now().toUtc());
    final leftText = left.inHours > 0 ? '${left.inHours}:${(left.inMinutes % 60).toString().padLeft(2, '0')}' : s.t('h_min_left', {'n': left.inMinutes});
    // GPS الجوال، وإن لم يتوفر (متصفح بدون إذن الموقع) فآخر موقع معروف لدى الخادم
    final meLoc = session.proximity?['me'] == null ? null : Map<String, dynamic>.from(session.proximity!['me'] as Map);
    final lat = session.myLat ?? (meLoc?['lat'] as num?)?.toDouble();
    final lng = session.myLng ?? (meLoc?['lng'] as num?)?.toDouble();
    final qibla = (lat != null && lng != null) ? HajjTime.qibla(lat, lng) : null;
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.mosque_rounded, color: AppColors.gold, size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(s.t('h_prayers'), style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 6),
        Text(s.t('h_next_prayer', {'p': s.t('h_${next.key}'), 't': leftText}),
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900, color: AppColors.green)),
        const SizedBox(height: 10),
        Row(children: [
          for (final k in HajjTime.prayers)
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 2),
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  color: k == next.key ? AppColors.gold.withValues(alpha: 0.18) : AppColors.surfaceAlt,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(children: [
                  Text(s.t('h_$k'), style: const TextStyle(fontSize: 10.5, color: AppColors.textMuted, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(HajjTime.clock(times[k]!), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w800)),
                ]),
              ),
            ),
        ]),
        const SizedBox(height: 4),
        Text(s.t('h_approx'), style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
        const Divider(height: 22),
        Row(children: [
          CompassArrow(bearing: qibla, size: 64, color: AppColors.gold),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.t('h_qibla'), style: const TextStyle(fontWeight: FontWeight.w800)),
              Text(qibla == null ? s.t('h_qibla_need') : s.t('h_qibla_deg', {'d': qibla}),
                  style: const TextStyle(color: AppColors.textMuted)),
            ]),
          ),
        ]),
      ]),
    );
  }

  // ------------------------------------------------------------ دليل اليوم
  Widget _guideCard(S s) {
    final g = _data?['guide'] == null ? null : _map(_data!['guide']);
    final steps = g == null ? <dynamic>[] : (g['steps'] as List? ?? <dynamic>[]);
    final rtl = g != null && S.isRtl('${g['lang']}');
    return Panel(
      border: AppColors.gold.withValues(alpha: 0.6),
      child: g == null
          ? Text(s.t('h_no_guide'), style: const TextStyle(color: AppColors.textMuted))
          : Directionality(
              textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(s.t('h_guide'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.w700)),
                Text('${g['title']}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.green)),
                const SizedBox(height: 8),
                for (var i = 0; i < steps.length; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      CircleAvatar(
                        radius: 11,
                        backgroundColor: AppColors.gold,
                        child: Text('${i + 1}', style: const TextStyle(fontSize: 11, color: AppColors.green, fontWeight: FontWeight.w900)),
                      ),
                      const SizedBox(width: 8),
                      Expanded(child: Text('${steps[i]}', style: const TextStyle(height: 1.6))),
                    ]),
                  ),
                if ((g['dua'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(s.t('h_dua'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.w700)),
                  Text('${g['dua']}', style: const TextStyle(fontSize: 16, color: AppColors.green, height: 1.7, fontWeight: FontWeight.w700)),
                ],
                if ((g['tip'] ?? '').toString().isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Panel(
                    color: AppColors.surfaceAlt,
                    padding: const EdgeInsets.all(10),
                    child: Text('${s.t('h_tip')}: ${g['tip']}', style: const TextStyle(color: AppColors.textMuted, height: 1.6)),
                  ),
                ],
              ]),
            ),
    );
  }

  // ------------------------------------------------------------ العدّادات
  List<String> get _kinds {
    final k = <String>['TAWAF', 'SAI'];
    if (_day == 10) k.add('JAMRAH_AQABA');
    if (_day >= 11 && _day <= 13) k.addAll(['JAMRAH_SUGHRA', 'JAMRAH_WUSTA', 'JAMRAH_AQABA']);
    return k;
  }

  Widget _countersCard(S s) {
    final counters = _map(_data?['counters']);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(s.t('h_counters'), style: const TextStyle(fontWeight: FontWeight.w800)),
        Text(s.t('h_counters_sub'), style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
        const SizedBox(height: 8),
        for (final kind in _kinds) _counterRow(s, kind, ((counters[kind] as num?) ?? 0).toInt()),
      ]),
    );
  }

  Widget _counterRow(S s, String kind, int count) {
    final busy = _busy.contains('c_$kind');
    final done = count >= 7;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: done ? AppColors.success.withValues(alpha: 0.08) : AppColors.surfaceAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: done ? AppColors.success.withValues(alpha: 0.4) : AppColors.line),
      ),
      child: Row(children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(s.t('h_$kind'), style: const TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 6),
            Row(children: [
              for (var i = 0; i < 7; i++)
                Container(
                  width: 14,
                  height: 14,
                  margin: const EdgeInsetsDirectional.only(end: 4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: i < count ? (done ? AppColors.success : AppColors.gold) : Colors.white,
                    border: Border.all(color: i < count ? Colors.transparent : AppColors.line, width: 1.5),
                  ),
                ),
            ]),
          ]),
        ),
        IconButton(
          onPressed: busy || count == 0 ? null : () => _step(kind, -1),
          icon: const Icon(Icons.remove_circle_outline_rounded),
          color: AppColors.textMuted,
        ),
        Text('$count/7', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
        IconButton.filled(
          onPressed: busy || done ? null : () => _step(kind, 1),
          icon: const Icon(Icons.add_rounded),
        ),
      ]),
    );
  }

  Future<void> _step(String kind, int delta) async {
    final s = S.of(context);
    final r = await _run('c_$kind', () => Api.call('app_counter_step', {'p_kind': kind, 'p_day': _day, 'p_delta': delta}));
    if (r == null || !mounted) return;
    final m = _map(r);
    setState(() {
      final c = _map(_data?['counters']);
      c[kind] = m['count'];
      _data?['counters'] = c;
    });
    if (m['complete'] == true && delta > 0) {
      showSnack(context, s.t('h_counter_done', {'name': s.t('h_$kind')}), color: AppColors.success);
    }
  }

  // ------------------------------------------------------------ الأدوية
  Widget _medsCard(S s) {
    final doses = _list(_data?['doses']);
    final meds = _list(_data?['medications']);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.medication_rounded, color: AppColors.green, size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(s.t('h_meds'), style: const TextStyle(fontWeight: FontWeight.w800))),
          TextButton.icon(onPressed: _addMedication, icon: const Icon(Icons.add_rounded, size: 18), label: Text(s.t('h_add_med'))),
        ]),
        Text(s.t('h_meds_sub'), style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
        const SizedBox(height: 8),
        if (doses.isEmpty) Text(s.t('h_no_doses'), style: const TextStyle(color: AppColors.textMuted)),
        for (final d in doses) _doseRow(s, d),
        if (meds.isNotEmpty) ...[
          const Divider(height: 20),
          Text(s.t('h_my_meds'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.w700)),
          for (final m in meds)
            Row(children: [
              Expanded(
                child: Text(
                  '${m['name']}${m['condition'] != null ? ' · ${m['condition']}' : ''} — '
                  '${(m['times'] as List? ?? <dynamic>[]).isEmpty ? s.t('h_as_needed') : (m['times'] as List).join('، ')}'
                  '${m['needs_fridge'] == true ? ' · ❄' : ''}',
                  style: const TextStyle(fontSize: 13),
                ),
              ),
              IconButton(
                tooltip: s.t('h_stop_med'),
                onPressed: () => _stopMedication(m['id'] as int),
                icon: const Icon(Icons.close_rounded, size: 18, color: AppColors.textFaint),
              ),
            ]),
        ],
      ]),
    );
  }

  Widget _doseRow(S s, Map<String, dynamic> d) {
    final status = '${d['status']}';
    final color = status == 'TAKEN'
        ? AppColors.success
        : status == 'MISSED'
            ? AppColors.danger
            : AppColors.textMuted;
    final id = d['dose_id'] as int;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(children: [
        Text(HajjTime.clock(DateTime.parse(d['scheduled_at'] as String)),
            style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
        const SizedBox(width: 10),
        Expanded(
          child: Text('${d['name']}${d['needs_fridge'] == true ? ' ❄' : ''}', style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
        if (status == 'TAKEN' || status == 'SKIPPED')
          Text(s.t('h_dose_$status'), style: TextStyle(color: color, fontWeight: FontWeight.w800, fontSize: 12))
        else
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 34),
              backgroundColor: status == 'MISSED' ? AppColors.danger : null,
            ),
            onPressed: _busy.contains('d_$id') ? null : () => _takeDose(id),
            child: Text(s.t('h_took_it')),
          ),
      ]),
    );
  }

  Future<void> _takeDose(int id) async {
    final s = S.of(context);
    final r = await _run('d_$id', () async {
      await Api.call('app_take_dose', {'p_dose_id': id});
      return true;
    });
    if (r == true && mounted) {
      showSnack(context, s.t('h_dose_saved'), color: AppColors.success);
      _load();
    }
  }

  Future<void> _addMedication() async {
    final s = S.of(context);
    final name = TextEditingController();
    final cond = TextEditingController();
    final times = TextEditingController();
    var fridge = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(s.t('h_add_med')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: name, decoration: InputDecoration(labelText: s.t('h_med_name'))),
              const SizedBox(height: 8),
              TextField(controller: cond, decoration: InputDecoration(labelText: s.t('h_med_condition'))),
              const SizedBox(height: 8),
              TextField(
                controller: times,
                keyboardType: TextInputType.datetime,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(labelText: s.t('h_med_times'), helperText: s.t('h_med_times_hint')),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.t('h_fridge')),
                value: fridge,
                onChanged: (v) => setD(() => fridge = v),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('save'))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    final list = times.text
        .replaceAll('،', ',')
        .split(RegExp(r'[,\s]+'))
        .map((t) => t.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    final r = await _run('addmed', () => Api.call('app_add_medication', {
          'p_name': name.text.trim(),
          'p_condition': cond.text.trim().isEmpty ? null : cond.text.trim(),
          'p_times': list,
          'p_needs_fridge': fridge,
        }));
    if (r != null && mounted) {
      showSnack(context, s.t('h_med_added'), color: AppColors.success);
      _load();
    }
  }

  Future<void> _stopMedication(int id) async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('h_stop_med')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('h_stop_med'))),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final r = await _run('stop_$id', () async {
      await Api.call('app_stop_medication', {'p_medication_id': id});
      return true;
    });
    if (r == true && mounted) {
      showSnack(context, s.t('h_med_stopped'));
      _load();
    }
  }

  // ------------------------------------------------------------ رسائل المشرف
  Widget _voiceCard(S s) {
    final items = _list(_data?['voice']);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.record_voice_over_rounded, color: AppColors.green, size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(s.t('h_voice'), style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 8),
        if (items.isEmpty) Text(s.t('h_no_voice'), style: const TextStyle(color: AppColors.textMuted)),
        for (final v in items)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: AppColors.surfaceAlt,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: v['is_urgent'] == true ? AppColors.danger.withValues(alpha: 0.5) : AppColors.line),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(
                  child: Text('${v['sender']}', style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 13)),
                ),
                if (v['is_urgent'] == true)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(end: 6),
                    child: Text(s.t('urgent'), style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w800, fontSize: 11)),
                  ),
                Text(timeAgo(s, v['created_at'] as String?), style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
              ]),
              const SizedBox(height: 6),
              Directionality(
                textDirection: S.isRtl('${v['lang']}') ? TextDirection.rtl : TextDirection.ltr,
                child: SizedBox(
                  width: double.infinity,
                  child: Text('${v['text']}', style: const TextStyle(fontSize: 15, height: 1.7)),
                ),
              ),
              if ('${v['lang']}' == 'ar' && s.lang != 'ar')
                Text(s.t('h_in_arabic'), style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: v['heard'] == true
                    ? Text(s.t('h_read'), style: const TextStyle(color: AppColors.success, fontWeight: FontWeight.w800, fontSize: 12))
                    : OutlinedButton(
                        onPressed: _busy.contains('v_${v['id']}') ? null : () => _markHeard(v['id'] as int),
                        child: Text(s.t('h_mark_read')),
                      ),
              ),
            ]),
          ),
      ]),
    );
  }

  Future<void> _markHeard(int id) async {
    final r = await _run('v_$id', () => Api.call('app_voice_heard', {'p_voice_id': id}));
    if (r != null && mounted) {
      setState(() {
        final items = _list(_data?['voice']);
        for (final v in items) {
          if (v['id'] == id) v['heard'] = true;
        }
        _data?['voice'] = items;
      });
    }
  }

  // ------------------------------------------------------------ التجهيز
  Widget _prepCard(S s) {
    final tasks = _list(_data?['prep']);
    final done = tasks.where((t) => t['done'] == true).length;
    return Panel(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.checklist_rounded, color: AppColors.green, size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(s.t('h_prep'), style: const TextStyle(fontWeight: FontWeight.w800))),
          Text(s.t('h_prep_progress', {'a': done, 'b': tasks.length}),
              style: TextStyle(color: done == tasks.length ? AppColors.success : AppColors.warning, fontWeight: FontWeight.w800, fontSize: 12)),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: tasks.isEmpty ? 0 : done / tasks.length,
            minHeight: 6,
            backgroundColor: AppColors.surfaceAlt,
            color: AppColors.success,
          ),
        ),
        for (final t in tasks)
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: t['done'] == true,
            title: Text('${t['name']}'),
            onChanged: _busy.contains('p_${t['id']}') ? null : (v) => _togglePrep(t['id'] as int, v ?? false),
          ),
      ]),
    );
  }

  Future<void> _togglePrep(int id, bool done) async {
    final r = await _run('p_$id', () async {
      await Api.call('app_prep_toggle', {'p_task_id': id, 'p_done': done});
      return true;
    });
    if (r == true && mounted) {
      setState(() {
        final tasks = _list(_data?['prep']);
        for (final t in tasks) {
          if (t['id'] == id) t['done'] = done;
        }
        _data?['prep'] = tasks;
      });
    }
  }

  // ------------------------------------------------------------ المفقودات
  static const _categories = ['PASSPORT', 'PHONE', 'GLASSES', 'BAG', 'MONEY', 'OTHER'];

  Widget _lostCard(S s) {
    final items = _list(_data?['lost']);
    return Panel(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.travel_explore_rounded, color: AppColors.green, size: 20),
          const SizedBox(width: 6),
          Expanded(child: Text(s.t('h_lost'), style: const TextStyle(fontWeight: FontWeight.w800))),
        ]),
        const SizedBox(height: 8),
        if (items.isEmpty) Text(s.t('h_no_lost'), style: const TextStyle(color: AppColors.textMuted)),
        for (final l in items)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(
                l['status'] == 'RETURNED'
                    ? Icons.check_circle_rounded
                    : l['status'] == 'FOUND'
                        ? Icons.notification_important_rounded
                        : Icons.search_rounded,
                color: l['status'] == 'OPEN' ? AppColors.warning : AppColors.success,
                size: 20,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${s.t('h_cat_${l['category']}')} · ${l['description']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(s.t('h_lost_${l['status']}', {'name': l['finder'] ?? ''}),
                      style: TextStyle(fontSize: 12, color: l['status'] == 'OPEN' ? AppColors.warning : AppColors.success, fontWeight: FontWeight.w700)),
                ]),
              ),
              Text(timeAgo(s, l['created_at'] as String?), style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
            ]),
          ),
        const SizedBox(height: 4),
        OutlinedButton.icon(onPressed: _reportLost, icon: const Icon(Icons.add_rounded), label: Text(s.t('h_report_lost'))),
      ]),
    );
  }

  Future<void> _reportLost() async {
    final s = S.of(context);
    final desc = TextEditingController();
    final place = TextEditingController();
    var cat = 'OTHER';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: Text(s.t('h_report_lost')),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              DropdownButtonFormField<String>(
                initialValue: cat,
                decoration: InputDecoration(labelText: s.t('h_category')),
                items: [for (final c in _categories) DropdownMenuItem(value: c, child: Text(s.t('h_cat_$c')))],
                onChanged: (v) => setD(() => cat = v ?? 'OTHER'),
              ),
              const SizedBox(height: 8),
              TextField(controller: desc, decoration: InputDecoration(labelText: s.t('h_lost_desc'))),
              const SizedBox(height: 8),
              TextField(controller: place, decoration: InputDecoration(labelText: s.t('h_lost_place'))),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('send'))),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    if (desc.text.trim().isEmpty) {
      showSnack(context, s.t('h_lost_desc'), color: AppColors.danger);
      return;
    }
    final r = await _run('lost', () => Api.call('app_report_lost', {
          'p_category': cat,
          'p_description': desc.text.trim(),
          'p_place': place.text.trim().isEmpty ? null : place.text.trim(),
        }));
    if (r != null && mounted) {
      showSnack(context, s.t(cat == 'PASSPORT' ? 'h_lost_passport' : 'h_lost_sent'), color: AppColors.success);
      _load();
    }
  }
}

/// نافذة «أنت بخير؟» تظهر فوق أي شاشة عندما يرصد الجوال توقف الحركة خارج المخيم
Future<void> showWellnessDialog(BuildContext context, Map<String, dynamic> check) async {
  final s = S.of(context);
  final session = context.read<SessionProvider>();
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      title: Text(s.t('h_wellness_q'), style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w900)),
      content: Text(s.t('h_wellness_body', {'n': check['still_minutes'] ?? 25}), style: const TextStyle(height: 1.6)),
      actions: [
        TextButton(
          style: TextButton.styleFrom(foregroundColor: AppColors.danger),
          onPressed: () => Navigator.pop(ctx, false),
          child: Text(s.t('h_need_help')),
        ),
        ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('h_im_ok'))),
      ],
    ),
  );
  if (ok == null) return;
  try {
    await Api.call('app_wellness_answer', {'p_check_id': check['check_id'], 'p_ok': ok});
    session.wellness.value = null;
    if (context.mounted) {
      showSnack(context, s.t(ok ? 'h_ok_thanks' : 'h_help_sent'), color: ok ? AppColors.success : AppColors.warning);
    }
  } on ApiException catch (e) {
    if (context.mounted) showSnack(context, e.network ? s.t('network_error') : e.message, color: AppColors.danger);
  }
}

/// بطاقة الدخول إلى «حجّي» في الرئيسية: اليوم والصلاة القادمة
class HajjEntryCard extends StatelessWidget {
  const HajjEntryCard({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final next = HajjTime.nextPrayer();
    final day = HajjTime.hajjDayToday();
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const HajjScreen())),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          gradient: const LinearGradient(colors: [AppColors.gold, AppColors.goldDark]),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(children: [
          const Icon(Icons.auto_stories_rounded, color: Colors.white, size: 30),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(day == null ? s.t('h_title') : '${s.t('h_title')} · ${s.t('h_day_$day')}',
                  style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w900)),
              Text(s.t('h_card_sub'), style: const TextStyle(color: Colors.white, fontSize: 12, height: 1.5)),
              const SizedBox(height: 2),
              Text('${s.t('h_${next.key}')} ${HajjTime.clock(next.value)}',
                  style: const TextStyle(color: Colors.white, fontSize: 12.5, fontWeight: FontWeight.w800)),
            ]),
          ),
          const Icon(Icons.chevron_left_rounded, color: Colors.white),
        ]),
      ),
    );
  }
}
