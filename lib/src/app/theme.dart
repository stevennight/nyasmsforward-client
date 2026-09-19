import 'package:flutter/material.dart';

// Same tokens as the web console and docs/prototype.html in nyasmsforward-server.
const _lightScheme = ColorScheme.light(
  primary: Color(0xFF2563EB),
  onPrimary: Colors.white,
  primaryContainer: Color(0xFFEFF6FF),
  onPrimaryContainer: Color(0xFF1D4ED8),
  surface: Color(0xFFFFFFFF),
  onSurface: Color(0xFF181C23),
  surfaceContainerHighest: Color(0xFFF2F5F9),
  onSurfaceVariant: Color(0xFF667085),
  outline: Color(0xFFCBD5E1),
  outlineVariant: Color(0xFFDDE3EB),
  error: Color(0xFFB42318),
);

const _darkScheme = ColorScheme.dark(
  primary: Color(0xFF4F8BFF),
  onPrimary: Color(0xFF0F1319),
  primaryContainer: Color(0xFF1A2740),
  onPrimaryContainer: Color(0xFF6B9DFF),
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
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        isDense: true,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(44),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
      ),
    );

final ThemeData lightTheme = _build(_lightScheme, const Color(0xFFF6F7F9));
final ThemeData darkTheme = _build(_darkScheme, const Color(0xFF0F1319));
