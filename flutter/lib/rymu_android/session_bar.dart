import 'package:flutter/material.dart';

import '../rymu/glass.dart';
import 'appearance.dart';

class RymuAndroidSessionBar extends StatelessWidget {
  const RymuAndroidSessionBar({
    super.key,
    required this.name,
    required this.status,
    required this.arabic,
    required this.displayControl,
    required this.onText,
    required this.onSettings,
    required this.onDisconnect,
  });

  static const maxWidth = 560.0;

  final String name;
  final String status;
  final bool arabic;
  final Widget displayControl;
  final VoidCallback? onText;
  final VoidCallback? onSettings;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) {
    final colors = RymuGlassPalette.of(context);
    return Directionality(
      textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
      child: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(8, 0, 8, 6),
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: 1,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: maxWidth),
            child: RymuGlass(
              radius: 18,
              padding: const EdgeInsetsDirectional.fromSTEB(12, 2, 4, 2),
              child: LayoutBuilder(builder: (context, constraints) {
                final textLabel =
                    rymuCopy(arabic, 'Open keyboard', 'إظهار لوحة المفاتيح');
                return Row(children: [
                  displayControl,
                  const SizedBox(width: 6),
                  Expanded(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.ink,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(color: colors.muted),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (constraints.maxWidth >= 350)
                    TextButton.icon(
                      onPressed: onText,
                      icon: const Icon(Icons.keyboard_outlined, size: 20),
                      label: Text(rymuCopy(arabic, 'Text', 'نص')),
                    )
                  else
                    IconButton(
                      tooltip: textLabel,
                      onPressed: onText,
                      icon: const Icon(Icons.keyboard_outlined, size: 20),
                    ),
                  IconButton(
                    tooltip:
                        rymuCopy(arabic, 'Session settings', 'إعدادات الجلسة'),
                    onPressed: onSettings,
                    icon: const Icon(Icons.tune_rounded),
                  ),
                  IconButton(
                    tooltip: rymuCopy(arabic, 'Disconnect', 'قطع الاتصال'),
                    icon: const Icon(Icons.call_end_outlined),
                    onPressed: onDisconnect,
                  ),
                ]);
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class RymuSessionDisplayControl extends StatelessWidget {
  const RymuSessionDisplayControl({
    super.key,
    required this.arabic,
    required this.current,
    required this.count,
    required this.cycleCount,
    required this.onNext,
    required this.onChoose,
    this.overview = false,
  });

  final bool arabic;
  final int current;
  final int count;
  final int cycleCount;
  final VoidCallback? onNext;
  final VoidCallback? onChoose;
  final bool overview;

  @override
  Widget build(BuildContext context) {
    final colors = RymuGlassPalette.of(context);
    final next = count > 1 ? onNext : null;
    final choose = count > 0 ? onChoose : null;
    final label = count == 0
        ? rymuCopy(
            arabic, 'Waiting for the remote display', 'بانتظار الشاشة البعيدة')
        : overview
            ? rymuCopy(arabic, 'All $count displays', 'كل الشاشات ($count)')
            : rymuCopy(arabic, 'Display $current of $count',
                'الشاشة $current من $count');
    final subset = cycleCount < count
        ? rymuCopy(arabic, ' $cycleCount in the cycle.',
            ' عدد الشاشات في التبديل $cycleCount.')
        : '';
    final action = next != null
        ? rymuCopy(
            arabic,
            'Tap for the next display. Hold to choose session screens.',
            'اضغط للشاشة التالية. اضغط مطوّلاً لاختيار شاشات الجلسة.')
        : rymuCopy(arabic, 'Choose session screens.', 'اختيار شاشات الجلسة.');
    final face = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
            overview
                ? Icons.view_column_outlined
                : Icons.desktop_windows_outlined,
            size: 16),
        const SizedBox(width: 4),
        Text(
            count == 0
                ? '–'
                : overview
                    ? rymuCopy(arabic, 'All', 'الكل')
                    : '$current/$count',
            textDirection: TextDirection.ltr,
            textScaler:
                MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3),
            style: Theme.of(context).textTheme.labelMedium),
      ],
    );
    if (next == null && choose == null) {
      return Semantics(
        label: label,
        child: ExcludeSemantics(
          child: IconTheme.merge(
            data: IconThemeData(color: colors.muted),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: face,
            ),
          ),
        ),
      );
    }
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Semantics(
        label: '$label.$subset $action',
        child: Tooltip(
          message: '$label.$subset $action',
          excludeFromSemantics: true,
          triggerMode: TooltipTriggerMode.manual,
          child: TextButton(
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 44),
              padding: const EdgeInsets.symmetric(horizontal: 8),
              foregroundColor: colors.ink,
              backgroundColor: colors.tint,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            onPressed: next ?? choose,
            onLongPress: next == null ? null : choose,
            child: ExcludeSemantics(child: face),
          ),
        ),
      ),
      if (choose != null)
        IconButton(
          tooltip: rymuCopy(arabic, 'Display options', 'خيارات الشاشات'),
          onPressed: choose,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 44),
          padding: EdgeInsets.zero,
          icon: const Icon(Icons.expand_more_rounded, size: 18),
        )
    ]);
  }
}

class RymuSessionScreensSheet extends StatefulWidget {
  const RymuSessionScreensSheet({
    super.key,
    required this.arabic,
    required this.sizes,
    required this.current,
    required this.selected,
    this.onOverview,
    this.overviewActive = false,
    this.onFit,
    this.onZoom,
  });

