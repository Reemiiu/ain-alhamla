import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../widgets/common.dart';
import '../map_screen.dart';
import 'account_screen.dart';
import 'feed_screen.dart';
import 'hajj_screen.dart';
import 'home_screen.dart';
import 'schedule_screen.dart';

/// واجهة الحاج: الرئيسية، الخريطة (تعمل بدون إنترنت)، جدولي، التنبيهات، حسابي.
class PilgrimShell extends StatefulWidget {
  const PilgrimShell({super.key});

  @override
  State<PilgrimShell> createState() => _PilgrimShellState();
}

class _PilgrimShellState extends State<PilgrimShell> {
  int _index = 0;
  late final SessionProvider _session;

  @override
  void initState() {
    super.initState();
    _session = context.read<SessionProvider>();
    _session.wellness.addListener(_onWellness);
  }

  @override
  void dispose() {
    _session.wellness.removeListener(_onWellness);
    super.dispose();
  }

  void _onWellness() {
    final w = _session.wellness.value;
    if (w != null && mounted) showWellnessDialog(context, w);
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
              HomeScreen(onOpenTab: (i) => setState(() => _index = i)),
              MapScreen(active: _index == 1),
              const ScheduleScreen(),
              const FeedScreen(),
              const AccountScreen(),
            ]),
          ),
        ]),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), selectedIcon: const Icon(Icons.home_rounded), label: s.t('tab_home')),
          NavigationDestination(icon: const Icon(Icons.map_outlined), selectedIcon: const Icon(Icons.map_rounded), label: s.t('tab_map')),
          NavigationDestination(icon: const Icon(Icons.event_note_outlined), selectedIcon: const Icon(Icons.event_note_rounded), label: s.t('tab_schedule')),
          NavigationDestination(icon: const Icon(Icons.notifications_outlined), selectedIcon: const Icon(Icons.notifications_rounded), label: s.t('tab_alerts')),
          NavigationDestination(icon: const Icon(Icons.person_outline_rounded), selectedIcon: const Icon(Icons.person_rounded), label: s.t('tab_account')),
        ],
      ),
    );
  }
}
