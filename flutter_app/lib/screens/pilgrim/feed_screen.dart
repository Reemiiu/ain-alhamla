import 'package:flutter/material.dart';

import '../../l10n/strings.dart';
import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// التنبيهات والإشعارات: رسائل المشرف، تجمعات جديدة، بلاغات قريبة، وحالة بلاغاتي.
class FeedScreen extends StatefulWidget {
  const FeedScreen({super.key});

  @override
  State<FeedScreen> createState() => _FeedScreenState();
}

class _FeedScreenState extends State<FeedScreen> {
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = Map<String, dynamic>.from(await Api.call('app_my_feed') as Map);
      final list = ((r['notifications'] as List?) ?? []).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (mounted) setState(() { _items = list; _loading = false; });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _markRead() async {
    try {
      await Api.call('app_mark_read');
      await _load();
    } catch (_) {}
  }

  IconData _icon(Map<String, dynamic> n) {
    if (n['broadcast_id'] != null) return Icons.campaign_rounded;
    switch (n['alert_type']) {
      case 'SOS':
        return Icons.shield_rounded;
      case 'LOST':
        return Icons.wrong_location_rounded;
      case 'ABSENCE':
      case 'DELAY':
        return Icons.schedule_rounded;
      case 'GEOFENCE_BREACH':
        return Icons.warning_rounded;
      default:
        return Icons.notifications_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 12, 4),
        child: Row(children: [
          Expanded(child: Text(s.t('tab_alerts'), style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w900))),
          TextButton(onPressed: _markRead, child: Text(s.t('mark_all_read'))),
        ]),
      ),
      Expanded(
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : RefreshIndicator(
                onRefresh: _load,
                child: _items.isEmpty
                    ? ListView(children: [Padding(padding: const EdgeInsets.all(60), child: Center(child: Text(s.t('no_notifications'))))])
                    : ListView.separated(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        itemCount: _items.length,
                        separatorBuilder: (_, __) => const SizedBox(height: 8),
                        itemBuilder: (_, i) {
                          final n = _items[i];
                          final urgent = n['is_urgent'] == true || n['alert_type'] == 'SOS' || n['alert_type'] == 'LOST';
                          final c = urgent ? AppColors.danger : n['broadcast_id'] != null ? AppColors.gold : AppColors.green;
                          return Panel(
                            color: n['read_at'] == null ? const Color(0xFFFFFBF0) : Colors.white,
                            border: urgent ? AppColors.danger.withValues(alpha: 0.35) : null,
                            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              CircleAvatar(radius: 18, backgroundColor: c.withValues(alpha: 0.13), child: Icon(_icon(n), color: c, size: 18)),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Row(children: [
                                    Expanded(child: Text('${n['title'] ?? ''}', style: const TextStyle(fontWeight: FontWeight.w800))),
                                    if (n['is_urgent'] == true)
                                      Text(s.t('urgent'), style: const TextStyle(color: AppColors.danger, fontSize: 11, fontWeight: FontWeight.w900)),
                                  ]),
                                  if (n['body'] != null) Text('${n['body']}', style: const TextStyle(color: AppColors.textMuted, height: 1.5)),
                                  const SizedBox(height: 2),
                                  Text(timeAgo(s, n['sent_at'] as String?), style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
                                ]),
                              ),
                            ]),
                          );
                        },
                      ),
              ),
      ),
    ]);
  }
}
