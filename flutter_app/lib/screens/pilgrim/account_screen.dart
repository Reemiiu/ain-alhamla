import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';
import 'contacts_screen.dart';
import 'medical_card_screen.dart';
import 'phrasebook_screen.dart';

/// حسابي: الملف، اللغة (4 لغات)، الخط الكبير، جهات الطوارئ، تسجيل الخروج.
class AccountScreen extends StatelessWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    final p = session.pilgrim ?? {};
    final g = session.group ?? {};
    return ListView(padding: const EdgeInsets.all(18), children: [
      Center(
        child: Column(children: [
          CircleAvatar(
            radius: 36,
            backgroundColor: AppColors.gold,
            child: const Icon(Icons.person_rounded, color: AppColors.green, size: 36),
          ),
          const SizedBox(height: 8),
          Text('${session.user?['full_name'] ?? ''}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
          Text('${session.campaign?['name'] ?? ''} · ${g['name'] ?? ''}', style: const TextStyle(color: AppColors.textMuted)),
          const SizedBox(height: 6),
          PriorityChip(level: p['priority_level'] as String?, reason: p['priority_reason'] as String?),
        ]),
      ),
      const SizedBox(height: 18),
      Panel(
        padding: EdgeInsets.zero,
        child: Column(children: [
          _info(s.t('national_id'), '${session.user?['national_id'] ?? ''}'),
          _info(s.t('passport'), '${p['passport_no'] ?? '—'}'),
          _info(s.t('blood_type'), '${p['blood_type'] ?? '—'}'),
          _info(s.t('nationality'), '${p['nationality'] ?? '—'}'),
          _info(s.t('supervisor'), '${g['supervisor_name'] ?? '—'}', last: true),
        ]),
      ),
      const SizedBox(height: 8),
      Row(children: [
        const Icon(Icons.lock_outline_rounded, size: 15, color: AppColors.textFaint),
        const SizedBox(width: 6),
        Expanded(child: Text(s.t('privacy_note'), style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint))),
      ]),
      const SizedBox(height: 16),
      Panel(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(children: [
          Row(children: [
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
          const Divider(height: 1),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            secondary: const Icon(Icons.text_increase_rounded, color: AppColors.green),
            title: Text(s.t('large_text'), style: const TextStyle(fontWeight: FontWeight.w700)),
            value: session.largeText,
            onChanged: session.setLargeText,
          ),
        ]),
      ),
      const SizedBox(height: 12),
      _tile(context, Icons.medical_information_rounded, s.t('medical_card'), const MedicalCardScreen()),
      _tile(context, Icons.contact_phone_rounded, s.t('emergency_contacts'), const ContactsScreen()),
      _tile(context, Icons.record_voice_over_rounded, s.t('phrases'), const PhrasebookScreen()),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(foregroundColor: AppColors.danger, side: const BorderSide(color: AppColors.danger)),
        onPressed: session.logout,
        icon: const Icon(Icons.logout_rounded),
        label: Text(s.t('logout')),
      ),
    ]);
  }

  Widget _info(String label, String value, {bool last = false}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(border: last ? null : const Border(bottom: BorderSide(color: AppColors.line))),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(color: AppColors.textMuted))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w800)),
        ]),
      );

  Widget _tile(BuildContext context, IconData icon, String label, Widget page) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          child: ListTile(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14), side: const BorderSide(color: AppColors.line)),
            leading: Icon(icon, color: AppColors.green),
            title: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
            trailing: const Icon(Icons.chevron_left_rounded),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page)),
          ),
        ),
      );
}
