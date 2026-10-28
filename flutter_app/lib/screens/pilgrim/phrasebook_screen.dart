import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../l10n/strings.dart';
import '../../providers/session_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common.dart';

/// عبارات جاهزة لغير الناطقين بالعربية: يختار الحاج العبارة بلغته فتظهر بالعربية بخط كبير ليعرضها على من حوله.
class PhrasebookScreen extends StatelessWidget {
  const PhrasebookScreen({super.key});

  static const _keys = ['phr_lost', 'phr_where_camp', 'phr_doctor', 'phr_sick', 'phr_water', 'phr_call', 'phr_toilet', 'phr_no_arabic'];
  static const _icons = [
    Icons.wrong_location_rounded, Icons.holiday_village_rounded, Icons.medical_services_rounded, Icons.airline_seat_recline_normal_rounded,
    Icons.water_drop_rounded, Icons.call_rounded, Icons.wc_rounded, Icons.translate_rounded,
  ];

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    return Scaffold(
      appBar: AppBar(title: Text(s.t('phrases'))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        Text(s.t('phr_hint'), style: const TextStyle(color: AppColors.textMuted)),
        const SizedBox(height: 12),
        for (var i = 0; i < _keys.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () => _show(context, _keys[i], session),
              child: Panel(
                child: Row(children: [
                  Icon(_icons[i], color: AppColors.green),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.t(_keys[i]), style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15)),
                      if (s.lang != 'ar')
                        Text(S.ar(_keys[i]), textDirection: TextDirection.rtl, style: const TextStyle(color: AppColors.textMuted)),
                    ]),
                  ),
                  const Icon(Icons.fullscreen_rounded, color: AppColors.textFaint),
                ]),
              ),
            ),
          ),
      ]),
    );
  }

  void _show(BuildContext context, String key, SessionProvider session) {
    final phone = session.group?['supervisor_phone'] as String?;
    final withPhone = key == 'phr_where_camp' || key == 'phr_call' || key == 'phr_lost';
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (ctx) => Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(backgroundColor: Colors.white),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(S.ar(key), textAlign: TextAlign.center, textDirection: TextDirection.rtl,
                  style: const TextStyle(fontSize: 40, fontWeight: FontWeight.w900, color: AppColors.green, height: 1.5)),
              if (withPhone && phone != null) ...[
                const SizedBox(height: 24),
                Text(phone, textDirection: TextDirection.ltr, style: const TextStyle(fontSize: 36, fontWeight: FontWeight.w900, letterSpacing: 2)),
                Text('${session.campaign?['name'] ?? ''}', textDirection: TextDirection.rtl, style: const TextStyle(fontSize: 18, color: AppColors.textMuted)),
              ],
            ]),
          ),
        ),
      ),
    ));
  }
}
