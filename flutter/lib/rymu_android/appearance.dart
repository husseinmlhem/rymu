import 'package:flutter/material.dart';

import '../rymu/glass.dart';

String rymuCopy(bool arabic, String english, String arabicText) =>
    arabic ? arabicText : english;

ThemeData rymuAndroidTheme(Brightness brightness) {
  final palette = RymuGlassPalette(brightness);
  final surface = palette.surface.withAlpha(255);
  final line = Color.alphaBlend(palette.line, surface);
  final field = OutlineInputBorder(
    borderRadius: BorderRadius.circular(12),
    borderSide: BorderSide(color: line),
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.black,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
    ).copyWith(
      surface: surface,
      surfaceTint: Colors.transparent,
      onSurface: palette.ink,
      onSurfaceVariant: palette.muted,
      outlineVariant: line,
      primary: palette.action,
      onPrimary: palette.onAction,
      secondaryContainer: palette.tint,
      onSecondaryContainer: palette.ink,
    ),
    scaffoldBackgroundColor: palette.canvas,
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      indicatorColor: palette.tint,
      elevation: 0,
      height: 64,
    ),
    dialogTheme: DialogTheme(
      backgroundColor: surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: field,
      enabledBorder: field,
      filled: true,
      fillColor: palette.tint,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(48, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    ),
  );
}
