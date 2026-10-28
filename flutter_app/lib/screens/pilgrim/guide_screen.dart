import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import '../map_screen.dart';

/// شاشة «أنا تائه»: سهم واتجاه ومسافة إلى نقطة التجمع أو المشرف، تتحدّث كل 15 ثانية.
/// تعمل بدون إنترنت أيضاً: GPS + آخر بيانات خريطة محفوظة على الجوال.
class GuideScreen extends StatefulWidget {
  const GuideScreen({super.key});

  @override
  State<GuideScreen> createState() => _GuideScreenState();
}

class _GuideScreenState extends State<GuideScreen> {
  Timer? _timer;
  bool _toSupervisor = false;

  @override
  void initState() {
    super.initState();
    final session = context.read<SessionProvider>();
    session.sendPing(askPermission: true);
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => session.sendPing());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    final prox = session.proximity;
    final g = prox?['gathering'] == null ? null : Map<String, dynamic>.from(prox!['gathering'] as Map);
    final sup = prox?['supervisor'] == null ? null : Map<String, dynamic>.from(prox!['supervisor'] as Map);
    final useSup = _toSupervisor || g == null;
    final target = useSup ? sup : g;

    return Scaffold(
      appBar: AppBar(title: Text(s.t('guide_title'))),
      body: ListView(padding: const EdgeInsets.all(20), children: [
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(value: false, label: Text(s.t('next_gathering')), icon: const Icon(Icons.flag_rounded)),
            ButtonSegment(value: true, label: Text(s.t('supervisor')), icon: const Icon(Icons.person_pin_circle_rounded)),
          ],
          selected: {useSup},
          onSelectionChanged: (v) => setState(() => _toSupervisor = v.first),
        ),
        const SizedBox(height: 24),
        Center(child: CompassArrow(bearing: target?['bearing'] as int?, size: 220, color: useSup ? AppColors.green : AppColors.gold)),
        const SizedBox(height: 18),
        Center(
          child: Text(fmtDistance(s, target?['distance_m'] as num?),
              style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w900, color: AppColors.text)),
        ),
        Center(
          child: Text(useSup ? s.t('guide_to_supervisor') : s.t('guide_to_gathering', {'name': g['location']}),
              style: const TextStyle(fontSize: 15, color: AppColors.textMuted, fontWeight: FontWeight.w700)),
        ),
        if (prox?['offline'] == true && target?['at'] != null)
          Center(
            child: Text(s.t('last_known', {'t': timeAgo(s, target!['at'] as String?)}),
                style: const TextStyle(color: AppColors.warning, fontWeight: FontWeight.w700)),
          ),
        if (prox?['offline'] == true)
          Center(child: Text(s.t('map_offline'), style: const TextStyle(color: AppColors.textFaint, fontSize: 12))),
        const SizedBox(height: 14),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => MapScreen(standalone: true, initialTarget: useSup ? 'supervisor' : 'gathering'))),
          icon: const Icon(Icons.map_rounded),
          label: Text(s.t('open_map')),
        ),
        const SizedBox(height: 14),
        Panel(color: AppColors.surfaceAlt, child: Text(s.t('guide_tip'), style: const TextStyle(height: 1.7, color: AppColors.textMuted))),
        const SizedBox(height: 16),
        ElevatedButton.icon(
          onPressed: () => callPhone(session.group?['supervisor_phone'] as String?),
          icon: const Icon(Icons.call_rounded),
          label: Text('${s.t('call_supervisor')} · ${session.group?['supervisor_name'] ?? ''}'),
        ),
        const SizedBox(height: 16),
        // عبارة بالعربية يعرضها الحاج على من حوله
        Panel(
          border: AppColors.gold,
          child: Column(children: [
            Text(S.ar('phr_lost'), textAlign: TextAlign.center, textDirection: TextDirection.rtl,
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900, color: AppColors.green, height: 1.6)),
            const SizedBox(height: 6),
            Text('${session.campaign?['name'] ?? ''} — ${session.group?['supervisor_phone'] ?? ''}',
                textDirection: TextDirection.rtl, style: const TextStyle(color: AppColors.textMuted)),
          ]),
        ),
      ]),
    );
  }
}
