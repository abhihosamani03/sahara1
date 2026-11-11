import 'package:flutter/material.dart';

/// Sahara premium dark theme — ink-and-saffron palette.
/// All colors derive from these tokens; UI code should never hardcode hex values.
class SaharaTheme {
  SaharaTheme._();

  // ── Palette ───────────────────────────────────────────────────────
  static const Color _ink = Color(0xFF0D0F14);
  static const Color _surface = Color(0xFF161922);
  static const Color _surfaceLight = Color(0xFF1E2230);
  static const Color _border = Color(0xFF2A2E3A);
  static const Color _saffron = Color(0xFFF59E0B);
  static const Color _saffronLight = Color(0xFFFBBF24);
  static const Color _saffronDark = Color(0xFFD97706);
  static const Color _red = Color(0xFFEF4444);
  static const Color _green = Color(0xFF22C55E);
  static const Color _textPrimary = Color(0xFFF1F5F9);
  static const Color _textSecondary = Color(0xFF94A3B8);
  static const Color _textMuted = Color(0xFF64748B);

  // ── ThemeData ─────────────────────────────────────────────────────
  static ThemeData get dark {
    final base = ThemeData.dark(useMaterial3: true);

    return base.copyWith(
      scaffoldBackgroundColor: _ink,
      colorScheme: ColorScheme.dark(
        primary: _saffron,
        onPrimary: _ink,
        primaryContainer: _saffronDark,
        secondary: _green,
        onSecondary: _ink,
        surface: _surface,
        onSurface: _textPrimary,
        error: _red,
        outline: _border,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: _surface,
        foregroundColor: _textPrimary,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: _textPrimary,
          letterSpacing: 1.2,
        ),
      ),
      cardTheme: CardThemeData(
        color: _surface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: _border),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: _border,
        thickness: 1,
        space: 1,
      ),
      textTheme: const TextTheme(
        headlineLarge: TextStyle(
          fontSize: 28,
          fontWeight: FontWeight.w800,
          color: _textPrimary,
          letterSpacing: -0.5,
        ),
        headlineMedium: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: _textPrimary,
        ),
        titleLarge: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: _textPrimary,
        ),
        titleMedium: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w600,
          color: _textPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w400,
          color: _textPrimary,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w400,
          color: _textSecondary,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w400,
          color: _textMuted,
        ),
        labelLarge: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: _saffron,
          letterSpacing: 0.8,
        ),
        labelSmall: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: _textMuted,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  // ── Named color accessors (for non-ThemeContext usage) ────────────
  static const Color ink = _ink;
  static const Color surface = _surface;
  static const Color surfaceLight = _surfaceLight;
  static const Color border = _border;
  static const Color saffron = _saffron;
  static const Color saffronLight = _saffronLight;
  static const Color saffronDark = _saffronDark;
  static const Color danger = _red;
  static const Color success = _green;
  static const Color textPrimary = _textPrimary;
  static const Color textSecondary = _textSecondary;
  static const Color textMuted = _textMuted;
}
