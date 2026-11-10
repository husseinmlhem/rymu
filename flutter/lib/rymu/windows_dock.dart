import 'package:flutter/material.dart';

import 'glass.dart';

class RymuWindowsDock extends StatelessWidget {
  const RymuWindowsDock({
    super.key,
    required this.selected,
    required this.signedIn,
    required this.arabic,
    required this.onSelect,
  });

  final int selected;
  final bool signedIn;
  final bool arabic;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final palette = RymuGlassPalette.of(context);
    final current = !signedIn && selected == 1 ? 0 : selected;

    Widget destination(int index, IconData icon, String label) {
      final active = index == current;
      return Expanded(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 2),
          child: Semantics(
            selected: active,
            child: TextButton(
              onPressed: () => onSelect(index),
              style: TextButton.styleFrom(
                foregroundColor: active ? palette.ink : palette.muted,
                backgroundColor: active ? palette.tint : Colors.transparent,
                overlayColor: palette.ink,
                minimumSize: const Size(0, 56),
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ).copyWith(
                side: WidgetStateProperty.resolveWith((states) {
                  if (states.contains(WidgetState.focused)) {
                    return BorderSide(color: palette.ink);
                  }
                  return BorderSide(
                    color: active ? palette.line : Colors.transparent,
                  );
                }),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 22),
                  const SizedBox(height: 3),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.1,
                      fontWeight: active ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: active ? palette.ink : Colors.transparent,
                      shape: BoxShape.circle,
                    ),
                    child: const SizedBox.square(dimension: 4),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Align(
      alignment: Alignment.bottomCenter,
      heightFactor: 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: signedIn ? 344 : 304),
          child: Directionality(
            textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
            child: RymuGlass(
              radius: 24,
              blur: true,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
              child: Row(
                children: [
                  destination(0, Icons.devices_outlined,
                      arabic ? 'الأجهزة' : 'Devices'),
                  if (signedIn)
                    destination(
                        1, Icons.folder_outlined, arabic ? 'الملفات' : 'Files'),
                  destination(2, Icons.settings_outlined,
                      arabic ? 'الإعدادات' : 'Settings'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
