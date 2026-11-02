import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../services/api.dart';
import '../../services/circle_store.dart';
import '../../services/geo.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// v4.5 «عائلتي ورفقتي»: الحاج ينشئ دائرة لعائلته أو أصدقائه ويعطيهم رمزها، وكل فرد ينضم بنفسه من جواله.
/// يرى كل فرد مسافة الباقين واتجاههم (تُحسب على الجوال من آخر موقع معروف، فتعمل بدون إنترنت)،
/// والخادم ينبّه الدائرة والمشرف إذا ابتعد أحدهم أو ضغط SOS.

/// المسافة والاتجاه من موقعي الحالي إلى الفرد (محلياً إن توفر GPS، وإلا من الخادم)
({int? distance, int? bearing}) circleDistance(SessionProvider session, Map<String, dynamic> m) {
  final lat = asDouble(m['lat']), lng = asDouble(m['lng']);
  if (session.myLat != null && session.myLng != null && lat != null && lng != null) {
    return (
      distance: Geo.distanceM(session.myLat!, session.myLng!, lat, lng),
      bearing: Geo.bearing(session.myLat!, session.myLng!, lat, lng),
    );
  }
  return (distance: (m['distance_m'] as num?)?.toInt(), bearing: (m['bearing'] as num?)?.toInt());
}

String circleError(S s, ApiException e) {
  if (e.network) return s.t('network_error');
  final key = 'circle_err_${e.code}';
  final t = s.t(key);
  return t == key ? e.message : t;
}

class CircleScreen extends StatefulWidget {
  const CircleScreen({super.key});

  @override
  State<CircleScreen> createState() => _CircleScreenState();
}

