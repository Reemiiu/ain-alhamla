import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/strings.dart';
import '../services/api.dart';
import '../theme/app_theme.dart';

String fmtDistance(S s, num? m) {
  if (m == null) return '—';
  if (m >= 1000) return s.t('km', {'n': (m / 1000).toStringAsFixed(1)});
  return s.t('meters', {'n': m.round()});
}

String timeAgo(S s, String? iso) {
  if (iso == null) return '—';
  final d = DateTime.tryParse(iso);
  if (d == null) return '—';
  final min = DateTime.now().difference(d).inMinutes;
  if (min < 1) return s.t('now');
  if (min < 60) return s.t('min_ago', {'n': min});
  return s.t('hour_ago', {'n': (min / 60).floor()});
}

String clockOf(String? iso) {
  if (iso == null) return '—';
  final d = DateTime.tryParse(iso)?.toLocal();
  if (d == null) return '—';
  return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
}

String fmtDuration(Duration d) {
  final neg = d.isNegative;
  final a = d.abs();
  final h = a.inHours, m = a.inMinutes % 60, sec = a.inSeconds % 60;
  final txt = h > 0 ? '$h:${m.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}' : '$m:${sec.toString().padLeft(2, '0')}';
  return neg ? '-$txt' : txt;
}

Future<void> callPhone(String? phone) async {
  if (phone == null || phone.isEmpty) return;
  await launchUrl(Uri(scheme: 'tel', path: phone));
}

Color statusColor(String? status) {
  switch (status) {
    case 'PRESENT':
      return AppColors.success;
    case 'LATE':
      return AppColors.warning;
    case 'ABSENT':
    case 'OUT_OF_RANGE':
      return AppColors.danger;
    default:
      return AppColors.textFaint;
  }
}

class StatusPill extends StatelessWidget {
  final String? status;
  const StatusPill({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final c = statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(999)),
      child: Text(s.t(status ?? 'NOT_CHECKED'), style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w800)),
    );
  }
}

class PriorityChip extends StatelessWidget {
  final String? level;
  final String? reason;
  const PriorityChip({super.key, required this.level, this.reason});

  @override
  Widget build(BuildContext context) {
    if (level == null || level == 'NORMAL') return const SizedBox.shrink();
    final s = S.of(context);
    final c = level == 'CRITICAL' ? AppColors.danger : AppColors.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(999)),
      child: Text('${s.t(level!)}${reason != null ? ' · $reason' : ''}',
          style: TextStyle(color: c, fontSize: 10.5, fontWeight: FontWeight.w800), overflow: TextOverflow.ellipsis),
    );
  }
}

/// بطاقة بيضاء بحدود ناعمة (نفس بطاقات الموقع)
class Panel extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final Color? border;
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(14), this.color, this.border});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: padding,
      decoration: BoxDecoration(
        color: color ?? Colors.white,
        border: Border.all(color: border ?? AppColors.line),
        borderRadius: BorderRadius.circular(16),
      ),
      child: child,
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8, top: 4),
      child: Row(children: [
        Expanded(child: Text(text, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: AppColors.text))),
        if (trailing != null) trailing!,
      ]),
    );
  }
}

/// شريط يظهر عند انقطاع الشبكة أو وجود عمليات محفوظة بانتظار الإرسال
class OfflineBanner extends StatelessWidget {
  const OfflineBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return ValueListenableBuilder<bool>(
      valueListenable: Api.online,
      builder: (_, online, __) => ValueListenableBuilder<int>(
        valueListenable: Api.pending,
        builder: (_, pending, __) {
          if (online && pending == 0) return const SizedBox.shrink();
          return Container(
            width: double.infinity,
            color: online ? AppColors.warning : AppColors.text,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              Icon(online ? Icons.sync_rounded : Icons.wifi_off_rounded, color: Colors.white, size: 16),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${online ? s.t('online') : s.t('offline')}${pending > 0 ? ' · ${s.t('pending_sync', {'n': pending})}' : ''}',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w700),
                ),
              ),
              if (pending > 0 && online)
                GestureDetector(onTap: () => Api.flush(), child: const Icon(Icons.refresh_rounded, color: Colors.white, size: 18)),
            ]),
          );
        },
      ),
    );
  }
}

/// بوصلة: سهم يشير إلى الهدف (الشمال أعلى الشاشة)
class CompassArrow extends StatelessWidget {
  final int? bearing;
  final double size;
  final Color color;
  const CompassArrow({super.key, required this.bearing, this.size = 120, this.color = AppColors.green});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return SizedBox(
      width: size,
      height: size,
      child: Stack(alignment: Alignment.center, children: [
        Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: Colors.white,
            border: Border.all(color: AppColors.line, width: 2),
          ),
        ),
        Positioned(
          top: 4,
          child: Text(s.t('north'), style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w900, color: AppColors.danger)),
        ),
        if (bearing != null)
          Transform.rotate(
            angle: bearing! * math.pi / 180,
            child: Icon(Icons.navigation_rounded, size: size * 0.6, color: color),
          )
        else
          Icon(Icons.location_searching_rounded, size: size * 0.4, color: AppColors.textFaint),
      ]),
    );
  }
}

void showSnack(BuildContext context, String msg, {Color? color}) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(msg), backgroundColor: color ?? AppColors.green));
}

Future<void> launchMaps(dynamic lat, dynamic lng) async {
  await launchUrl(Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng'), mode: LaunchMode.externalApplication);
}
