import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import 'group_screen.dart';

/// تنبيهات مجموعتي (المشرف): مرتبة بالنوع ثم الخطورة ثم أولوية الحاج، مع بدء الاستجابة والإغلاق والاتجاه للموقع.
class StaffAlertsScreen extends StatefulWidget {
  final Future<void> Function() onChanged;
  const StaffAlertsScreen({super.key, required this.onChanged});

  @override
  State<StaffAlertsScreen> createState() => _StaffAlertsScreenState();
}

class _StaffAlertsScreenState extends State<StaffAlertsScreen> {
  List<Map<String, dynamic>> _alerts = [];
  bool _loading = true;

  static const _type = {'SOS': 4, 'LOST': 3, 'GEOFENCE_BREACH': 2, 'ABSENCE': 1};
  static const _sev = {'CRITICAL': 3, 'MEDIUM': 2, 'LOW': 1};
  static const _prio = {'CRITICAL': 3, 'HIGH': 2, 'NORMAL': 1};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final session = context.read<SessionProvider>();
    final ids = session.staffGroups.map((g) => g['id']).toSet();
    try {
      final rows = GroupScreen.listOf(await Supabase.instance.client
          .from('alerts')
          .select('id, type, severity, status, created_at, note, latitude, longitude, pilgrim_id, '
              'pilgrims(id, group_id, priority_level, priority_reason, users(full_name, phone))')
          .neq('status', 'RESOLVED')
          .order('created_at', ascending: false)
          .limit(100));
      final mine = rows.where((a) => ids.contains((a['pilgrims'] as Map?)?['group_id'])).toList()
        ..sort((a, b) {
          int r(Map m, String k, Map<String, int> t) => t[m[k]] ?? 0;
          final pa = Map<String, dynamic>.from((a['pilgrims'] as Map?) ?? {});
          final pb = Map<String, dynamic>.from((b['pilgrims'] as Map?) ?? {});
          return [
            r(b, 'type', _type) - r(a, 'type', _type),
            r(b, 'severity', _sev) - r(a, 'severity', _sev),
            r(pb, 'priority_level', _prio) - r(pa, 'priority_level', _prio),
          ].firstWhere((x) => x != 0, orElse: () => 0);
        });
      if (mounted) setState(() { _alerts = mine; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _update(Map<String, dynamic> a, String status) async {
    try {
      await Api.call('app_update_alert', {'p_alert_id': a['id'], 'p_status': status, 'p_note': null});
      await _load();
      await widget.onChanged();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, color: AppColors.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return RefreshIndicator(
      onRefresh: _load,
      child: _loading
          ? ListView(children: const [Padding(padding: EdgeInsets.all(60), child: Center(child: CircularProgressIndicator()))])
          : _alerts.isEmpty
              ? ListView(children: [Padding(padding: const EdgeInsets.all(60), child: Center(child: Text(s.t('all_good'))))])
              : ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: _alerts.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, i) {
                    final a = _alerts[i];
                    final p = Map<String, dynamic>.from((a['pilgrims'] as Map?) ?? {});
                    final u = Map<String, dynamic>.from((p['users'] as Map?) ?? {});
                    final urgent = a['type'] == 'SOS' || a['type'] == 'LOST';
                    final c = a['severity'] == 'CRITICAL' ? AppColors.danger : a['severity'] == 'MEDIUM' ? AppColors.warning : AppColors.success;
                    return Panel(
                      border: urgent ? AppColors.danger : null,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Row(children: [
                          Container(width: 10, height: 10, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text('${s.t(a['type'] as String)} — ${u['full_name'] ?? ''}',
                                style: TextStyle(fontWeight: FontWeight.w900, color: urgent ? AppColors.danger : AppColors.text)),
                          ),
                          Text(timeAgo(s, a['created_at'] as String?), style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
                        ]),
                        const SizedBox(height: 4),
                        Row(children: [
                          PriorityChip(level: p['priority_level'] as String?, reason: p['priority_reason'] as String?),
                          if (a['status'] == 'IN_PROGRESS') ...[
                            const SizedBox(width: 6),
                            Text(s.t('in_progress'), style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.w800, fontSize: 12)),
                          ],
                        ]),
                        if (a['note'] != null) Text('${a['note']}', style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
                        const SizedBox(height: 10),
                        Row(children: [
                          IconButton.filledTonal(onPressed: () => callPhone(u['phone'] as String?), icon: const Icon(Icons.call_rounded)),
                          if (a['latitude'] != null)
                            IconButton.filledTonal(
                              onPressed: () => launchMaps(a['latitude'], a['longitude']),
                              icon: const Icon(Icons.directions_rounded),
                            ),
                          const Spacer(),
                          if (a['status'] == 'OPEN')
                            TextButton(onPressed: () => _update(a, 'IN_PROGRESS'), child: Text(s.t('respond'))),
                          TextButton(onPressed: () => _update(a, 'RESOLVED'), child: Text(s.t('resolve'))),
                        ]),
                      ]),
                    );
                  },
                ),
    );
  }
}
