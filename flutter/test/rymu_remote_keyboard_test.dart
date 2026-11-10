import 'package:flutter/material.dart';
import 'package:flutter_hbb/rymu_android/remote_keyboard.dart';
import 'package:flutter_hbb/rymu_android/session_bar.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue committed(String text) {
  final value = RymuRemoteKeys.editorValue.text + text;
  return TextEditingValue(
      text: value, selection: TextSelection.collapsed(offset: value.length));
}

void main() {
  test('Shift and Alt apply to the next Tab press only', () {
    final keys = RymuRemoteKeys();
    keys.toggle(RymuModifier.shift);
    final previous = keys.stroke('VK_TAB');
    expect(previous.key, 'VK_TAB');
    expect(previous.modifiers, {RymuModifier.shift});
    expect(keys.selected(RymuModifier.shift), isFalse);

    keys.toggle(RymuModifier.alt);
    final switchWindow = keys.stroke('VK_TAB');
    expect(switchWindow.modifiers, {RymuModifier.alt});
    expect(keys.stroke('VK_TAB').modifiers, isEmpty);
  });

  test('Ctrl and Win use native chords for simple Latin IME commits', () {
    final keys = RymuRemoteKeys()..toggle(RymuModifier.control);
    final copy = keys.commit(committed('c'))! as RymuKeyStroke;
    expect(copy.key, 'VK_C');
    expect(copy.modifiers, {RymuModifier.control});
    expect(keys.commit(committed('c')), isA<RymuCommittedText>());

    keys.toggle(RymuModifier.windows);
    final explorer = keys.commit(committed('e'))! as RymuKeyStroke;
    expect(explorer.key, 'VK_E');
    expect(explorer.modifiers, {RymuModifier.windows});
    expect(keys.stroke('Meta').modifiers, isEmpty);
  });

  test('composition is deferred and non-Latin text is kept intact', () {
    final keys = RymuRemoteKeys()..toggle(RymuModifier.control);
    final value = committed('العربية 👋');
    expect(
      keys.commit(value.copyWith(
          composing: TextRange(start: 1, end: value.text.length))),
      isNull,
    );
    expect(keys.selected(RymuModifier.control), isTrue);
    final result = keys.commit(value)! as RymuCommittedText;
    expect(result.text, 'العربية 👋');
    expect(keys.selected(RymuModifier.control), isFalse);
  });

  test('the scratch editor preserves Backspace, Return and Space', () {
    final keys = RymuRemoteKeys();
    expect(keys.commit(RymuRemoteKeys.editorValue), isNull);
    expect(
        (keys.commit(TextEditingValue.empty)! as RymuKeyStroke).key, 'VK_BACK');
    expect((keys.commit(committed('\n'))! as RymuKeyStroke).key, 'VK_RETURN');
    expect((keys.commit(committed(' '))! as RymuKeyStroke).key, 'VK_SPACE');
    keys.toggle(RymuModifier.alt);
    keys.clear();
    expect(keys.stroke('VK_TAB').modifiers, isEmpty);
  });

  testWidgets('narrow glass dock stays above the IME and keeps text focus',
      (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 660);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetViewInsets);
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final keys = RymuRemoteKeys();
    final sent = <RymuKeyStroke>[];
    var expanded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, update) => Column(children: [
              Expanded(
                child: Align(
                  alignment: Alignment.topCenter,
                  child: TextField(focusNode: focus),
                ),
              ),
              RymuRemoteKeyboard(
                arabic: true,
                expanded: expanded,
                keys: keys,
                onModifier: (modifier) => update(() => keys.toggle(modifier)),
                onKey: (key, modifiers) =>
                    update(() => sent.add(keys.stroke(key, modifiers))),
                onExpand: () => update(() => expanded = !expanded),
                onHide: () {
                  keys.clear();
                  focus.unfocus();
                },
              ),
            ]),
          ),
        ),
      ),
    );
    await tester.showKeyboard(find.byType(TextField));
    tester.view.viewInsets = const FakeViewPadding(bottom: 250);
    await tester.pumpAndSettle();
    expect(tester.testTextInput.isVisible, isTrue);
    expect(tester.getBottomLeft(find.byType(RymuRemoteKeyboard)).dy,
        lessThanOrEqualTo(410));

    await tester.tap(find.text('Ctrl'));
    await tester.tap(find.byTooltip('مفاتيح إضافية'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('السهم الأيسر'));
    await tester.pumpAndSettle();
    expect(sent.single.key, 'VK_LEFT');
    expect(sent.single.modifiers, {RymuModifier.control});
    expect(focus.hasFocus, isTrue);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byTooltip('إخفاء لوحة المفاتيح'));
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isFalse);
    expect(keys.selected(RymuModifier.control), isFalse);
  });

  testWidgets('screen chooser keeps one selection and restores All screens',
      (tester) async {
    Set<int>? result;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
            builder: (context) => RymuSessionDisplayControl(
                  arabic: false,
                  current: 1,
                  count: 3,
                  cycleCount: 3,
                  onNext: () {},
                  onChoose: () async {
                    result = await showModalBottomSheet<Set<int>>(
                      context: context,
                      builder: (_) => const RymuSessionScreensSheet(
                        arabic: false,
                        sizes: [
                          Size(1920, 1080),
                          Size(1080, 1920),
                          Size(2560, 1440)
                        ],
                        current: 0,
                        selected: {0, 1, 2},
                      ),
                    );
                  },
                )),
      ),
    ));
    final control = find.byType(RymuSessionDisplayControl);
    await tester.longPress(control);
    await tester.pumpAndSettle();
    final first = find.widgetWithText(CheckboxListTile, 'Display 1');
    for (final display in ['Display 2', 'Display 3']) {
      final row = find.text(display);
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(first);
    expect(tester.widget<CheckboxListTile>(first).onChanged, isNull);
    final apply = find.text('Apply');
    await tester.ensureVisible(apply);
    await tester.tap(apply);
    await tester.pumpAndSettle();
    expect(result, {0});

    await tester.longPress(control);
    await tester.pumpAndSettle();
    await tester.tap(find.text('All screens'));
    await tester.pumpAndSettle();
    expect(result, isEmpty);
  });
}
