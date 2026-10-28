import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// بطاقة الطوارئ الطبية ثنائية اللغة: بلغة الحاج + العربية دائماً، ليقرأها أي مسعف أو رجل أمن.
class MedicalCardScreen extends StatelessWidget {
  const MedicalCardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    final p = session.pilgrim ?? {};
    final g = session.group ?? {};
    final contact = session.contacts.isEmpty ? null : session.contacts.first;
    final birth = DateTime.tryParse('${p['birth_date']}');
    final age = birth == null ? null : (DateTime.now().difference(birth).inDays / 365.25).floor();
    final bilingual = s.lang != 'ar';

    Widget row(String key, String value, {bool big = false, Color? color}) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(bilingual ? '${s.t(key)} · ${S.ar(key)}' : S.ar(key), style: const TextStyle(fontSize: 12, color: AppColors.textMuted)),
            Text(value, style: TextStyle(fontSize: big ? 24 : 17, fontWeight: FontWeight.w900, color: color ?? AppColors.text)),
          ]),
        );

    return Scaffold(
      backgroundColor: AppColors.green,
      appBar: AppBar(backgroundColor: AppColors.green, foregroundColor: Colors.white, title: Text(s.t('medical_card'))),
      body: ListView(padding: const EdgeInsets.all(18), children: [
        Text(bilingual ? '${s.t('card_show')}\n${S.ar('card_show')}' : S.ar('card_show'),
            textAlign: TextAlign.center, style: const TextStyle(color: AppColors.gold, fontWeight: FontWeight.w700, height: 1.6)),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(20), border: Border.all(color: AppColors.danger, width: 3)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              const Icon(Icons.medical_services_rounded, color: AppColors.danger, size: 28),
              const SizedBox(width: 8),
              Expanded(
                child: Text(bilingual ? '${s.t('card_title')} · ${S.ar('card_title')}' : S.ar('card_title'),
                    style: const TextStyle(fontWeight: FontWeight.w900, color: AppColors.danger)),
              ),
            ]),
            const Divider(height: 22),
            Text('${session.user?['full_name'] ?? ''}', style: const TextStyle(fontSize: 26, fontWeight: FontWeight.w900)),
            Text('${p['nationality'] ?? ''}${age != null ? ' · $age' : ''}', style: const TextStyle(color: AppColors.textMuted)),
            row('blood_type', '${p['blood_type'] ?? '—'}', big: true, color: AppColors.danger),
            row('medical', (p['medical_notes'] as String?)?.isNotEmpty == true ? p['medical_notes'] as String : s.t('none')),
            if (contact != null)
              row('emergency_contact', '${contact['name']} (${contact['relation'] ?? ''})\n${contact['phone']}'),
            row('campaign_supervisor', '${g['supervisor_name'] ?? '—'}\n${g['supervisor_phone'] ?? ''}'),
            row('campaign', '${session.campaign?['name'] ?? ''} · ${g['name'] ?? ''}'),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              style: ElevatedButton.styleFrom(backgroundColor: AppColors.danger),
              onPressed: () => callPhone(g['supervisor_phone'] as String?),
              icon: const Icon(Icons.call_rounded),
              label: Text(s.t('call_supervisor')),
            ),
          ]),
        ),
      ]),
    );
  }
}
