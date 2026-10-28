import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../l10n/strings.dart';
import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import 'group_screen.dart';

/// التجمعات (المشرف): فتح تجمع بموعد ومهلة، تسجيل الحضور يدوياً، إغلاق التجمع، إنهاء المنسك بتعليق → تقرير للإدارة.
class GatheringScreen extends StatelessWidget {
  final Map<String, dynamic>? board;
  final Future<void> Function() onChanged;
  const GatheringScreen({super.key, required this.board, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    if (board == null) return const Center(child: CircularProgressIndicator());
    final groups = GroupScreen.listOf(board!['groups']);
    final pilgrims = GroupScreen.listOf(board!['pilgrims']);
    return RefreshIndicator(
      onRefresh: onChanged,
      child: ListView(padding: const EdgeInsets.all(16), children: [
        ElevatedButton.icon(
          onPressed: () => _create(context, groups),
          icon: const Icon(Icons.add_location_alt_rounded),
          label: Text(s.t('new_gathering')),
        ),
        const SizedBox(height: 14),
        for (final grp in groups) ...[
          if (grp['gathering'] == null)
            Panel(child: Text('${grp['name']} · ${s.t('no_open_gathering')}', style: const TextStyle(color: AppColors.textMuted)))
          else
            _GatheringBlock(
              group: grp,
              gathering: Map<String, dynamic>.from(grp['gathering'] as Map),
              pilgrims: pilgrims.where((p) => p['group_id'] == grp['id']).toList(),
              onChanged: onChanged,
            ),
          const SizedBox(height: 12),
        ],
      ]),
    );
  }

  Future<void> _create(BuildContext context, List<Map<String, dynamic>> groups) async {
    final s = S.of(context);
    final client = Supabase.instance.client;
    List<Map<String, dynamic>> locs = [], rituals = [];
    try {
      locs = GroupScreen.listOf(await client.from('locations').select('id, name').order('id'));
      rituals = GroupScreen.listOf(await client.from('rituals').select('id, name, status').neq('status', 'COMPLETED').order('seq'));
    } catch (_) {
      if (context.mounted) showSnack(context, s.t('network_error'), color: AppColors.danger);
      return;
    }
    if (!context.mounted || groups.isEmpty || locs.isEmpty) return;
    final title = TextEditingController();
    final deadline = TextEditingController(text: '15');
    int groupId = groups.first['id'] as int;
    int locId = locs.first['id'] as int;
    int? ritualId = rituals.isEmpty ? null : rituals.first['id'] as int;
    var at = DateTime.now().add(const Duration(minutes: 30));
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setSt) => Padding(
          padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
          child: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(s.t('new_gathering'), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
              const SizedBox(height: 12),
              TextField(controller: title, decoration: InputDecoration(labelText: s.t('title'))),
              const SizedBox(height: 10),
              if (groups.length > 1)
                DropdownButtonFormField<int>(
                  initialValue: groupId,
                  decoration: InputDecoration(labelText: s.t('group')),
                  items: groups.map((g) => DropdownMenuItem(value: g['id'] as int, child: Text('${g['name']}'))).toList(),
                  onChanged: (v) => groupId = v ?? groupId,
                ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int>(
                initialValue: locId,
                decoration: InputDecoration(labelText: s.t('place')),
                items: locs.map((l) => DropdownMenuItem(value: l['id'] as int, child: Text('${l['name']}'))).toList(),
                onChanged: (v) => locId = v ?? locId,
              ),
              const SizedBox(height: 10),
              DropdownButtonFormField<int?>(
                initialValue: ritualId,
                decoration: InputDecoration(labelText: s.t('ritual')),
                items: [
                  const DropdownMenuItem<int?>(value: null, child: Text('—')),
                  ...rituals.map((r) => DropdownMenuItem<int?>(value: r['id'] as int, child: Text('${r['name']}'))),
                ],
                onChanged: (v) => ritualId = v,
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.schedule_rounded),
                    label: Text('${s.t('time')}: ${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}'),
                    onPressed: () async {
                      final t = await showTimePicker(context: ctx, initialTime: TimeOfDay.fromDateTime(at));
                      if (t != null) {
                        final n = DateTime.now();
                        var d = DateTime(n.year, n.month, n.day, t.hour, t.minute);
                        if (d.isBefore(n.subtract(const Duration(hours: 1)))) d = d.add(const Duration(days: 1));
                        setSt(() => at = d);
                      }
                    },
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 120,
                  child: TextField(controller: deadline, keyboardType: TextInputType.number, decoration: InputDecoration(labelText: s.t('deadline_min'))),
                ),
              ]),
              const SizedBox(height: 16),
              ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('save'))),
            ]),
          ),
        ),
      ),
    );
    if (ok != true || title.text.trim().isEmpty) return;
    try {
      await Api.call('app_create_gathering', {
        'p_group_id': groupId,
        'p_location_id': locId,
        'p_title': title.text,
        'p_scheduled_at': at.toUtc().toIso8601String(),
        'p_deadline_minutes': int.tryParse(deadline.text) ?? 15,
        'p_ritual_id': ritualId,
        'p_trip_id': null,
      });
      await onChanged();
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.network ? s.t('network_error') : e.message, color: AppColors.danger);
    }
  }
}