class _CircleScreenState extends State<CircleScreen> {
  bool _busy = false;
  bool _offline = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    CircleStore.loadCached();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    try {
      final ok = await CircleStore.refresh();
      if (mounted) setState(() => _offline = !ok);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, circleError(S.of(context), e), color: AppColors.danger);
    }
  }

  Future<void> _run(Future<dynamic> Function() action) async {
    final s = S.of(context);
    setState(() => _busy = true);
    try {
      final r = await action();
      await CircleStore.set(r);
    } on ApiException catch (e) {
      if (mounted) showSnack(context, circleError(s, e), color: AppColors.danger);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<String?> _ask(String title, String hint, {bool code = false}) {
    final s = S.of(context);
    final ctrl = TextEditingController();
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          TextField(
            controller: ctrl,
            autofocus: true,
            textAlign: code ? TextAlign.center : TextAlign.start,
            textCapitalization: code ? TextCapitalization.characters : TextCapitalization.sentences,
            maxLength: code ? 6 : 60,
            style: code ? const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 6) : null,
            decoration: InputDecoration(hintText: hint, counterText: ''),
          ),
          const SizedBox(height: 14),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: Text(code ? s.t('circle_join') : s.t('circle_create'))),
        ]),
      ),
    );
  }

  Future<void> _create() async {
    final s = S.of(context);
    final name = await _ask(s.t('circle_create'), s.t('circle_name'));
    if (name == null || name.isEmpty) return;
    await _run(() => Api.call('app_circle_create', {'p_name': name}));
  }

  Future<void> _join() async {
    final s = S.of(context);
    final code = await _ask(s.t('circle_join'), s.t('circle_enter_code'), code: true);
    if (code == null || code.isEmpty) return;
    await _run(() => Api.call('app_circle_join', {'p_code': code}));
  }

  Future<bool> _confirm(String msg, String action) async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        content: Text(msg),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action, style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _leave(Map<String, dynamic> c) async {
    final s = S.of(context);
    if (!await _confirm(s.t('circle_leave_q', {'name': c['name']}), s.t('circle_leave'))) return;
    await _run(() => Api.call('app_circle_leave'));
  }

  Future<void> _remove(Map<String, dynamic> m) async {
    final s = S.of(context);
    if (!await _confirm(s.t('circle_remove_q', {'name': m['name']}), s.t('circle_remove'))) return;
    await _run(() => Api.call('app_circle_remove', {'p_pilgrim_id': m['pilgrim_id']}));
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(s.t('circle_title'))),
      body: ValueListenableBuilder<Map<String, dynamic>?>(
        valueListenable: CircleStore.data,
        builder: (context, _, __) {
          final c = CircleStore.circle;
          return RefreshIndicator(
            onRefresh: _refresh,
            child: ListView(padding: const EdgeInsets.all(16), children: [
              if (_busy) const LinearProgressIndicator(minHeight: 3),
              if (_offline)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(s.t('circle_offline'), style: const TextStyle(fontSize: 12, color: AppColors.warning, fontWeight: FontWeight.w700)),
                ),
              if (c == null) ..._empty(s) else ..._circle(s, session, c),
            ]),
          );
        },
      ),
    );
  }

  List<Widget> _empty(S s) => [
        Panel(
          color: AppColors.surfaceAlt,
          child: Column(children: [
            const Icon(Icons.diversity_3_rounded, size: 56, color: AppColors.green),
            const SizedBox(height: 10),
            Text(s.t('circle_intro'), textAlign: TextAlign.center, style: const TextStyle(height: 1.7, color: AppColors.text)),
          ]),
        ),
        const SizedBox(height: 16),
        ElevatedButton.icon(onPressed: _busy ? null : _create, icon: const Icon(Icons.add_circle_outline_rounded), label: Text(s.t('circle_create'))),
        const SizedBox(height: 10),
        OutlinedButton.icon(onPressed: _busy ? null : _join, icon: const Icon(Icons.vpn_key_rounded), label: Text(s.t('circle_join'))),
        const SizedBox(height: 14),
        _privacy(s),
      ];

  List<Widget> _circle(S s, SessionProvider session, Map<String, dynamic> c) {
    final members = CircleStore.members;
    final limit = (c['max_distance_m'] as num?)?.toInt() ?? 200;
    final isOwner = c['is_owner'] == true;
    return [
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Icon(Icons.diversity_3_rounded, color: AppColors.green),
            const SizedBox(width: 10),
            Expanded(child: Text('${c['name']}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900))),
          ]),
          const SizedBox(height: 12),
          Text(s.t('circle_code'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
          Row(children: [
            Expanded(
              child: SelectableText('${c['join_code']}',
                  style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, letterSpacing: 6, color: AppColors.green)),
            ),
            IconButton.filledTonal(
              tooltip: s.t('circle_copied'),
              icon: const Icon(Icons.copy_rounded),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: '${c['join_code']}'));
                showSnack(context, s.t('circle_copied'));
              },
            ),
          ]),
          Text(s.t('circle_code_hint'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted, height: 1.5)),
          const SizedBox(height: 6),
          Text(s.t('circle_limit', {'n': fmtDistance(s, limit)}),
              style: const TextStyle(fontSize: 12, color: AppColors.textFaint)),
        ]),
      ),
      const SizedBox(height: 16),
      SectionTitle(s.t('circle_members', {'n': members.length})),
      for (final m in members)
        Padding(padding: const EdgeInsets.only(bottom: 10), child: _member(s, session, m, limit, isOwner)),
      const SizedBox(height: 8),
      _privacy(s),
      const SizedBox(height: 12),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, side: const BorderSide(color: AppColors.danger)),
        onPressed: _busy ? null : () => _leave(c),
        icon: const Icon(Icons.logout_rounded),
        label: Text(s.t('circle_leave')),
      ),
    ];
  }

  Widget _member(S s, SessionProvider session, Map<String, dynamic> m, int limit, bool isOwner) {
    final me = m['is_me'] == true;
    final ({int? distance, int? bearing}) d = me ? (distance: null, bearing: null) : circleDistance(session, m);
    final far = !me && d.distance != null && d.distance! > limit;
    final battery = (m['battery'] as num?)?.toInt();
    final phone = m['phone'] as String?;
    return Panel(
      border: far ? AppColors.danger : null,
      child: Row(children: [
        if (me)
          const CircleAvatar(radius: 26, backgroundColor: AppColors.gold, child: Icon(Icons.person_rounded, color: AppColors.green))
        else
          CompassArrow(bearing: d.bearing, size: 52, color: far ? AppColors.danger : AppColors.green),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text('${m['name']}', style: const TextStyle(fontWeight: FontWeight.w800))),
              if (me) ...[const SizedBox(width: 6), _tag(s.t('circle_me'), AppColors.goldDark)],
              if (m['is_owner'] == true) ...[const SizedBox(width: 6), _tag(s.t('circle_owner'), AppColors.textMuted)],
            ]),
            if ((m['group_name'] as String?) != null)
              Text('${m['group_name']}', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            if (!me)
              Text(
                m['lat'] == null
                    ? s.t('circle_no_location')
                    : '${fmtDistance(s, d.distance)}${far ? ' · ${s.t('circle_far')}' : ''} · ${timeAgo(s, m['at'] as String?)}'
                        '${battery != null ? ' · 🔋$battery٪' : ''}',
                style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: far ? AppColors.danger : AppColors.text),
              ),
          ]),
        ),
        if (!me && phone != null && phone.isNotEmpty)
          IconButton(icon: const Icon(Icons.call_rounded, color: AppColors.green), tooltip: s.t('call'), onPressed: () => callPhone(phone)),
        if (!me && m['lat'] != null)
          IconButton(icon: const Icon(Icons.directions_walk_rounded, color: AppColors.green), onPressed: () => launchMaps(m['lat'], m['lng'])),
        if (isOwner && !me)
          IconButton(
            icon: const Icon(Icons.person_remove_alt_1_rounded, color: AppColors.textFaint),
            tooltip: s.t('circle_remove'),
            onPressed: _busy ? null : () => _remove(m),
          ),
      ]),
    );
  }

  Widget _tag(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(border: Border.all(color: color), borderRadius: BorderRadius.circular(8)),
        child: Text(text, style: TextStyle(fontSize: 10.5, color: color, fontWeight: FontWeight.w800)),
      );

  Widget _privacy(S s) => Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Icon(Icons.lock_outline_rounded, size: 15, color: AppColors.textFaint),
        const SizedBox(width: 6),
        Expanded(child: Text(s.t('circle_privacy'), style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint))),
      ]);
}

