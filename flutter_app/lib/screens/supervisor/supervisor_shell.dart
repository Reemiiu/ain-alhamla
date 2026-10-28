import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../map_screen.dart';
import 'staff_alerts_screen.dart';
import 'gathering_screen.dart';
import 'group_screen.dart';

/// واجهة المشرف الميدانية في التطبيق: مجموعتي، الخريطة (تعمل بدون إنترنت)، التجمعات والحضور، التنبيهات، حسابي.
/// تُحدَّث كل 20 ثانية (app_tick يفتح التجمعات وينبّه على الغياب ويصعّد البلاغات).
class SupervisorShell extends StatefulWidget {
  const SupervisorShell({super.key});

  @override
  State<SupervisorShell> createState() => _SupervisorShellState();
}

class _SupervisorShellState extends State<SupervisorShell> {
  int _index = 0;
  Map<String, dynamic>? board;
  Timer? _timer;
  int _unread = 0;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 20), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final tick = Map<String, dynamic>.from(await Api.call('app_tick') as Map);
      final b = Map<String, dynamic>.from(await Api.call('app_board') as Map);
      if (!mounted) return;
      final unread = (tick['unread'] as num?)?.toInt() ?? 0;
      if (unread > _unread && _unread != 0) {
        showSnack(context, S.of(context).t('tab_alerts'), color: AppColors.danger);
      }
      setState(() {
        board = b;
        _unread = unread;
      });
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(children: [
          const OfflineBanner(),
          Expanded(
            child: IndexedStack(index: _index, children: [
              GroupScreen(board: board, onRefresh: _load),
              MapScreen(active: _index == 1),
              GatheringScreen(board: board, onChanged: _load),
              StaffAlertsScreen(onChanged: _load),
              const _StaffAccount(),
            ]),
          ),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.groups_outlined), selectedIcon: const Icon(Icons.groups_rounded), label: s.t('tab_group')),
          NavigationDestination(icon: const Icon(Icons.map_outlined), selectedIcon: const Icon(Icons.map_rounded), label: s.t('tab_map')),
          NavigationDestination(icon: const Icon(Icons.fact_check_outlined), selectedIcon: const Icon(Icons.fact_check_rounded), label: s.t('tab_gatherings')),
          NavigationDestination(
            icon: Badge(isLabelVisible: _unread > 0, label: Text('$_unread'), child: const Icon(Icons.notifications_outlined)),
            selectedIcon: const Icon(Icons.notifications_rounded),
            label: s.t('tab_alerts'),
          ),
          NavigationDestination(icon: const Icon(Icons.person_outline_rounded), selectedIcon: const Icon(Icons.person_rounded), label: s.t('tab_account')),
        ],
      ),
    );
  }
}

/// حساب المشرف: رسالة جماعية للمجموعة، اللغة، تسجيل الخروج.
class _StaffAccount extends StatefulWidget {
  const _StaffAccount();

  @override
  State<_StaffAccount> createState() => _StaffAccountState();
}

class _StaffAccountState extends State<_StaffAccount> {
  final _title = TextEditingController();
  final _body = TextEditingController();
  bool _urgent = false;
  int? _groupId;

  Future<void> _send() async {
    final s = S.of(context);
    final groups = context.read<SessionProvider>().staffGroups;
    final gid = _groupId ?? (groups.isEmpty ? null : groups.first['id'] as int);
    if (_title.text.trim().isEmpty || _body.text.trim().isEmpty || gid == null) return;
    try {
      final r = Map<String, dynamic>.from(await Api.call('app_send_broadcast',
          {'p_group_id': gid, 'p_title': _title.text, 'p_body': _body.text, 'p_urgent': _urgent}) as Map);
      if (!mounted) return;
      showSnack(context, s.t('broadcast_sent', {'n': r['recipients']}));
      _title.clear();
      _body.clear();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.network ? s.t('network_error') : e.message, color: AppColors.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    final groups = session.staffGroups;
    return ListView(padding: const EdgeInsets.all(18), children: [
      Row(children: [
        const CircleAvatar(radius: 26, backgroundColor: AppColors.green, child: Icon(Icons.badge_rounded, color: AppColors.gold)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${session.user?['full_name'] ?? ''}', style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w900)),
            Text(groups.map((g) => g['name']).join('، '), style: const TextStyle(color: AppColors.textMuted)),
          ]),
        ),
      ]),
      const SizedBox(height: 18),
      SectionTitle(s.t('broadcast')),
      Panel(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (groups.length > 1)
            DropdownButtonFormField<int>(
              initialValue: _groupId ?? groups.first['id'] as int,
              items: groups.map((g) => DropdownMenuItem(value: g['id'] as int, child: Text('${g['name']}'))).toList(),
              onChanged: (v) => setState(() => _groupId = v),
            ),
          const SizedBox(height: 8),
          TextField(controller: _title, decoration: InputDecoration(hintText: s.t('title'))),
          const SizedBox(height: 8),
          TextField(controller: _body, maxLines: 3, decoration: InputDecoration(hintText: s.t('body'))),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: _urgent,
            onChanged: (v) => setState(() => _urgent = v ?? false),
            title: Text(s.t('urgent')),
          ),
          ElevatedButton.icon(onPressed: _send, icon: const Icon(Icons.campaign_rounded), label: Text(s.t('send'))),
        ]),
      ),
      const SizedBox(height: 16),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        child: Row(children: [
          const Icon(Icons.translate_rounded, color: AppColors.green),
          const SizedBox(width: 12),
          Expanded(child: Text(s.t('language'), style: const TextStyle(fontWeight: FontWeight.w700))),
          DropdownButton<String>(
            value: session.lang,
            underline: const SizedBox.shrink(),
            items: S.supported.map((l) => DropdownMenuItem(value: l, child: Text(S.names[l]!))).toList(),
            onChanged: (v) {
              if (v != null) session.setLanguage(v);
            },
          ),
        ]),
      ),
      const SizedBox(height: 10),
      Text(s.t('dashboard_link'), style: const TextStyle(color: AppColors.textFaint, fontSize: 12)),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, side: const BorderSide(color: AppColors.danger)),
        onPressed: session.logout,
        icon: const Icon(Icons.logout_rounded),
        label: Text(s.t('logout')),
      ),
    ]);
  }
}