class _GatheringBlock extends StatelessWidget {
  final Map<String, dynamic> group;
  final Map<String, dynamic> gathering;
  final List<Map<String, dynamic>> pilgrims;
  final Future<void> Function() onChanged;
  const _GatheringBlock({required this.group, required this.gathering, required this.pilgrims, required this.onChanged});

  Future<void> _mark(BuildContext context, Map<String, dynamic> p, String status) async {
    try {
      await Api.call('app_manual_attendance', {'p_gathering_id': gathering['id'], 'p_pilgrim_id': p['id'], 'p_status': status});
      await onChanged();
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.message, color: AppColors.danger);
    }
  }

  Future<void> _close(BuildContext context) async {
    final s = S.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.t('close_gathering')),
        content: Text(s.t('close_gathering_body')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('close_gathering'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.call('app_close_gathering', {'p_gathering_id': gathering['id']});
      await onChanged();
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.message, color: AppColors.danger);
    }
  }

  Future<void> _finish(BuildContext context) async {
    final s = S.of(context);
    final c = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('${s.t('finish_ritual')} — ${gathering['ritual'] ?? ''}'),
        content: TextField(controller: c, maxLines: 4, decoration: InputDecoration(hintText: s.t('your_comment'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('send'))),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await Api.call('app_finish_ritual', {'p_ritual_id': gathering['ritual_id'], 'p_group_id': group['id'], 'p_comment': c.text});
      if (context.mounted) showSnack(context, s.t('report_issued'));
      await onChanged();
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.message, color: AppColors.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final at = DateTime.parse(gathering['scheduled_at'] as String).toLocal();
    final deadline = at.add(Duration(minutes: (gathering['deadline_minutes'] as num).toInt()));
    final overdue = DateTime.now().isAfter(deadline);
    return Panel(
      border: AppColors.gold.withValues(alpha: 0.6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${group['name']} · ${gathering['title']}', style: const TextStyle(fontWeight: FontWeight.w900, fontSize: 15)),
        Text('${gathering['location']} · ${clockOf(gathering['scheduled_at'] as String?)} (+${gathering['deadline_minutes']}′)'
            '${gathering['ritual'] != null ? ' · ${gathering['ritual']}' : ''}',
            style: TextStyle(color: overdue ? AppColors.danger : AppColors.textMuted, fontSize: 12.5)),
        const Divider(height: 20),
        for (final p in pilgrims)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${p['full_name']}', style: const TextStyle(fontWeight: FontWeight.w700)),
                  PriorityChip(level: p['priority_level'] as String?),
                ]),
              ),
              StatusPill(status: p['current_status'] as String?),
              PopupMenuButton<String>(
                tooltip: s.t('mark'),
                icon: const Icon(Icons.edit_note_rounded, color: AppColors.green),
                onSelected: (v) => _mark(context, p, v),
                itemBuilder: (_) => ['PRESENT', 'LATE', 'ABSENT']
                    .map((st) => PopupMenuItem(value: st, child: Text(s.t(st), style: TextStyle(color: statusColor(st)))))
                    .toList(),
              ),
            ]),
          ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: OutlinedButton(onPressed: () => _close(context), child: Text(s.t('close_gathering')))),
          if (gathering['ritual_id'] != null) ...[
            const SizedBox(width: 8),
            Expanded(child: ElevatedButton(onPressed: () => _finish(context), child: Text(s.t('finish_ritual'), textAlign: TextAlign.center))),
          ],
        ]),
      ]),
    );
  }
}
