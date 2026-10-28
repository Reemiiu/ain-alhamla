import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../services/api.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// جهات الطوارئ (عبر دوال الخادم — الجدول نفسه لا يُقرأ مباشرة حفاظاً على الخصوصية).
class ContactsScreen extends StatelessWidget {
  const ContactsScreen({super.key});

  Future<void> _add(BuildContext context) async {
    final s = S.of(context);
    final name = TextEditingController(), rel = TextEditingController(), phone = TextEditingController();
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 20, 20, MediaQuery.of(ctx).viewInsets.bottom + 20),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(s.t('add_contact'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800)),
          const SizedBox(height: 12),
          TextField(controller: name, decoration: InputDecoration(hintText: s.t('name'))),
          const SizedBox(height: 10),
          TextField(controller: rel, decoration: InputDecoration(hintText: s.t('relation'))),
          const SizedBox(height: 10),
          TextField(controller: phone, keyboardType: TextInputType.phone, decoration: InputDecoration(hintText: s.t('phone'))),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: () => Navigator.pop(ctx, true), child: Text(s.t('save'))),
        ]),
      ),
    );
    if (ok != true || name.text.trim().isEmpty || phone.text.trim().isEmpty || !context.mounted) return;
    try {
      await Api.call('app_save_contact', {'p_name': name.text, 'p_relation': rel.text, 'p_phone': phone.text, 'p_is_primary': false});
      if (context.mounted) await context.read<SessionProvider>().refreshMe();
    } on ApiException catch (e) {
      if (context.mounted) showSnack(context, e.network ? s.t('network_error') : e.message, color: AppColors.danger);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    final list = session.contacts;
    return Scaffold(
      appBar: AppBar(title: Text(s.t('emergency_contacts'))),
      floatingActionButton: FloatingActionButton(
        backgroundColor: AppColors.green,
        onPressed: () => _add(context),
        child: const Icon(Icons.add, color: Colors.white),
      ),
      body: list.isEmpty
          ? Center(child: Text(s.t('none'), style: const TextStyle(color: AppColors.textFaint)))
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              separatorBuilder: (_, __) => const SizedBox(height: 10),
              itemBuilder: (_, i) {
                final c = list[i];
                return Panel(
                  child: Row(children: [
                    const CircleAvatar(backgroundColor: AppColors.surfaceAlt, child: Icon(Icons.person_rounded, color: AppColors.green)),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Flexible(child: Text('${c['name']}', style: const TextStyle(fontWeight: FontWeight.w800))),
                          if (c['is_primary'] == true) ...[
                            const SizedBox(width: 6),
                            Text(s.t('primary'), style: const TextStyle(fontSize: 11, color: AppColors.success, fontWeight: FontWeight.w800)),
                          ],
                        ]),
                        Text('${c['relation'] ?? ''} · ${c['phone']}', style: const TextStyle(color: AppColors.textMuted, fontSize: 12.5)),
                      ]),
                    ),
                    IconButton(icon: const Icon(Icons.call_rounded, color: AppColors.green), onPressed: () => callPhone(c['phone'] as String?)),
                    IconButton(
                      icon: const Icon(Icons.delete_outline_rounded, color: AppColors.danger),
                      onPressed: () async {
                        try {
                          await Api.call('app_delete_contact', {'p_contact_id': c['id']});
                          if (context.mounted) await context.read<SessionProvider>().refreshMe();
                        } catch (_) {}
                      },
                    ),
                  ]),
                );
              },
            ),
    );
  }
}
