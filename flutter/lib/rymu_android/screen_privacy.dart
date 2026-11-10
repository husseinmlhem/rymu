import 'package:flutter/material.dart';

import 'appearance.dart';

const rymuPrivacyOverlay = 'rymu_privacy_overlay';

class RymuScreenPrivacyTile extends StatefulWidget {
  const RymuScreenPrivacyTile({
    super.key,
    required this.arabic,
    required this.active,
    required this.available,
    required this.onChanged,
  });

  final bool arabic;
  final bool active;
  final bool available;
  final Future<bool> Function(bool enabled) onChanged;

  @override
  State<RymuScreenPrivacyTile> createState() => _RymuScreenPrivacyTileState();
}

class _RymuScreenPrivacyTileState extends State<RymuScreenPrivacyTile> {
  bool _pending = false;
  bool _failed = false;

  String t(String english, String arabic) =>
      rymuCopy(widget.arabic, english, arabic);

  @override
  void didUpdateWidget(covariant RymuScreenPrivacyTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.active != widget.active) _failed = false;
  }

  Future<void> _change(bool requested) async {
    if (_pending) return;
    setState(() {
      _pending = true;
      _failed = false;
    });
    var failed = false;
    try {
      failed = await widget.onChanged(requested) != requested;
    } catch (_) {
      failed = true;
    }
    if (mounted) {
      setState(() {
        _pending = false;
        _failed = failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) => SwitchListTile(
        title: Text(t('Screen privacy', 'خصوصية الشاشة')),
        secondary: _pending
            ? const SizedBox.square(
                dimension: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                widget.active ? Icons.privacy_tip : Icons.privacy_tip_outlined),
        subtitle: Semantics(
          liveRegion: true,
          child: Text(_pending
              ? t('Waiting for the computer to confirm…',
                  'بانتظار تأكيد الكمبيوتر…')
              : _failed
                  ? widget.active
                      ? t('Restoring the screens was not confirmed. Disconnect to restore them.',
                          'لم يتأكد إظهار الشاشات. افصل الاتصال لاستعادتها.')
                      : t('Screen hiding was not confirmed. Do not start private work.',
                          'لم يتأكد حجب الشاشات. لا تبدأ العمل الخاص.')
                  : widget.active
                      ? t('All office screens are hidden. They return when you disconnect. If the private session ends, connect again and enable privacy before continuing.',
                          'كل شاشات المكتب محجوبة. تعود عند فصل الاتصال. إذا انتهت الجلسة الخاصة، اتصل مجددًا وفعّل الخصوصية قبل المتابعة.')
                      : widget.available
                          ? t('Hide all office screens, including excluded screens. A local Stop shortcut stays visible. Requires an unlocked Windows desktop; lock, administrator prompts, display changes or capture loss end the connection.',
                              'احجب كل شاشات المكتب، حتى المستبعدة من التنقّل. يظهر اختصار إيقاف محلي. تعمل داخل جلسة ويندوز المفتوحة؛ القفل أو مطالبة المسؤول أو تغيّر الشاشات أو فقد الالتقاط ينهي الاتصال.')
                          : t('Requires a supported Windows host and permission to control it.',
                              'تتطلب مضيف ويندوز مدعومًا وصلاحية التحكم به.')),
        ),
        value: widget.active,
        onChanged:
            _pending || (!widget.available && !widget.active) ? null : _change,
      );
}

class RymuScreenPrivacyStatus extends StatelessWidget {
  const RymuScreenPrivacyStatus({
    super.key,
    required this.arabic,
    required this.pending,
    required this.onDisconnect,
  });

  final bool arabic;
  final bool pending;
  final VoidCallback onDisconnect;

  @override
  Widget build(BuildContext context) => Directionality(
        textDirection: arabic ? TextDirection.rtl : TextDirection.ltr,
        child: SafeArea(
          bottom: false,
          top: false,
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(12, 2, 4, 2),
            child: Row(children: [
              Icon(pending ? Icons.hourglass_top : Icons.privacy_tip_outlined,
                  size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  liveRegion: true,
                  child: Text(
                    pending
                        ? rymuCopy(arabic, 'Confirming screen privacy…',
                            'جارٍ تأكيد خصوصية الشاشة…')
                        : rymuCopy(arabic, 'Office screens hidden',
                            'شاشات المكتب محجوبة'),
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                ),
              ),
              IconButton(
                tooltip: rymuCopy(arabic, 'Disconnect', 'قطع الاتصال'),
                onPressed: onDisconnect,
                icon: const Icon(Icons.call_end_outlined),
              ),
            ]),
          ),
        ),
      );
}