/// بطاقة الرئيسية: ملخص الدائرة (عدد الأفراد وأبعدهم) أو دعوة لإنشائها
class CircleEntryCard extends StatefulWidget {
  const CircleEntryCard({super.key});

  @override
  State<CircleEntryCard> createState() => _CircleEntryCardState();
}

class _CircleEntryCardState extends State<CircleEntryCard> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    CircleStore.loadCached();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 60), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      await CircleStore.refresh();
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    return ValueListenableBuilder<Map<String, dynamic>?>(
      valueListenable: CircleStore.data,
      builder: (context, _, __) {
        final c = CircleStore.circle;
        String sub;
        Map<String, dynamic>? farthest;
        int? farD;
        var far = false;
        if (c == null) {
          sub = s.t('circle_card_empty');
        } else {
          final members = CircleStore.members;
          for (final m in members.where((x) => x['is_me'] != true)) {
            final d = circleDistance(session, m).distance;
            if (d != null && (farD == null || d > farD)) {
              farD = d;
              farthest = m;
            }
          }
          final limit = (c['max_distance_m'] as num?)?.toInt() ?? 200;
          far = farD != null && farD > limit;
          sub = far
              ? s.t('circle_card_far', {'name': farthest?['name']}) + ' · ${fmtDistance(s, farD)}'
              : s.t('circle_card_status', {'n': members.length, 'd': fmtDistance(s, farD)});
        }
        return InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CircleScreen())),
          child: Panel(
            border: far ? AppColors.danger : null,
            child: Row(children: [
              Icon(Icons.diversity_3_rounded, color: far ? AppColors.danger : AppColors.green, size: 30),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(c == null ? s.t('circle_title') : '${s.t('circle_title')} · ${c['name']}',
                      style: const TextStyle(fontWeight: FontWeight.w800)),
                  Text(sub, style: TextStyle(fontSize: 12.5, color: far ? AppColors.danger : AppColors.textMuted, fontWeight: far ? FontWeight.w800 : null)),
                ]),
              ),
              const Icon(Icons.chevron_left_rounded),
            ]),
          ),
        );
      },
    );
  }
}
