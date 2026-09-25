import 'package:flutter/material.dart';

class AppTheme {
  // ═══════════════════════════════════════════════════════════════════
  // MUSI — Warm Amber/Gold on Deep Charcoal Dark Theme
  //
  // Palette inspired by warm studio lighting — glowing amber against
  // deep obsidian blacks. Like a vinyl record player in a darkened room.
  // ═══════════════════════════════════════════════════════════════════

  // Backgrounds — very dark, slightly warm charcoal
  static const Color background = Color(0xFF0E0B07); // Deepest warm black
  static const Color surface = Color(0xFF161209); // Warm dark surface
  static const Color surfaceLight = Color(0xFF251D0F); // Lifted warm card
  static const Color surfaceCard = Color(0xFF1C1509); // Card background
  static const Color borderColor = Color(0xFF2E2410); // Warm border

  // Brand — Electric Amber / Golden Yellow
  static const Color primary = Color(0xFFF59E0B); // Vivid amber
  static const Color primaryLight = Color(0xFFFBBF24); // Gold
  static const Color accent = Color(0xFFFBBF24); // Gold accent
  static const Color accentVibrant = Color(0xFFD97706); // Deep amber
  static const Color accentOrange = Color(0xFFEA580C); // Burnt orange glow

  // Status
  static const Color youtubeRed = Color(0xFFEF4444);
  static const Color error = Color(0xFFEF4444);
  static const Color success = Color(0xFF34D399); // Teal for positive

  // Text
  static const Color textPrimary = Color(0xFFFFF8F0); // Warm white
  static const Color textSecondary = Color(0xFFB8A790); // Warm silver
  static const Color textMuted = Color(0xFF7C6A52); // Warm muted

  static ThemeData get darkTheme {
    final colorScheme = const ColorScheme.dark(
      primary: primary,
      secondary: primaryLight,
      surface: surface,
      error: error,
      onPrimary: Color(0xFF0E0B07),
      onSecondary: Color(0xFF0E0B07),
      onSurface: textPrimary,
      onError: Colors.white,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: background,
      canvasColor: surface,
      cardColor: surfaceCard,
      fontFamily: null,
      appBarTheme: const AppBarTheme(
        backgroundColor: background,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.bold,
          letterSpacing: -0.5,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: primaryLight,
        unselectedItemColor: textMuted,
        type: BottomNavigationBarType.fixed,
        elevation: 12,
        selectedLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
        unselectedLabelStyle: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
      ),
      cardTheme: CardThemeData(
        color: surfaceCard,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: borderColor, width: 0.8),
        ),
      ),
      sliderTheme: SliderThemeData(
        activeTrackColor: primary,
        inactiveTrackColor: surfaceLight,
        thumbColor: primaryLight,
        overlayColor: primary.withValues(alpha: 0.2),
        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
        trackHeight: 3,
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: const Color(0xFF0E0B07),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
      ),
      tabBarTheme: const TabBarThemeData(
        indicatorColor: primary,
        labelColor: primary,
        unselectedLabelColor: textMuted,
        indicatorSize: TabBarIndicatorSize.label,
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: surfaceLight,
        contentTextStyle: const TextStyle(color: textPrimary, fontSize: 13),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: borderColor, width: 0.8),
        ),
        behavior: SnackBarBehavior.floating,
      ),
      iconTheme: const IconThemeData(color: textPrimary),
      dividerColor: borderColor,
      listTileTheme: const ListTileThemeData(
        iconColor: textSecondary,
        textColor: textPrimary,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surfaceCard,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
          side: const BorderSide(color: borderColor),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: primary),
      ),
    );
  }
}
