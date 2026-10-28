import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../providers/session_provider.dart';
import '../services/api.dart';
import '../theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _id = TextEditingController();
  final _pw = TextEditingController();
  bool _loading = false;
  String? _error;

  @override
  void dispose() {
    _id.dispose();
    _pw.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final s = S.of(context);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final ok = await context.read<SessionProvider>().login(_id.text.trim(), _pw.text);
      if (!ok && mounted) setState(() => _error = s.t('login_error'));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.network ? s.t('network_error') : e.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final session = context.watch<SessionProvider>();
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 12),
              // اختيار اللغة قبل الدخول (لغير الناطقين بالعربية)
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: PopupMenuButton<String>(
                  onSelected: session.setLanguage,
                  itemBuilder: (_) => S.supported.map((l) => PopupMenuItem(value: l, child: Text(S.names[l]!))).toList(),
                  child: Padding(
                    padding: const EdgeInsets.all(8),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      const Icon(Icons.translate_rounded, size: 18, color: AppColors.green),
                      const SizedBox(width: 6),
                      Text(S.names[session.lang]!, style: const TextStyle(fontWeight: FontWeight.w700, color: AppColors.green)),
                    ]),
                  ),
                ),
              ),
              const SizedBox(height: 18),
              ClipRRect(
                borderRadius: BorderRadius.circular(22),
                child: Image.asset('assets/logo.jpg', width: 96, height: 96, fit: BoxFit.cover),
              ),
              const SizedBox(height: 10),
              Text(s.t('app_name'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: AppColors.green)),
              const SizedBox(height: 4),
              Text(s.t('tagline'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 12.5, color: AppColors.textMuted)),
              const SizedBox(height: 28),
              _label(s.t('national_id')),
              TextField(controller: _id, keyboardType: TextInputType.number, textInputAction: TextInputAction.next,
                  decoration: const InputDecoration(hintText: '1030303030')),
              const SizedBox(height: 14),
              _label(s.t('password')),
              TextField(controller: _pw, obscureText: true, onSubmitted: (_) => _submit(),
                  decoration: const InputDecoration(hintText: '••••••••')),
              if (_error != null) ...[
                const SizedBox(height: 10),
                Text(_error!, style: const TextStyle(color: AppColors.danger, fontSize: 13)),
              ],
              const SizedBox(height: 18),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _loading ? null : _submit,
                  child: _loading
                      ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : Text(s.t('login')),
                ),
              ),
              const SizedBox(height: 16),
              Text(s.t('staff_hint'), textAlign: TextAlign.center, style: const TextStyle(fontSize: 11.5, color: AppColors.textFaint)),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }

  Widget _label(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: Text(t, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: AppColors.text)),
        ),
      );
}
