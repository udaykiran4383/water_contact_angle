import 'package:flutter/material.dart';

class AppTheme {
  AppTheme._();

  // Core palette
  static const Color deepNavy     = Color(0xFF0D1B2A);
  static const Color darkBlue     = Color(0xFF1B2838);
  static const Color cardDark     = Color(0xFF1E2D3D);
  static const Color surfaceDark  = Color(0xFF162231);
  static const Color tealAccent   = Color(0xFF00BFA5);
  static const Color cyanLight    = Color(0xFF4DD0E1);
  static const Color amberWarn    = Color(0xFFFFB74D);
  static const Color errorRed     = Color(0xFFEF5350);
  static const Color textPrimary  = Color(0xFFF5F5F5);
  static const Color textSecondary = Color(0xFFB0BEC5);
  static const Color dividerColor = Color(0xFF2A3F52);

  static const Gradient primaryGradient = LinearGradient(
    colors: [Color(0xFF00BFA5), Color(0xFF4DD0E1)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const Gradient backgroundGradient = LinearGradient(
    colors: [deepNavy, Color(0xFF0F2027)],
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
  );

  static ThemeData get darkTheme {
    return ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: deepNavy,
      primaryColor: tealAccent,
      colorScheme: const ColorScheme.dark(
        primary: tealAccent,
        secondary: cyanLight,
        surface: cardDark,
        error: errorRed,
        onPrimary: deepNavy,
        onSecondary: deepNavy,
        onSurface: textPrimary,
        onError: Colors.white,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w700,
          color: textPrimary,
          letterSpacing: 0.5,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      cardTheme: CardThemeData(
        color: cardDark.withValues(alpha: 0.7),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: dividerColor,
        thickness: 1,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: cardDark,
        contentTextStyle: const TextStyle(color: textPrimary),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
