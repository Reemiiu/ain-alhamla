import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../services/api.dart';
import '../../services/location_service.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../../widgets/sos_button.dart';
import 'contacts_screen.dart';
import 'guide_screen.dart';
import 'hajj_screen.dart';
import 'medical_card_screen.dart';
import 'phrasebook_screen.dart';

/// الرئيسية للحاج: حالة النطاق، التجمع القادم مع عدّاد المهلة وزر الحضور، مؤشر القرب، SOS و«أنا تائه».
class HomeScreen extends StatefulWidget {
  final void Function(int tab) onOpenTab;
  const HomeScreen({super.key, required this.onOpenTab});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Map<String, dynamic>> _messages = [];
  bool _checking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _refresh());
  }

  Future<void> _refresh() async {
    final session = context.read<SessionProvider>();
    await Future.wait([session.sendPing(), _loadMessages()]);
  }

  Future<void> _loadMessages() async {
    try {
      final feed = await Api.call('app_my_feed');
      final list = ((feed as Map)['notifications'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
      if (mounted) setState(() => _messages = list.where((n) => n['broadcast_id'] != null).take(2).toList());
    } catch (_) {}
  }

  Future<void> _checkIn(Map<String, dynamic> g) async {
    final s = S.of(context);
    final session = context.read<SessionProvider>();
    setState(() => _checking = true);
    try {
      final pos = await LocationService.current();
      final r = await Api.callOrQueue('app_check_in', {
        'p_gathering_id': g['id'],
        'p_lat': pos?.latitude,
        'p_lng': pos?.longitude,
        'p_recorded_at': DateTime.now().toUtc().toIso8601String(),
      });
      if (!mounted) return;
      if (r == null) {
        showSnack(context, s.t('offline_saved'), color: AppColors.warning);
      } else {
        final st = (r as Map)['status'] as String;
        showSnack(context, s.t('checked_in', {'s': s.t(st)}), color: statusColor(st));
        await session.refreshProximity();
      }
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, color: AppColors.danger);
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    final prox = session.proximity;
    final g = prox?['gathering'] == null ? null : Map<String, dynamic>.from(prox!['gathering'] as Map);
    final sup = prox?['supervisor'] == null ? null : Map<String, dynamic>.from(prox!['supervisor'] as Map);
    final near = prox?['nearest_member'] == null ? null : Map<String, dynamic>.from(prox!['nearest_member'] as Map);
    final zone = prox?['zone'] == null ? null : Map<String, dynamic>.from(prox!['zone'] as Map);
    final groupCenter = prox?['group_center'] == null ? null : Map<String, dynamic>.from(prox!['group_center'] as Map);

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          _Header(session: session, zone: zone, hasLocation: prox?['me'] != null),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (g != null) _GatheringCard(g: g, checking: _checking, onCheckIn: () => _checkIn(g)) else
                Panel(child: Row(children: [
                  const Icon(Icons.event_available_rounded, color: AppColors.textFaint),
                  const SizedBox(width: 10),
                  Text(s.t('no_gathering'), style: const TextStyle(color: AppColors.textMuted)),
                ])),
              const SizedBox(height: 12),
              // مؤشر القرب
              Panel(
                child: Row(children: [
                  CompassArrow(bearing: sup?['bearing'] as int?, size: 64),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.t('proximity'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                      Text(sup == null ? '—' : '${fmtDistance(s, sup['distance_m'] as num?)} ${s.t('from_supervisor')}',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800, color: AppColors.text)),
                      if (near != null)
                        Text(s.t('nearest_member', {'name': near['name']}) + ' · ${fmtDistance(s, near['distance_m'] as num?)}',
                            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                      // بدون إنترنت: المسافة محسوبة على الجوال من آخر موقع معروف للمشرف
                      if (prox?['offline'] == true && sup?['at'] != null)
                        Text(s.t('last_known', {'t': timeAgo(s, sup!['at'] as String?)}),
                            style: const TextStyle(fontSize: 11.5, color: AppColors.warning, fontWeight: FontWeight.w700)),
                      if (prox?['offline'] == true && groupCenter != null && groupCenter['distance_m'] != null)
                        Text('${s.t('group_center', {'n': groupCenter['members']})} · ${fmtDistance(s, groupCenter['distance_m'] as num?)}',
                            style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
                    ]),
                  ),
                  IconButton(
                    onPressed: () => widget.onOpenTab(1),
                    icon: const Icon(Icons.map_rounded, color: AppColors.green),
                    tooltip: s.t('open_map'),
                  ),
                  IconButton.filledTonal(
                    onPressed: () => callPhone(session.group?['supervisor_phone'] as String?),
                    icon: const Icon(Icons.call_rounded),
                    tooltip: s.t('call_supervisor'),
                  ),
                ]),
              ),
              const SizedBox(height: 22),
              Center(child: SosButton(onLost: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const GuideScreen())))),
              const SizedBox(height: 22),
              const HajjEntryCard(),
              const SizedBox(height: 12),
              Row(children: [
                _Quick(icon: Icons.medical_information_rounded, label: s.t('medical_card'),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const MedicalCardScreen()))),
                const SizedBox(width: 10),
                _Quick(icon: Icons.translate_rounded, label: s.t('phrases'),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const PhrasebookScreen()))),
                const SizedBox(width: 10),
                _Quick(icon: Icons.contact_phone_rounded, label: s.t('emergency_contacts'),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ContactsScreen()))),
              ]),
              if (_messages.isNotEmpty) ...[
                const SizedBox(height: 20),
                SectionTitle(s.t('messages_from'), trailing: TextButton(onPressed: () => widget.onOpenTab(3), child: Text(s.t('tab_alerts')))),
                for (final m in _messages)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Panel(
                      border: m['is_urgent'] == true ? AppColors.danger.withValues(alpha: 0.4) : null,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Icon(Icons.campaign_rounded, size: 18, color: m['is_urgent'] == true ? AppColors.danger : AppColors.gold),
                          const SizedBox(width: 6),
                          Expanded(child: Text('${m['title']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                          Text(timeAgo(s, m['sent_at'] as String?), style: const TextStyle(fontSize: 11, color: AppColors.textFaint)),
                        ]),
                        const SizedBox(height: 4),
                        Text('${m['body'] ?? ''}', style: const TextStyle(color: AppColors.textMuted, height: 1.6)),
                      ]),
                    ),
                  ),
              ],
            ]),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final SessionProvider session;
  final Map<String, dynamic>? zone;
  final bool hasLocation;
  const _Header({required this.session, required this.zone, required this.hasLocation});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final name = (session.user?['full_name'] as String?) ?? '';
    final inside = zone?['inside'] == true;
    final group = session.group;
    final String pillText;
    final Color pillColor;
    if (!hasLocation || zone == null) {
      pillText = s.t('no_location');
      pillColor = AppColors.textMuted;
    } else if (inside) {
      pillText = s.t('inside_zone');
      pillColor = AppColors.success;
    } else {
      pillText = s.t('outside_zone', {'d': fmtDistance(s, zone!['distance_m'] as num?), 'zone': zone!['name']});
      pillColor = AppColors.danger;
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [AppColors.green, AppColors.greenSoft]),
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(26)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          CircleAvatar(
            radius: 22,
            backgroundColor: AppColors.gold,
            child: Text(name.isNotEmpty ? name.characters.first : '؟',
                style: const TextStyle(color: AppColors.green, fontWeight: FontWeight.w900, fontSize: 18)),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(s.t('welcome', {'name': name.split(' ').first}),
                style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w800)),
          ),
        ]),
        const SizedBox(height: 12),
        Text('${session.campaign?['name'] ?? ''}', style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700)),
        if (group != null)
          Text('${group['name']} · ${s.t('supervisor')}: ${group['supervisor_name'] ?? '—'}',
              style: const TextStyle(color: Colors.white70, fontSize: 12)),
        const SizedBox(height: 10),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(color: pillColor, borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(inside ? Icons.verified_user_rounded : Icons.my_location_rounded, color: Colors.white, size: 15),
            const SizedBox(width: 6),
            Flexible(child: Text(pillText, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700))),
          ]),
        ),
      ]),
    );
  }
}

