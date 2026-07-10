import 'package:flutter/material.dart';

/// FE role theme — "ocean_depths" from theme_config.py:
/// gradient #006D6F (Skobeloff) → #004953 (Deep Jungle Green),
/// accent #006D6F, pressed #005558, badge bg #ecfeff / text #155e63.
/// Headings use Fjalla One (same font file the web app serves).
class AppTheme {
  static const Color primary = Color(0xFF006D6F);
  static const Color gradientFrom = Color(0xFF006D6F);
  static const Color gradientTo = Color(0xFF004953);
  static const Color pressed = Color(0xFF005558);
  static const Color badgeBg = Color(0xFFECFEFF);
  static const Color badgeText = Color(0xFF155E63);

  static const LinearGradient headerGradient = LinearGradient(
    colors: [gradientFrom, gradientTo],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static ThemeData light() {
    final scheme = ColorScheme.fromSeed(
      seedColor: primary,
      primary: primary,
      brightness: Brightness.light,
    );

    final base = ThemeData(colorScheme: scheme, useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: const Color(0xFFF4F6F8),
      appBarTheme: const AppBarTheme(
        backgroundColor: gradientFrom,
        foregroundColor: Colors.white,
        elevation: 0,
        titleTextStyle: TextStyle(
          fontFamily: 'FjallaOne',
          fontSize: 20,
          color: Colors.white,
        ),
      ),
      cardTheme: CardTheme(
        elevation: 1.5,
        // Echo the web app's rounded-2xl cards.
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        color: Colors.white,
        surfaceTintColor: Colors.white,
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          side: const BorderSide(color: primary),
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: Colors.grey.shade300),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: primary, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// Heading style — Fjalla One, like the web app's display font.
  static const TextStyle heading = TextStyle(
    fontFamily: 'FjallaOne',
    fontSize: 18,
    color: Color(0xFF1F2937),
  );
}
