import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// نظام الألوان والطباعة الرسمي لتطبيق "عين الحملة".
/// نفس الألوان المستخدمة في تصاميم التطبيق والموقع ولوحة التحكم،
/// حتى تبقى الهوية البصرية موحّدة عبر كل واجهات المشروع.
class AppColors {
  AppColors._();

  static const Color green = Color(0xFF12332A); // اللون الأساسي الداكن
  static const Color greenSoft = Color(0xFF1E4D3D);
  static const Color gold = Color(0xFFC9A24A); // اللون الذهبي (التمييز)
  static const Color goldDark = Color(0xFFB5761E);
  static const Color background = Color(0xFFFAF7EF); // الخلفية الكريمية
  static const Color surface = Color(0xFFFFFFFF);
  static const Color surfaceAlt = Color(0xFFF3EEDD);
  static const Color line = Color(0xFFE4DCC8);
  static const Color text = Color(0xFF1E1B16);
  static const Color textMuted = Color(0xFF5B564C);
  static const Color textFaint = Color(0xFF9C9585);
  static const Color success = Color(0xFF3F7A57);
  static const Color warning = Color(0xFFB5761E);
  static const Color danger = Color(0xFFB23B2E);
}

class AppTheme {
  AppTheme._();

  static ThemeData light() {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: AppColors.green,
        primary: AppColors.green,
        secondary: AppColors.gold,
        error: AppColors.danger,
        surface: AppColors.surface,
      ),
      scaffoldBackgroundColor: AppColors.background,
      fontFamily: GoogleFonts.tajawal().fontFamily,
      textTheme: GoogleFonts.tajawalTextTheme(),
    );

    return base.copyWith(
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.background,
        foregroundColor: AppColors.text,
        elevation: 0,
        centerTitle: true,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.green,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(52),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.tajawal(fontWeight: FontWeight.w800, fontSize: 14.5),
          elevation: 0,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: AppColors.green,
          minimumSize: const Size.fromHeight(48),
          side: const BorderSide(color: AppColors.gold, width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          textStyle: GoogleFonts.tajawal(fontWeight: FontWeight.w700, fontSize: 13.5),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.line),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.gold, width: 1.6),
        ),
        hintStyle: GoogleFonts.tajawal(color: AppColors.textMuted, fontSize: 13.5),
      ),
      cardTheme: CardThemeData(
        color: Colors.white,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: const BorderSide(color: AppColors.line),
        ),
      ),
      dividerColor: AppColors.line,
    );
  }
}
