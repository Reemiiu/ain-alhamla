import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// جدولي: المناسك (مع تقييم كل منسك بعد انتهائه)، تجمعات مجموعتي، والحافلات.
class ScheduleScreen extends StatefulWidget {
  const ScheduleScreen({super.key});

  @override
  State<ScheduleScreen> createState() => _ScheduleScreenState();
}

class _ScheduleScreenState extends State<ScheduleScreen> {
  Map<String, dynamic>? _data;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await Api.call('app_today');
      if (mounted) setState(() { _data = Map<String, dynamic>.from(r as Map); _error = null; });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.network ? 'network_error' : e.message);
    }
  }

  List<Map<String, dynamic>> _list(String k) =>
      ((_data?[k] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  Future<void> _rate(Map<String, dynamic> r) async {
    final s = S.of(context);
    var stars = 5;
    final comment = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text('${s.t('rate_ritual')}: ${r['name']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
            const SizedBox(height: 12),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              for (var i = 1; i <= 5; i++)
                IconButton(
                  iconSize: 38,
                  onPressed: () => setSt(() => stars = i),
                  icon: Icon(i <= stars ? Icons.star_rounded : Icons.star_outline_rounded, color: AppColors.gold),
                ),
            ]),
            TextField(controller: comment, maxLines: 3, decoration: InputDecoration(hintText: s.t('comment_optional'))),
            const SizedBox(height: 14),
            ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('send'))),
          ]),
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await Api.call('app_rate_ritual', {'p_ritual_id': r['id'], 'p_rating': stars, 'p_body': comment.text});
      if (mounted) showSnack(context, s.t('rate_thanks'));
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.network ? s.t('network_error') : e.message, color: AppColors.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (_data == null) {
      return Center(
        child: _error == null
            ? const CircularProgressIndicator()
            : Column(mainAxisSize: MainAxisSize.min, children: [
                Text(s.t(_error!)),
                TextButton(onPressed: _load, child: Text(s.t('retry'))),
              ]),
      );
    }
    final rituals = _list('rituals'), gatherings = _list('gatherings'), trips = _list('trips');
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        SectionTitle(s.t('rituals')),
        for (final r in rituals) _ritualTile(s, r),
        const SizedBox(height: 16),
        SectionTitle(s.t('today_gatherings')),
        if (gatherings.isEmpty) Text(s.t('no_gathering'), style: const TextStyle(color: AppColors.textFaint)),
        for (final g in gatherings)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Panel(
              child: Row(children: [
                Column(children: [
                  Text(clockOf(g['scheduled_at'] as String?), style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16, color: AppColors.green)),
                  Text('+${g['deadline_minutes']}′', style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
                ]),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${g['title']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text('${g['location']}', style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
                  ]),
                ),
                StatusPill(status: g['my_status'] as String?),
              ]),
            ),
          ),
        if (trips.isNotEmpty) ...[
          const SizedBox(height: 16),
          SectionTitle(s.t('trips')),
          for (final t in trips)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Panel(
                child: Row(children: [
                  const Icon(Icons.directions_bus_rounded, color: AppColors.gold),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${t['vehicle_no']} · ${t['from'] ?? ''} ← ${t['to'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      Text('${clockOf(t['departure_time'] as String?)} · ${t['driver_name']}', style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
                    ]),
                  ),
                ]),
              ),
            ),
        ],
      ]),
    );
  }

  Widget _ritualTile(S s, Map<String, dynamic> r) {
    final st = r['status'] as String;
    final color = st == 'COMPLETED' ? AppColors.success : st == 'IN_PROGRESS' ? AppColors.gold : AppColors.line;
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SizedBox(
          width: 26,
          child: Column(children: [
            Container(width: 16, height: 16, margin: const EdgeInsets.only(top: 14),
                decoration: BoxDecoration(shape: BoxShape.circle, color: st == 'UPCOMING' ? Colors.white : color, border: Border.all(color: color, width: 3))),
            Expanded(child: Container(width: 3, color: AppColors.line)),
          ]),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Panel(
              border: st == 'IN_PROGRESS' ? AppColors.gold : null,
              child: Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${r['name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                    Text('${s.t('hajj_day', {'d': r['hajj_day']})} · ${r['location'] ?? ''}',
                        style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
                    Text(s.t(st == 'COMPLETED' ? 'done' : st == 'IN_PROGRESS' ? 'in_progress' : 'upcoming'),
                        style: TextStyle(color: st == 'UPCOMING' ? AppColors.textFaint : color, fontSize: 12, fontWeight: FontWeight.w800)),
                  ]),
                ),
                if (st != 'UPCOMING')
                  TextButton.icon(
                    onPressed: () => _rate(r),
                    icon: const Icon(Icons.star_rounded, color: AppColors.gold),
                    label: Text(s.t('rate_ritual')),
                  ),
              ]),
            ),
          ),
        ),
      ]),
    );
  }
}
