import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

class RymuGlassPalette {
  const RymuGlassPalette(this.brightness);

  factory RymuGlassPalette.of(BuildContext context) =>
      RymuGlassPalette(Theme.of(context).brightness);

  final Brightness brightness;
  bool get _dark => brightness == Brightness.dark;

  Color get canvas => _dark ? const Color(0xff111111) : const Color(0xfff3f3f3);
  Color get surface =>
      _dark ? const Color(0xed222222) : const Color(0xe6ffffff);
  Color get line => _dark ? const Color(0x25ffffff) : const Color(0x17000000);
  Color get ink => _dark ? const Color(0xfff6f6f6) : const Color(0xff171717);
  Color get muted => _dark ? const Color(0xffb8b8b8) : const Color(0xff5d5d5d);
  Color get action => _dark ? const Color(0xfff5f5f5) : const Color(0xff191919);
  Color get onAction => _dark ? const Color(0xff151515) : Colors.white;
  Color get tint => _dark ? const Color(0xff343434) : const Color(0xffeaeaea);
}

class RymuGlass extends StatelessWidget {
  const RymuGlass({
    super.key,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.radius = 20,
    this.blur = false,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final bool blur;

  @override
  Widget build(BuildContext context) {
    final palette = RymuGlassPalette.of(context);
    final corners = BorderRadius.circular(radius);
    final dark = palette.brightness == Brightness.dark;
    final surface = DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: corners,
        border: Border.all(color: palette.line),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            dark ? const Color(0xe63a3a3a) : const Color(0xfbffffff),
            palette.surface,
          ],
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: Padding(padding: padding, child: child),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(borderRadius: corners, boxShadow: [
        BoxShadow(
          color: dark ? const Color(0x35000000) : const Color(0x10000000),
          blurRadius: 20,
          offset: const Offset(0, 6),
        ),
      ]),
      child: blur
          ? ClipRRect(
              borderRadius: corners,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                child: surface,
              ),
            )
          : surface,
    );
  }
}
