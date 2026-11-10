import 'package:flutter/material.dart';

import '../rymu/glass.dart';
import 'appearance.dart';
import 'session_bar.dart';

enum RymuModifier { shift, control, alt, windows }

sealed class RymuKeyboardInput {
  const RymuKeyboardInput();
}

class RymuKeyStroke extends RymuKeyboardInput {
  const RymuKeyStroke(this.key, this.modifiers);

  final String key;
  final Set<RymuModifier> modifiers;
}

class RymuCommittedText extends RymuKeyboardInput {
  const RymuCommittedText(this.text);

  final String text;
}

/// Keeps touch modifiers local until the next complete key stroke.
class RymuRemoteKeys {
  // A hidden placeholder keeps Backspace available in Android's text editor.
  static const _placeholder = '\u200b';
  static const editorValue = TextEditingValue(
      text: _placeholder, selection: TextSelection.collapsed(offset: 1));
  static final _shortcutLetter = RegExp(r'^[a-zA-Z0-9]$');

  final _pending = <RymuModifier>{};

  bool selected(RymuModifier modifier) => _pending.contains(modifier);

  void toggle(RymuModifier modifier) {
    if (!_pending.remove(modifier)) _pending.add(modifier);
  }

  void clear() => _pending.clear();

  RymuKeyStroke stroke(String key, [Set<RymuModifier> extra = const {}]) {
    final modifiers = {..._pending, ...extra};
    clear();
    return RymuKeyStroke(key, modifiers);
  }

  RymuKeyboardInput? commit(TextEditingValue value) {
    if ((value.isComposingRangeValid && !value.composing.isCollapsed) ||
        value.text == _placeholder) {
      return null;
    }
    final text = value.text.startsWith(_placeholder)
        ? value.text.substring(_placeholder.length)
        : value.text;
    final key = switch (text) {
      '' => 'VK_BACK',
      '\n' => 'VK_RETURN',
      '\t' => 'VK_TAB',
      ' ' => 'VK_SPACE',
      _ => _pending.isNotEmpty && _shortcutLetter.hasMatch(text)
          ? 'VK_${text.toUpperCase()}'
          : null,
    };
    if (key != null) return stroke(key);
    clear();
    return RymuCommittedText(text);
  }
}

class RymuRemoteKeyboard extends StatelessWidget {
  const RymuRemoteKeyboard({
    super.key,
    required this.arabic,
    required this.expanded,
    required this.keys,
    required this.onModifier,
    required this.onKey,
    required this.onExpand,
    required this.onHide,
    this.displayControl,
  });

  final bool arabic;
  final bool expanded;
  final RymuRemoteKeys keys;
  final ValueChanged<RymuModifier> onModifier;
  final void Function(String, Set<RymuModifier>) onKey;
  final VoidCallback onExpand;
  final VoidCallback onHide;
  final Widget? displayControl;

  static const rowHeight = 48.0;
  static const maxWidth = RymuAndroidSessionBar.maxWidth;

  String _text(String english, String arabicText) =>
      rymuCopy(arabic, english, arabicText);

