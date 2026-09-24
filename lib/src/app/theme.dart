import 'package:flutter/material.dart';

// Same tokens as the web console and docs/prototype.html in nyasmsforward-server.
const _lightScheme = ColorScheme.light(
  primary: Color(0xFF4964D8),
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFEEF1FF),
  onPrimaryContainer: Color(0xFF354FC0),
  // Without these Material falls back to its teal secondary, which showed up on tonal buttons.
  secondary: Color(0xFF4964D8),
  onSecondary: Colors.white,
  secondaryContainer: Color(0xFFE4E9FF),
  onSecondaryContainer: Color(0xFF2B3F9E),
  tertiary: Color(0xFF0E9384),
  surface: Color(0xFFFFFFFF),
  onSurface: Color(0xFF181C23),
  surfaceContainerHighest: Color(0xFFEEF2F8),
  onSurfaceVariant: Color(0xFF667085),
  outline: Color(0xFFCDD6E5),
  outlineVariant: Color(0xFFE1E6F0),
  error: Color(0xFFB42318),
);

const _darkScheme = ColorScheme.dark(
  primary: Color(0xFF91A7FF),
  onPrimary: Color(0xFF0F1319),
  primaryContainer: Color(0xFF202A52),
  onPrimaryContainer: Color(0xFFB0BDFF),
  secondary: Color(0xFF91A7FF),
  onSecondary: Color(0xFF0F1319),
  secondaryContainer: Color(0xFF26315E),
  onSecondaryContainer: Color(0xFFC7D1FF),
  tertiary: Color(0xFF3CCBB8),
  surface: Color(0xFF171C24),
  onSurface: Color(0xFFE8ECF2),
  surfaceContainerHighest: Color(0xFF212936),
  onSurfaceVariant: Color(0xFF93A0B4),
  outline: Color(0xFF3A4556),
  outlineVariant: Color(0xFF2B3441),
  error: Color(0xFFFF8A80),
);

ThemeData _build(ColorScheme scheme, Color background) => ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: background,
      visualDensity: VisualDensity.standard,
      textTheme: TextTheme(
        headlineSmall: TextStyle(fontSize: 24, fontWeight: FontWeight.w700, letterSpacing: -0.4),
        titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, letterSpacing: -0.2),
        titleMedium: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        bodyLarge: TextStyle(fontSize: 15, height: 1.45),
        bodyMedium: TextStyle(fontSize: 14, height: 1.45),
        bodySmall: TextStyle(fontSize: 12, height: 1.45),
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 2,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: scheme.primary,
        centerTitle: false,
        titleTextStyle: TextStyle(color: scheme.onSurface, fontSize: 19, fontWeight: FontWeight.w700, letterSpacing: -0.2),
      ),
      cardTheme: CardThemeData(
        margin: EdgeInsets.zero,
        elevation: 0,
        color: scheme.surface,
        surfaceTintColor: scheme.primary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surface,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(11), borderSide: BorderSide(color: scheme.outlineVariant)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(11), borderSide: BorderSide(color: scheme.outlineVariant)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(11), borderSide: BorderSide(color: scheme.primary, width: 2)),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
          padding: const EdgeInsets.symmetric(horizontal: 18),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(11)),
          side: BorderSide(color: scheme.outline),
          padding: const EdgeInsets.symmetric(horizontal: 16),
        ),
      ),
      listTileTheme: ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        minVerticalPadding: 8,
        selectedTileColor: scheme.primaryContainer,
        selectedColor: scheme.onPrimaryContainer,
      ),
      dividerTheme: DividerThemeData(color: scheme.outlineVariant, space: 1, thickness: 1),
      // Unread counts are information, not errors: brand colour instead of Material's red.
      badgeTheme: BadgeThemeData(backgroundColor: scheme.primary, textColor: scheme.onPrimary),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: BorderSide(color: scheme.outlineVariant),
        backgroundColor: scheme.surface,
        selectedColor: scheme.primaryContainer,
        labelStyle: TextStyle(fontSize: 13, color: scheme.onSurface),
      ),
      snackBarTheme: const SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );

final ThemeData lightTheme = _build(_lightScheme, const Color(0xFFF4F6FB));
final ThemeData darkTheme = _build(_darkScheme, const Color(0xFF0F1319));
