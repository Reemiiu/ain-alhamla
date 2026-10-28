import 'package:flutter/material.dart';

import '../l10n/strings.dart';
import '../services/api.dart';
import '../services/location_service.dart';
import '../theme/app_theme.dart';
import 'common.dart';

/// زر النجدة (ضغط مطوّل) + زر «أنا تائه». كلاهما يُبلغ المشرف ومركز العمليات وأقرب 3 أفراد،
/// ويُحفظان في طابور عدم الاتصال إن انقطعت الشبكة.
class SosButton extends StatefulWidget {
  final VoidCallback onLost;
  const SosButton({super.key, required this.onLost});

  @override
  State<SosButton> createState() => _SosButtonState();
}

class _SosButtonState extends State<SosButton> {
  bool _sending = false;

  Future<bool> _confirm({required String title, required String body, required String action, required Color color, required IconData icon}) async {
    final s = S.of(context);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
      builder: (ctx) => Padding(
        padding: const EdgeInsets.all(24),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, color: color, size: 44),
          const SizedBox(height: 10),
          Text(title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          const SizedBox(height: 8),
          Text(body, textAlign: TextAlign.center, style: const TextStyle(color: AppColors.textMuted, height: 1.6)),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: color),
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(action),
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(width: double.infinity, child: OutlinedButton(onPressed: () => Navigator.pop(ctx, false), child: Text(s.t('cancel')))),
        ]),
      ),
    );
    return ok == true;
  }

  Future<void> _send(String kind) async {
    final s = S.of(context);
    final isSos = kind == 'SOS';
    final ok = await _confirm(
      title: s.t(isSos ? 'sos_title' : 'lost_title'),
      body: s.t(isSos ? 'sos_body' : 'lost_body'),
      action: s.t(isSos ? 'sos_send' : 'lost_send'),
      color: isSos ? AppColors.danger : AppColors.warning,
      icon: isSos ? Icons.shield_rounded : Icons.wrong_location_rounded,
    );
    if (!ok || !mounted) return;
    setState(() => _sending = true);
    try {
      // لا يتعطل البلاغ أبداً بسبب الموقع: إن تعذّر يُرسل بدونه ويستخدم الخادم آخر موقع معروف
      final pos = await LocationService.current();
      final r = await Api.callOrQueue('app_trigger_sos', {
        'p_lat': pos?.latitude,
        'p_lng': pos?.longitude,
        'p_recorded_at': DateTime.now().toUtc().toIso8601String(),
        'p_kind': kind,
      });
      if (!mounted) return;
      if (r == null) {
        showSnack(context, s.t('offline_saved'), color: AppColors.warning);
      } else {
        showSnack(context, isSos ? s.t('sos_sent', {'n': (r as Map)['notified']}) : s.t('lost_sent'),
            color: isSos ? AppColors.danger : AppColors.warning);
      }
      if (!isSos) widget.onLost();
    } on ApiException catch (e) {
      if (mounted) showSnack(context, e.message, color: AppColors.danger);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Column(children: [
      GestureDetector(
        onLongPress: _sending ? null : () => _send('SOS'),
        child: Container(
          width: 150,
          height: 150,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 5),
            gradient: const RadialGradient(center: Alignment(-0.3, -0.4), colors: [Color(0xFFD3574A), Color(0xFFA6362C)]),
            boxShadow: [BoxShadow(color: const Color(0xFFA6362C).withValues(alpha: 0.5), blurRadius: 30, offset: const Offset(0, 14))],
          ),
          child: _sending
              ? const Center(child: CircularProgressIndicator(color: Colors.white))
              : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.shield_rounded, color: Colors.white, size: 30),
                  SizedBox(height: 4),
                  Text('SOS', style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.w900, letterSpacing: 1)),
                ]),
        ),
      ),
      const SizedBox(height: 8),
      Text(s.t('sos_hint'), style: const TextStyle(color: AppColors.textMuted, fontSize: 12)),
      const SizedBox(height: 14),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.warning,
          side: const BorderSide(color: AppColors.warning, width: 1.5),
          minimumSize: const Size(220, 48),
        ),
        onPressed: _sending ? null : () => _send('LOST'),
        icon: const Icon(Icons.wrong_location_rounded),
        label: Text(s.t('lost_btn')),
      ),
    ]);
  }
}