/// بطاقة التجمع القادم: عدّاد تنازلي للموعد ثم للمهلة، المسافة والاتجاه، وزر تسجيل الحضور.
class _GatheringCard extends StatefulWidget {
  final Map<String, dynamic> g;
  final bool checking;
  final VoidCallback onCheckIn;
  const _GatheringCard({required this.g, required this.checking, required this.onCheckIn});

  @override
  State<_GatheringCard> createState() => _GatheringCardState();
}

class _GatheringCardState extends State<_GatheringCard> {
  Timer? _t;

  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final g = widget.g;
    final at = DateTime.parse(g['scheduled_at'] as String).toLocal();
    final deadline = at.add(Duration(minutes: (g['deadline_minutes'] as num).toInt()));
    final now = DateTime.now();
    final checked = g['checked_in'] as String?;
    final String timing;
    Color tColor = AppColors.green;
    if (now.isBefore(at)) {
      timing = s.t('starts_in', {'t': fmtDuration(at.difference(now))});
    } else if (now.isBefore(deadline)) {
      timing = s.t('deadline_in', {'t': fmtDuration(deadline.difference(now))});
      tColor = AppColors.warning;
    } else {
      timing = s.t('deadline_passed');
      tColor = AppColors.danger;
    }
    return Panel(
      border: AppColors.gold.withValues(alpha: 0.6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Icon(Icons.flag_rounded, color: AppColors.gold, size: 18),
          const SizedBox(width: 6),
          Text(s.t('next_gathering'), style: const TextStyle(fontSize: 12, color: AppColors.textMuted, fontWeight: FontWeight.w700)),
          const Spacer(),
          if (checked != null) StatusPill(status: checked),
        ]),
        const SizedBox(height: 6),
        Text('${g['title']}', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w900, color: AppColors.text)),
        Text('${g['location']} · ${clockOf(g['scheduled_at'] as String?)}', style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
        const SizedBox(height: 10),
        Row(children: [
          CompassArrow(bearing: g['bearing'] as int?, size: 52, color: AppColors.gold),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(fmtDistance(s, g['distance_m'] as num?), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900, color: AppColors.text)),
              if (checked == null) Text(timing, style: TextStyle(color: tColor, fontWeight: FontWeight.w800, fontSize: 13)),
            ]),
          ),
        ]),
        if (checked == null) ...[
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: widget.checking ? null : widget.onCheckIn,
            icon: widget.checking
                ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.how_to_reg_rounded),
            label: Text(s.t('check_in')),
          ),
        ] else
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(s.t('checked_in', {'s': s.t(checked)}), style: TextStyle(color: statusColor(checked), fontWeight: FontWeight.w800)),
          ),
      ]),
    );
  }
}

class _Quick extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _Quick({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 6),
          decoration: BoxDecoration(color: AppColors.surfaceAlt, border: Border.all(color: AppColors.line), borderRadius: BorderRadius.circular(14)),
          child: Column(children: [
            Icon(icon, color: AppColors.green, size: 24),
            const SizedBox(height: 6),
            Text(label, textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, fontWeight: FontWeight.w700, color: AppColors.text)),
          ]),
        ),
      ),
    );
  }
}