  final bool arabic;
  final List<Size> sizes;
  final int current;
  final Set<int> selected;
  final VoidCallback? onOverview;
  final bool overviewActive;
  final VoidCallback? onFit;
  final ValueChanged<double>? onZoom;

  @override
  State<RymuSessionScreensSheet> createState() =>
      _RymuSessionScreensSheetState();
}

class _RymuSessionScreensSheetState extends State<RymuSessionScreensSheet> {
  late final _draft = widget.selected.toSet();

  String t(String english, String arabic) =>
      rymuCopy(widget.arabic, english, arabic);

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: widget.arabic ? TextDirection.rtl : TextDirection.ltr,
        child: SafeArea(
          top: false,
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            children: [
              ListTile(
                title: Text(t('Session screens', 'شاشات الجلسة'),
                    style: Theme.of(context).textTheme.titleLarge),
                subtitle: Text(t(
                    'Choose which screens the display button cycles through.',
                    'اختر الشاشات التي ينتقل بينها زر التبديل.')),
              ),
              if (widget.onOverview != null)
                ListTile(
                  leading: const Icon(Icons.view_column_outlined),
                  title: Text(t(
                      'All displays side by side', 'كل الشاشات جنبًا إلى جنب')),
                  subtitle:
                      Text(t('Live overview · Pro', 'عرض مباشر شامل · Pro')),
                  trailing: widget.overviewActive
                      ? const Icon(Icons.check_rounded)
                      : null,
                  onTap: widget.onOverview,
                ),
              if (widget.onFit != null)
                ListTile(
                  leading: const Icon(Icons.fit_screen_rounded),
                  title: Text(t('Fit to view', 'ملاءمة العرض')),
                  subtitle: Text(t('Pinch to zoom. Move two fingers to pan.',
                      'باعد إصبعين للتكبير، وحركهما لتحريك العرض.')),
                  onTap: widget.onFit,
                ),
              if (widget.onZoom != null)
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  TextButton.icon(
                      onPressed: () => widget.onZoom!(.8),
                      icon: const Icon(Icons.remove_rounded),
                      label: Text(t('Zoom out', 'تصغير'))),
                  const SizedBox(width: 12),
                  TextButton.icon(
                      onPressed: () => widget.onZoom!(1.25),
                      icon: const Icon(Icons.add_rounded),
                      label: Text(t('Zoom in', 'تكبير'))),
                ]),
              ListTile(
                leading: const Icon(Icons.monitor_rounded),
                title: Text(t('All screens', 'كل الشاشات')),
                onTap: () => Navigator.pop(context, const <int>{}),
              ),
              for (var i = 0; i < widget.sizes.length; i++)
                CheckboxListTile(
                  title: Text(t('Display ${i + 1}', 'الشاشة ${i + 1}')),
                  subtitle: Text(
                    '${widget.sizes[i].width.toInt()} × ${widget.sizes[i].height.toInt()}',
                    textDirection: TextDirection.ltr,
                    textAlign: widget.arabic ? TextAlign.right : TextAlign.left,
                  ),
                  secondary: i == widget.current
                      ? const Icon(Icons.desktop_windows_rounded)
                      : null,
                  value: _draft.contains(i),
                  onChanged: _draft.length == 1 && _draft.contains(i)
                      ? null
                      : (value) => setState(() {
                            if (value == true) {
                              _draft.add(i);
                            } else {
                              _draft.remove(i);
                            }
                          }),
                ),
              const SizedBox(height: 8),
              FilledButton(
                onPressed: () => Navigator.pop(context, _draft),
                child: Text(t('Apply', 'تطبيق')),
              ),
            ],
          ),
        ),
      );
}

class RymuInputModeSelector extends StatelessWidget {
  const RymuInputModeSelector(
      {super.key,
      required this.arabic,
      required this.direct,
      required this.onChanged});
  final bool arabic;
  final bool direct;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => Column(children: [
        RadioListTile<bool>(
          title: Text(rymuCopy(arabic, 'Direct touch', 'اللمس المباشر')),
          subtitle: Text(rymuCopy(
              arabic,
              'Tap the item you want on the remote screen.',
              'المس العنصر المطلوب مباشرة على الشاشة البعيدة.')),
          value: true,
          groupValue: direct,
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
        RadioListTile<bool>(
          title:
              Text(rymuCopy(arabic, 'Mouse / trackpad', 'الماوس / لوحة اللمس')),
          subtitle: Text(rymuCopy(
              arabic,
              'Move the pointer from anywhere in the viewing area, including the margins.',
              'حرّك المؤشر من أي مكان في مساحة العرض، بما فيها الهوامش.')),
          value: false,
          groupValue: direct,
          onChanged: (value) {
            if (value != null) onChanged(value);
          },
        ),
        Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
                rymuCopy(
                    arabic,
                    'Tap: left click · Hold: right click · Double tap and move: drag · Two fingers: zoom and pan · Three fingers: scroll',
                    'نقرة: زر أيسر · ضغط مطوّل: زر أيمن · نقرتان ثم حركة: سحب · إصبعان: تكبير وتحريك · ثلاثة أصابع: تمرير'),
                style: Theme.of(context).textTheme.bodySmall)),
      ]);
}
