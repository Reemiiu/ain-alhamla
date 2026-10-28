import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// مجموعتي (المشرف): جاهزية التجمع الحالي + الحجاج مرتّبين بالأولوية (كبار السن والمرضى أولاً).
class GroupScreen extends StatelessWidget {
  final Map<String, dynamic>? board;
  final Future<void> Function() onRefresh;
  const GroupScreen({super.key, required this.board, required this.onRefresh});

  static List<Map<String, dynamic>> listOf(dynamic v) =>
      ((v as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (board == null) return const Center(child: CircularProgressIndicator());
    final groups = listOf(board!['groups']);
    final pilgrims = listOf(board!['pilgrims']);
    return RefreshIndicator(
      onRefresh: onRefresh,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        for (final g in groups) _ReadinessCard(group: g, pilgrims: pilgrims.where((p) => p['group_id'] == g['id']).toList()),
        const SizedBox(height: 8),
        SectionTitle('${s.t('tab_group')} · ${pilgrims.length}'),
        for (final p in pilgrims)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => showPilgrimSheet(context, p),
              child: Panel(
                border: (p['open_alerts'] as num? ?? 0) > 0 ? AppColors.danger.withValues(alpha: 0.4) : null,
                child: Row(children: [
                  CircleAvatar(
                    backgroundColor: p['priority_level'] == 'CRITICAL' ? AppColors.danger.withValues(alpha: 0.12) : AppColors.surfaceAlt,
                    child: Text('${p['full_name']}'.characters.first, style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.green)),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('${p['full_name']}', style: const TextStyle(fontWeight: FontWeight.w800)),
                      const SizedBox(height: 2),
                      Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                        PriorityChip(level: p['priority_level'] as String?, reason: p['priority_reason'] as String?),
                        if (p['preferred_language'] != 'ar')
                          Text('${S.names[p['preferred_language']] ?? ''}', style: const TextStyle(fontSize: 11, color: AppColors.green, fontWeight: FontWeight.w800)),
                        _batteryText(s, p['last_ping']),
                      ]),
                    ]),
                  ),
                  Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    StatusPill(status: p['current_status'] as String?),
                    if ((p['open_alerts'] as num? ?? 0) > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('${p['open_alerts']} ⚠', style: const TextStyle(color: AppColors.danger, fontWeight: FontWeight.w900, fontSize: 12)),
                      ),
                  ]),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  Widget _batteryText(S s, dynamic ping) {
    if (ping == null) return const SizedBox.shrink();
    final m = Map<String, dynamic>.from(ping as Map);
    final b = (m['battery'] as num?)?.toInt();
    final c = b == null ? AppColors.textFaint : b < 15 ? AppColors.danger : b < 35 ? AppColors.warning : AppColors.success;
    return Text('🔋${b ?? '—'}% · ${timeAgo(s, m['at'] as String?)}', style: TextStyle(fontSize: 11, color: c));
  }
}

class _ReadinessCard extends StatelessWidget {
  final Map<String, dynamic> group;
  final List<Map<String, dynamic>> pilgrims;
  const _ReadinessCard({required this.group, required this.pilgrims});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final g = group['gathering'] == null ? null : Map<String, dynamic>.from(group['gathering'] as Map);
    final total = pilgrims.length;
    final checked = (g?['checked'] as num?)?.toInt() ?? 0;
    final pct = total == 0 ? 0.0 : checked / total;
    final ready = g != null && checked >= total && total > 0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Panel(
        border: ready ? AppColors.success : AppColors.gold.withValues(alpha: 0.6),
        child: Row(children: [
          SizedBox(
            width: 74,
            height: 74,
            child: Stack(alignment: Alignment.center, children: [
              SizedBox.expand(
                child: CircularProgressIndicator(
                  value: g == null ? 0 : pct,
                  strokeWidth: 8,
                  backgroundColor: AppColors.surfaceAlt,
                  color: ready ? AppColors.success : AppColors.gold,
                ),
              ),
              Text(g == null ? '—' : '${(pct * 100).round()}%', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 16)),
            ]),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${s.t('readiness')} · ${group['name']}', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
              if (g == null)
                Text(s.t('no_open_gathering'), style: const TextStyle(fontWeight: FontWeight.w800))
              else ...[
                Text('${g['title']}', style: const TextStyle(fontWeight: FontWeight.w900)),
                Text('${g['location']} · ${clockOf(g['scheduled_at'] as String?)}', style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                Text(s.t('checked_of', {'a': checked, 'b': total}), style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700)),
                Text(ready ? s.t('ready_go') : s.t('waiting_rest'),
                    style: TextStyle(color: ready ? AppColors.success : AppColors.warning, fontWeight: FontWeight.w900)),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

/// ملف الحاج للمشرف (بيانات طبية وجهات طوارئ — من دالة تتحقق أنه من مجموعته)
Future<void> showPilgrimSheet(BuildContext context, Map<String, dynamic> p) async {
  final s = S.of(context);
  Map<String, dynamic>? prof;
  try {
    prof = Map<String, dynamic>.from(await Api.call('app_pilgrim_profile', {'p_pilgrim_id': p['id']}) as Map);
  } catch (_) {}
  if (!context.mounted) return;
  final contacts = GroupScreen.listOf(prof?['contacts']);
  await showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.white,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    builder: (ctx) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.65,
      builder: (ctx, controller) => ListView(controller: controller, padding: const EdgeInsets.all(20), children: [
        Text('${p['full_name']}', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
        Text('${prof?['age'] ?? '—'} · ${prof?['nationality'] ?? ''} · ${S.names[p['preferred_language']] ?? ''}',
            style: const TextStyle(color: AppColors.textMuted)),
        const SizedBox(height: 8),
        PriorityChip(level: p['priority_level'] as String?, reason: p['priority_reason'] as String?),
        const SizedBox(height: 12),
        Panel(
          color: AppColors.surfaceAlt,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${s.t('blood_type')}: ${prof?['blood_type'] ?? '—'}', style: const TextStyle(fontWeight: FontWeight.w800)),
            Text('${s.t('medical')}: ${(prof?['medical_notes'] as String?) ?? s.t('none')}'),
          ]),
        ),
        const SizedBox(height: 12),
        ElevatedButton.icon(onPressed: () => callPhone(p['phone'] as String?), icon: const Icon(Icons.call_rounded), label: Text('${s.t('call')} · ${p['phone']}')),
        const SizedBox(height: 12),
        Text(s.t('emergency_contacts'), style: const TextStyle(fontWeight: FontWeight.w900)),
        for (final c in contacts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('${c['name']} (${c['relation'] ?? ''})'),
            subtitle: Text('${c['phone']}'),
            trailing: IconButton(icon: const Icon(Icons.call_rounded, color: AppColors.green), onPressed: () => callPhone(c['phone'] as String?)),
          ),
      ]),
    ),
  );
}
