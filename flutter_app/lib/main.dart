import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:provider/provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'l10n/strings.dart';
import 'providers/session_provider.dart';
import 'screens/login_screen.dart';
import 'screens/pilgrim/pilgrim_shell.dart';
import 'screens/supervisor/supervisor_shell.dart';
import 'services/api.dart';
import 'services/supabase_config.dart';
import 'theme/app_theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Supabase.initialize(url: SupabaseConfig.supabaseUrl, anonKey: SupabaseConfig.supabaseAnonKey);
  await Api.init();
  final session = SessionProvider();
  session.restore();
  runApp(ChangeNotifierProvider.value(value: session, child: const AinAlHamlaApp()));
}

class AinAlHamlaApp extends StatelessWidget {
  const AinAlHamlaApp({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    return MaterialApp(
      title: 'عين الحملة',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      locale: Locale(session.lang),
      supportedLocales: S.supported.map((l) => Locale(l)).toList(),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      // الخط الكبير لكبار السن: تكبير كل نصوص التطبيق
      builder: (context, child) {
        final mq = MediaQuery.of(context);
        return MediaQuery(
          data: mq.copyWith(textScaler: TextScaler.linear(session.largeText ? 1.3 : 1.0)),
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: const _Root(),
    );
  }
}

/// يوجّه كل مستخدم لواجهته: الحاج ← واجهة الحاج، المشرف/الإدارة ← واجهة المشرف الميدانية.
class _Root extends StatelessWidget {
  const _Root();

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionProvider>();
    if (session.restoring) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (!session.loggedIn) return const LoginScreen();
    if (session.isPilgrim) return const PilgrimShell();
    return const SupervisorShell();
  }
}