  @override
  Widget build(BuildContext context) {
    final colors = RymuGlassPalette.of(context);
    final keyLabelStyle = Theme.of(context)
        .textTheme
        .labelLarge
        ?.copyWith(fontSize: 12, fontWeight: FontWeight.w600);

    Widget keyButton(String label, VoidCallback press,
        {bool? selected, IconData? icon, String? tooltip}) {
      return Semantics(
        selected: selected,
        child: Tooltip(
          message: tooltip ?? label,
          child: TextButton(
            style: TextButton.styleFrom(
              foregroundColor: selected == true ? colors.onAction : colors.ink,
              backgroundColor:
                  selected == true ? colors.action : Colors.transparent,
              minimumSize: const Size(44, rowHeight - 4),
              padding: const EdgeInsets.symmetric(horizontal: 6),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              textStyle: keyLabelStyle,
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: press,
            child: icon == null
                ? Text(label, maxLines: 1, overflow: TextOverflow.ellipsis)
                : Icon(icon, size: 19, semanticLabel: tooltip ?? label),
          ),
        ),
      );
    }

    Widget key(String label, String nativeKey,
            {IconData? icon,
            String? tooltip,
            Set<RymuModifier> modifiers = const {}}) =>
        keyButton(label, () => onKey(nativeKey, modifiers),
            icon: icon, tooltip: tooltip);

    Widget modifier(String label, RymuModifier modifier) =>
        keyButton(label, () => onModifier(modifier),
            selected: keys.selected(modifier));

    final escape = key('Esc', 'VK_ESCAPE');
    final arrows = [
      key('Left', 'VK_LEFT',
          icon: Icons.chevron_left,
          tooltip: _text('Left arrow', 'السهم الأيسر')),
      key('Up', 'VK_UP',
          icon: Icons.expand_less, tooltip: _text('Up arrow', 'السهم للأعلى')),
      key('Down', 'VK_DOWN',
          icon: Icons.expand_more,
          tooltip: _text('Down arrow', 'السهم للأسفل')),
      key('Right', 'VK_RIGHT',
          icon: Icons.chevron_right,
          tooltip: _text('Right arrow', 'السهم الأيمن')),
    ];
    final delete = key('Del', 'VK_DELETE');
    final clipboard = [
      key('Ctrl+C', 'VK_C', modifiers: const {RymuModifier.control}),
      key('Ctrl+V', 'VK_V', modifiers: const {RymuModifier.control}),
    ];

    // The Windows key order stays consistent with a physical keyboard.
    return TextFieldTapRegion(
      child: ExcludeFocus(
        child: Directionality(
          textDirection: TextDirection.ltr,
          child: SafeArea(
            top: false,
            bottom: false,
            minimum: const EdgeInsets.symmetric(horizontal: 4),
            child: Align(
              alignment: Alignment.bottomCenter,
              heightFactor: 1,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: maxWidth),
                child: RymuGlass(
                  radius: 16,
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: SizedBox(
                    height: rowHeight,
                    child: LayoutBuilder(builder: (context, constraints) {
                      final width = constraints.maxWidth;
                      return Row(children: [
                        if (!arabic && displayControl != null) displayControl!,
                        Expanded(
                          child: SingleChildScrollView(
                            key: ValueKey(expanded),
                            scrollDirection: Axis.horizontal,
                            child: Row(children: [
                              if (!expanded) ...[
                                modifier('Shift', RymuModifier.shift),
                                modifier('Ctrl', RymuModifier.control),
                                modifier('Alt', RymuModifier.alt),
                                modifier('Win', RymuModifier.windows),
                                key('Tab', 'VK_TAB'),
                                if (width >= 468) escape,
                                if (width >= 532) ...arrows,
                                if (width >= 578) delete,
                                if (width >= 702) ...clipboard,
                              ] else ...[
                                escape,
                                ...arrows,
                                delete,
                                key('Backspace', 'VK_BACK',
                                    icon: Icons.backspace_outlined,
                                    tooltip: _text('Backspace', 'حذف للخلف')),
                                ...clipboard,
                                key('Home', 'VK_HOME'),
                                key('End', 'VK_END'),
                                key('PgUp', 'VK_PRIOR'),
                                key('PgDn', 'VK_NEXT'),
                                key('Start', 'Meta',
                                    tooltip:
                                        _text('Windows key', 'مفتاح ويندوز')),
                                for (var index = 1; index <= 12; index++)
                                  key('F$index', 'VK_F$index'),
                              ],
                            ]),
                          ),
                        ),
                        keyButton('More', onExpand,
                            icon: expanded
                                ? Icons.keyboard_command_key
                                : Icons.more_horiz,
                            selected: expanded,
                            tooltip: expanded
                                ? _text('Main keys', 'المفاتيح الرئيسية')
                                : _text('More keys', 'مفاتيح إضافية')),
                        keyButton('Hide', onHide,
                            icon: Icons.keyboard_hide_outlined,
                            tooltip:
                                _text('Hide keyboard', 'إخفاء لوحة المفاتيح')),
                        if (arabic && displayControl != null) displayControl!,
                      ]);
                    }),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
