import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart' as engine;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';
import 'package:window_manager/window_manager.dart';

import 'glass.dart';
import 'attribution.dart';
import 'native_bridge.dart';
import 'session_language.dart';
import 'startup_mark.dart';
import 'windows_account.dart';
import 'windows_dock.dart';
import 'windows_packaged_startup.dart';
import 'windows_tray.dart';

const _refreshInterval = Duration(seconds: 20);
const _hostStartupDelays = [
  Duration(seconds: 2),
  Duration(seconds: 4),
  Duration(seconds: 8),
  Duration(seconds: 16),
];

class RymuWindowsHome extends StatefulWidget {
  const RymuWindowsHome({super.key, this.createAccount = WindowsAccount.new});

  final WindowsAccount Function() createAccount;

  @override
  State<RymuWindowsHome> createState() => _RymuWindowsHomeState();
}

class _RymuWindowsHomeState extends State<RymuWindowsHome> with WindowListener {
  WindowsAccount? _account;
  List<Map<String, dynamic>> _devices = [];
  late final TextEditingController _search = TextEditingController()
    ..addListener(() {
      if (_active) setState(() {});
    });
  Timer? _poll;
  Completer<void>? _backgroundOperation;
  bool _busy = false, _hosting = false, _viewOnly = false, _ar = false;
  bool _hostRequested = false, _waitingForBrowser = false;
  bool _closing = false;
  bool _startupBusy = false, _startupError = false;
  PackagedStartupState? _startupState;
  int _section = 0, _hostRevision = 0;
  int _hostRetry = 0;
  DateTime? _lastHeartbeat;
  String? _error, _browserCode, _hostingIssue;

  bool get _wantsHosting => _hostRequested || _account?.autoHost == true;
  bool get _hostReady => _hosting && _lastHeartbeat != null;
  bool get _active => mounted && !_closing;

  String t(String en, String ar) => _ar ? ar : en;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    WindowsTray.onQuit(_quit);
    _initialize();
    unawaited(_updateTray());
  }

  void _initialize() {
    try {
      final account = widget.createAccount();
      _account = account;
      _ar = account.localeSet
          ? account.arabic
          : PlatformDispatcher.instance.locale.languageCode == 'ar';
      if (account.packagedWindows) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_refreshPackagedStartup());
        });
      }
      String? startupError;
      try {
        account.ensureAutomaticHosting();
      } on ControlError catch (error) {
        startupError = error.code;
      }
      if (account.signedIn) {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!_active) return;
          await _run(_refresh, background: true);
          if (_active && startupError != null) {
            setState(() => _error = startupError);
          }
        });
      }
    } catch (error) {
      _error =
          error is ControlError ? error.code : 'local_credentials_unavailable';
    }
  }

  @override
  void onWindowFocus() {
    if (_account?.packagedWindows == true) {
      unawaited(_refreshPackagedStartup());
    }
  }

  Future<void> _refreshPackagedStartup({bool? enabled}) async {
    if (!_active || _startupBusy || _account?.packagedWindows != true) return;
    setState(() {
      _startupBusy = true;
      _startupError = false;
    });
    try {
      final state = enabled == null
          ? await WindowsPackagedStartup.query()
          : await WindowsPackagedStartup.setEnabled(enabled);
      if (_active) setState(() => _startupState = state);
    } catch (_) {
      if (_active) {
        setState(() {
          _startupState = null;
          _startupError = true;
        });
      }
    } finally {
      if (_active) setState(() => _startupBusy = false);
    }
  }

  Future<void> _updateTray() async {
    if (!_active) return;
    await WindowsTray.configure(
      ar: _ar,
      status: _account?.signedIn != true
          ? 'signed_out'
          : _hostReady
              ? 'online'
              : _wantsHosting
                  ? 'waiting'
                  : 'stopped',
    );
  }

  void _scheduleRefresh() {
    _poll?.cancel();
    if (!_active || _account?.signedIn != true) return;
    final startupRetry = _wantsHosting &&
        !_hostReady &&
        _hostRetry < _hostStartupDelays.length &&
        const {
          null,
          'service_unavailable',
          'transport_unconfigured',
          'host_waiting_relay',
          'host_display_unavailable',
        }.contains(_hostingIssue);
    final delay =
        startupRetry ? _hostStartupDelays[_hostRetry] : _refreshInterval;
    _poll = Timer(delay, () {
      if (startupRetry) _hostRetry++;
      unawaited(_run(_refresh, background: true));
    });
  }

  Future<void> _refresh() async {
    final a = _account!;
    final revision = _hostRevision;
    bool stillRequested() =>
        _active && revision == _hostRevision && _wantsHosting;

    try {
      final transport = a.transport;
      final devices = await a.devices();
      if (!_active) return;
      _devices = devices;
      if (_hosting && transport != a.transport) _pauseHosting();
      if (!stillRequested()) return;
      if (!a.hasTransport) {
        _hostingIssue = 'transport_unconfigured';
        return;
      }
      if (!_hosting) {
        final started = await a.startHost(stillRequested);
        if (!started) return;
        if (!stillRequested()) {
          RymuNative.disableHost();
          return;
        }
        _hosting = true;
      }
      if (!RymuNative.hostOnline()) {
        _lastHeartbeat = null;
        _hostingIssue = 'host_waiting_relay';
        return;
      }
      if (_lastHeartbeat != null &&
          DateTime.now().difference(_lastHeartbeat!).inSeconds < 59) {
        _hostingIssue = null;
        return;
      }
      final displayCount = (await engine.getScreenRectList()).length;
      if (!stillRequested()) return;
      if (displayCount == 0) {
        _lastHeartbeat = null;
        _hostingIssue = 'host_display_unavailable';
        return;
      }
      final online = await a.heartbeat(displayCount, stillRequested);
      if (!stillRequested()) return;
      _lastHeartbeat = online ? DateTime.now() : null;
      _hostingIssue = online ? null : 'host_waiting_relay';
      if (online) _hostRetry = 0;
    } catch (error) {
      if (!_active) return;
      if (a.signedIn && stillRequested()) {
        // Revalidate before resuming after a denial or a service interruption.
        _pauseHosting();
        _hostingIssue = _operationError(error);
      }
      rethrow;
    }
  }

  Future<void> _run(Future<void> Function() action,
      {bool background = false}) async {
    final pending = _backgroundOperation;
    if (!background && pending != null) await pending.future;
    if (!_active || _busy || _account == null) return;
    _poll?.cancel();
    final completed = background ? Completer<void>() : null;
    setState(() {
      _busy = true;
      _backgroundOperation = completed;
      _error = null;
    });
    try {
      await action();
    } catch (error) {
      if (_active) {
        final code = _operationError(error);
        _error = code == 'refresh_interrupted' ||
                (background && _account!.signedIn && _wantsHosting)
            ? null
            : code;
        if (!_account!.signedIn) {
          _devices = [];
          _hostRequested = false;
          try {
            _pauseHosting();
          } catch (_) {
            _error = 'native_setup_failed';
          }
        }
      }
    } finally {
      if (_active) {
        setState(() {
          _busy = false;
          _backgroundOperation = null;
          _browserCode = null;
          _waitingForBrowser = false;
        });
        _scheduleRefresh();
        unawaited(_updateTray());
      }
      completed?.complete();
    }
  }

  String _operationError(Object error) => switch (error) {
        ControlError(:final code) => code,
        SocketException() => 'local_browser_return_unavailable',
        TimeoutException() => 'sign_in_expired',
        RymuNativeException() => 'native_setup_failed',
        _ => 'operation_failed',
      };

  String _message(String error) => switch (error) {
        'trust_pending' => t(
            'Approve this device in your account, then try again.',
            'وافق على هذا الجهاز في حسابك ثم أعد المحاولة.'),
        'invalid_service_address' => t(
            'Set a valid Rymu service address in Settings.',
            'أدخل عنوان خدمة ريمو صالحاً في الإعدادات.'),
        'sign_out_before_changing_service' => t(
            'Sign out before switching to a different service.',
            'سجّل الخروج قبل الانتقال إلى خدمة أخرى.'),
        'local_credentials_unavailable' => t(
            'Windows could not load Rymu credentials.',
            'تعذّر على ويندوز فتح بيانات اعتماد ريمو.'),
        'local_browser_return_unavailable' => t(
            'The Windows browser return port is unavailable.',
            'منفذ العودة من المتصفح على ويندوز غير متاح.'),
        'service_unavailable' => t(
            'The account service is unreachable. Check the address and retry.',
            'خدمة الحساب غير متاحة. تحقق من العنوان وأعد المحاولة.'),
        'native_setup_failed' => t(
            'The Windows hosting component could not start. Check this installation.',
            'تعذّر تشغيل مكوّن الاستضافة في ويندوز. تحقّق من هذا التثبيت.'),
        'transport_unconfigured' => t(
            'Waiting for connection settings from Rymu. Refresh to try again.',
            'بانتظار إعدادات الاتصال من ريمو. حدّث لإعادة المحاولة.'),
        'invalid_transport' => t(
            'Check the private server and relay addresses and the server public key.',
            'تحقّق من عنوان الخادم الخاص وعنوان التمرير والمفتاح العام للخادم.'),
        'host_waiting_relay' => _account?.transport?.isManaged == true
            ? t('Rymu is connecting. Check this computer’s internet access if this continues.',
                'يحاول ريمو الاتصال. تحقّق من اتصال الكمبيوتر بالإنترنت إذا استمر الانتظار.')
            : t('Rymu will retry. Check that this computer can reach the private connection server.',
                'سيعيد ريمو المحاولة. تحقّق من إمكانية وصول هذا الكمبيوتر إلى خادم الاتصال الخاص.'),
        'host_display_unavailable' => t(
            'Rymu is waiting for a display in this Windows session.',
            'ينتظر ريمو ظهور شاشة في جلسة ويندوز الحالية.'),
        'account_suspended' => t(
            'Hosting is paused while this account is suspended.',
            'الاستضافة متوقفة مؤقتاً بسبب تعليق هذا الحساب.'),
        'windows_startup_unavailable' => t(
            'Windows could not update the startup entry for Rymu.',
            'تعذّر تحديث إعداد بدء تشغيل ريمو في ويندوز.'),
        'windows_tray_unavailable' => t(
            'The background icon is unavailable. Keep this window minimized to continue hosting.',
            'أيقونة الخلفية غير متاحة. صغّر هذه النافذة للاستمرار في الاستضافة.'),
        'sign_in_expired' => t(
            'Browser sign-in expired. Start again from Rymu.',
            'انتهت مهلة تسجيل الدخول. ابدأ من ريمو مرة أخرى.'),
        'refresh_interrupted' => t(
            'Sign-in renewal was interrupted. Sign in again.',
            'توقّف تجديد تسجيل الدخول. سجّل الدخول مجدداً.'),
        'device_conflict' => t(
            'Remove the previous entry for this computer from your trusted devices, then try again.',
            'أزل الإدخال السابق لهذا الكمبيوتر من أجهزتك الموثوقة، ثم أعد المحاولة.'),
        'invalid_token' =>
          t('Sign in again to continue.', 'سجّل الدخول مجدداً للمتابعة.'),
        _ => t(
            'The operation could not be completed. Check your account and try again.',
            'تعذّر إتمام العملية. تحقق من الحساب وحاول مجدداً.'),
      };

  Future<void> _beginSignIn(BuildContext context) async {
    var alias = t('Windows PC', 'كمبيوتر ويندوز');
    final supportsAutoHost = _account?.supportsAutoHost == true;
    var host = false;
    final selection = await showDialog<(String, bool)>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: _ar ? TextDirection.rtl : TextDirection.ltr,
        child: StatefulBuilder(builder: (ctx, update) {
          return AlertDialog(
            scrollable: true,
            title: Text(t('Link this computer', 'اربط هذا الكمبيوتر')),
            content: SizedBox(
                width: 400,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextFormField(
                        initialValue: alias,
                        onChanged: (value) => alias = value,
                        maxLength: 60,
                        decoration: InputDecoration(
                            labelText: t('Device name', 'اسم الجهاز'))),
                    SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                            t('Host this computer', 'استضافة هذا الكمبيوتر')),
                        subtitle: Text(supportsAutoHost
                            ? t('Trusted devices can connect. Rymu will also start hosting automatically after Windows sign-in.',
                                'يمكن للأجهزة الموثوقة الاتصال. وسيبدأ ريمو الاستضافة تلقائياً بعد تسجيل الدخول إلى ويندوز.')
                            : t('Trusted devices can connect while Rymu is running.',
                                'يمكن للأجهزة الموثوقة الاتصال أثناء تشغيل ريمو.')),
                        value: host,
                        onChanged: (v) => update(() => host = v)),
                  ],
                )),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(t('Cancel', 'إلغاء'))),
              FilledButton(
                  onPressed: () {
                    final name = alias.trim();
                    if (name.isNotEmpty) Navigator.pop(ctx, (name, host));
                  },
                  child: Text(t('Continue in browser', 'متابعة في المتصفح'))),
            ],
          );
        }),
      ),
    );
    if (selection == null || !_active) return;
    await _run(() async {
      final startHosting = await _account!.beginSignIn(
        alias: selection.$1,
        host: selection.$2,
        showBrowser: (code) {
          if (_active) {
            setState(() {
              _browserCode = code;
              _waitingForBrowser = true;
            });
          }
        },
      );
      await _finishEnrollment(startHosting);
    });
  }

  Future<void> _finishEnrollment(bool startHosting) async {
    final account = _account;
    if (!_active || account == null || !account.signedIn) return;
    if (startHosting && account.supportsAutoHost) {
      account.configureEnrolledHostStartup();
    }
    _hostRequested = startHosting;
    _hostRetry = 0;
    await _refresh();
  }

  void _connect(Map<String, dynamic> device, {bool files = false}) {
    unawaited(_run(() async {
      await _account!.stage(device, viewOnly: _viewOnly, files: files);
      if (_active) {
        engine.connect(context, device['peerId'] as String,
            isFileTransfer: files);
      }
    }));
  }

  @override
  void onWindowClose() {
    if (_closing) return;
    unawaited(_hideToTray());
  }

  Future<void> _hideToTray() async {
    if (await WindowsTray.hide() || !_active) return;
    setState(() => _error = 'windows_tray_unavailable');
    await windowManager.show();
  }

  Future<void> _quit() async {
    if (_closing) return;
    _shutdown();
    await WindowsTray.remove();
    await _closeWindow();
  }

  Future<void> _closeWindow() async {
    try {
      await windowManager.setPreventClose(false);
      await windowManager.close();
    } catch (_) {
      await windowManager.destroy();
    }
  }

  void _shutdown() {
    if (_closing) return;
    _closing = true;
    _poll?.cancel();
    _hostRequested = false;
    _hostRevision++;
    try {
      _account?.dispose();
    } catch (_) {
      // The process still exits if the native bridge has already shut down.
    }
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    WindowsTray.onQuit(null);
    unawaited(WindowsTray.remove());
    _shutdown();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final glass = RymuGlassPalette.of(context);
    final solidSurface = Color.alphaBlend(glass.surface, glass.canvas);
    const fontFamily = 'Segoe UI';
    final signedIn = _account?.signedIn == true;
    final section = !signedIn && _section == 1 ? 0 : _section;
    return Theme(
      data: ThemeData(
        useMaterial3: true,
        brightness: glass.brightness,
        fontFamily: fontFamily,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.black,
          dynamicSchemeVariant: DynamicSchemeVariant.monochrome,
          brightness: glass.brightness,
          surface: solidSurface,
          onSurface: glass.ink,
          onSurfaceVariant: glass.muted,
          primary: glass.action,
          onPrimary: glass.onAction,
        ),
        listTileTheme: ListTileThemeData(
          titleTextStyle: TextStyle(
              fontFamily: fontFamily,
              color: glass.ink,
              fontSize: 14,
              fontWeight: FontWeight.w600),
          subtitleTextStyle: TextStyle(
              fontFamily: fontFamily, color: glass.muted, fontSize: 13),
        ),
        dialogTheme: DialogTheme(
          backgroundColor: solidSurface,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: glass.surface,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide(color: glass.line),
          ),
        ),
      ),
      child: Directionality(
        textDirection: _ar ? TextDirection.rtl : TextDirection.ltr,
        child: Scaffold(
          backgroundColor: glass.canvas,
          body: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [solidSurface, glass.canvas, glass.tint],
                stops: const [0, 0.58, 1],
              ),
            ),
            child: LayoutBuilder(builder: (context, bounds) {
              return Padding(
                padding: EdgeInsets.fromLTRB(bounds.maxWidth < 560 ? 16 : 28,
                    12, bounds.maxWidth < 560 ? 16 : 28, 16),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 920),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(glass, section, signedIn),
                        Expanded(
                          child: LayoutBuilder(builder: (context, viewport) {
                            return SingleChildScrollView(
                              key: ValueKey(section),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                              child: ConstrainedBox(
                                constraints: BoxConstraints(
                                    minHeight: (viewport.maxHeight - 32)
                                        .clamp(0.0, double.infinity)),
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (_busy && _backgroundOperation == null)
                                      const Padding(
                                        padding: EdgeInsets.only(bottom: 12),
                                        child: LinearProgressIndicator(
                                            semanticsLabel: 'Rymu'),
                                      ),
                                    if (_error != null)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 12),
                                        child: RymuGlass(
                                          padding: const EdgeInsets.all(14),
                                          child: Semantics(
                                              liveRegion: true,
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(_message(_error!)),
                                                  if (_error ==
                                                      'windows_tray_unavailable')
                                                    TextButton(
                                                      onPressed: _quit,
                                                      child: Text(t('Quit Rymu',
                                                          'خروج كامل')),
                                                    ),
                                                ],
                                              )),
                                        ),
                                      ),
                                    if (section == 2)
                                      _settings(context)
                                    else if (signedIn)
                                      _devicePanel()
                                    else
                                      _signInPanel(context),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ),
                        RymuWindowsDock(
                          selected: section,
                          signedIn: signedIn,
                          arabic: _ar,
                          onSelect: (value) => setState(() => _section = value),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  Widget _header(RymuGlassPalette glass, int section, bool signedIn) {
    final title = switch (section) {
      1 => t('File transfers', 'نقل الملفات'),
      2 => t('Settings', 'الإعدادات'),
      _ => t('My computers', 'أجهزتي'),
    };
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 52),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                const RymuStartupMark(width: 28, height: 20),
                const SizedBox(width: 7),
                Flexible(
                  child: Text('Rymu',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textDirection: TextDirection.ltr,
                      style: TextStyle(
                          color: glass.ink,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                ),
              ],
            ),
          ),
          Expanded(
            flex: 2,
            child: Semantics(
              header: true,
              child: Text(title,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  style: TextStyle(
                      color: glass.ink,
                      fontSize: 22,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          Expanded(
            child: Align(
              alignment: AlignmentDirectional.centerEnd,
              child: Wrap(
                alignment: WrapAlignment.end,
                children: [
                  if (signedIn && section != 2)
                    IconButton(
                      constraints:
                          const BoxConstraints.tightFor(width: 36, height: 44),
                      tooltip: t('Refresh', 'تحديث'),
                      onPressed: _busy ? null : () => _run(_refresh),
                      icon: const Icon(Icons.refresh_rounded, size: 21),
                    ),
                  if (signedIn && section != 0 && _wantsHosting)
                    IconButton(
                      constraints:
                          const BoxConstraints.tightFor(width: 36, height: 44),
                      tooltip: t('Stop hosting', 'إيقاف الاستضافة'),
                      onPressed: _stopHosting,
                      icon: const Icon(Icons.stop_circle_outlined, size: 22),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _signInPanel(BuildContext context) {
    final a = _account;
    final pending = a?.pendingChallenge;
    final glass = RymuGlassPalette.of(context);
    return Align(
      alignment: Alignment.center,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 456),
        child: SizedBox(
          width: double.infinity,
          child: RymuGlass(
            radius: 24,
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
            child: DefaultTextStyle.merge(
              textAlign: TextAlign.center,
              child: Column(children: [
                _computerIcon(glass.tint, glass.ink, Icons.devices_rounded),
                const SizedBox(height: 16),
                Text(t('Sign in to Rymu', 'سجّل الدخول إلى ريمو'),
                    style: const TextStyle(
                        fontSize: 24, fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                if (_browserCode != null) ...[
                  Text(t('Compare this code in your browser:',
                      'طابق هذا الرمز في المتصفح:')),
                  SelectableText(_browserCode!,
                      textDirection: TextDirection.ltr),
                ] else if (_waitingForBrowser) ...[
                  Text(t('Finish signing in to Rymu in your browser.',
                      'أكمل تسجيل الدخول إلى ريمو في المتصفح.')),
                ] else if (pending != null) ...[
                  if (a!.pendingAccountSignIn)
                    Text(t(
                        'Your browser sign-in is complete. Retry linking this computer.',
                        'اكتمل تسجيل الدخول في المتصفح. أعد محاولة ربط هذا الكمبيوتر.'))
                  else ...[
                    Text(t(
                        'Compare the enrollment code before approving this computer:',
                        'طابق رمز التسجيل قبل الموافقة على هذا الكمبيوتر:')),
                    SelectableText('${pending['verificationCode']}',
                        textDirection: TextDirection.ltr),
                  ],
                  const SizedBox(height: 12),
                  Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        if (!a.pendingAccountSignIn)
                          FilledButton.tonal(
                              onPressed:
                                  _busy ? null : () => _run(a.openApproval),
                              child: Text(t('Open approval', 'فتح الموافقة'))),
                        FilledButton(
                            onPressed: _busy
                                ? null
                                : () => _run(() async =>
                                    _finishEnrollment(await a.finishSignIn())),
                            child: Text(t('Finish setup', 'إكمال الإعداد'))),
                        TextButton(
                            onPressed: _busy
                                ? null
                                : () => setState(a.cancelEnrollment),
                            child: Text(t('Cancel', 'إلغاء'))),
                      ]),
                ] else ...[
                  Text(a?.needsSignIn == true
                      ? _message('refresh_interrupted')
                      : t('Use the same account on your devices.',
                          'استخدم الحساب نفسه على أجهزتك.')),
                  const SizedBox(height: 18),
                  FilledButton.icon(
                      onPressed: a == null || _busy
                          ? null
                          : () => _beginSignIn(context),
                      icon: const Icon(Icons.login_rounded, size: 18),
                      label: Text(t('Sign in', 'تسجيل الدخول'))),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Widget _devicePanel() {
    final a = _account!;
    final isFiles = _section == 1;
    final computers = _devices
        .where((d) =>
            (d['roles'] as List).contains('host') &&
            d['id'] != a.deviceId &&
            (d['state'] == 'online' || d['state'] == 'offline'))
        .toList();
    final query = _search.text.trim().toLowerCase();
    final hostList = computers
        .where((d) => (d['alias'] as String).toLowerCase().contains(query))
        .toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (!isFiles && a.isHost) ...[_hostCard(), const SizedBox(height: 24)],
      LayoutBuilder(builder: (context, bounds) {
        final glass = RymuGlassPalette.of(context);
        final search = computers.length >= 4 || query.isNotEmpty;
        final showSearchInline = search && bounds.maxWidth >= 540;
        final field = search
            ? SizedBox(
                width: showSearchInline ? 240 : double.infinity,
                child: TextField(
                  controller: _search,
                  decoration: InputDecoration(
                      isDense: true,
                      prefixIcon: const Icon(Icons.search_rounded, size: 20),
                      labelText: t('Search computers', 'ابحث في الأجهزة')),
                ),
              )
            : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(t('Other computers', 'أجهزة الكمبيوتر الأخرى'),
                        style: const TextStyle(
                            fontSize: 17, fontWeight: FontWeight.w700)),
                  ),
                ),
                if (showSearchInline) ...[
                  const SizedBox(width: 16),
                  field!,
                ] else if (computers.isNotEmpty)
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      color: glass.tint,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 4),
                      child: Text('${hostList.length}',
                          style: TextStyle(color: glass.muted, fontSize: 12)),
                    ),
                  ),
              ],
            ),
            if (isFiles) ...[
              const SizedBox(height: 6),
              Text(
                  t('Choose a computer to open its Rymu transfer folder.',
                      'اختر كمبيوتراً لفتح مجلد نقل ريمو عليه.'),
                  style: TextStyle(color: glass.muted)),
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: _busy ? null : _openTransferFolder,
                icon: const Icon(Icons.folder_open_outlined),
                label: Text(t('Open this computer’s transfer folder',
                    'فتح مجلد النقل على هذا الكمبيوتر')),
              ),
            ],
            if (search && !showSearchInline) ...[
              const SizedBox(height: 12),
              field!,
            ],
          ],
        );
      }),
      const SizedBox(height: 12),
      if (hostList.isEmpty)
        RymuGlass(
          padding: const EdgeInsets.all(22),
          child: Text(
            query.isNotEmpty
                ? t('No matching computers.', 'لا توجد أجهزة مطابقة.')
                : t('Other computers appear here when linked to your account.',
                    'تظهر أجهزة الكمبيوتر الأخرى هنا عند ربطها بحسابك.'),
            textAlign: TextAlign.center,
          ),
        ),
      if (!a.hasTransport &&
          hostList.any((device) => device['state'] == 'online'))
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Text(_message('transport_unconfigured')),
        ),
      if (hostList.isNotEmpty)
        LayoutBuilder(builder: (context, bounds) {
          const gap = 16.0;
          final twoColumns = bounds.maxWidth >= 640 && hostList.length > 1;
          final width =
              twoColumns ? (bounds.maxWidth - gap) / 2 : bounds.maxWidth;
          return Wrap(
            spacing: gap,
            runSpacing: gap,
            alignment: WrapAlignment.center,
            children: [
              for (final device in hostList)
                SizedBox(
                  width: width,
                  child: _deviceCard(device, a, files: isFiles),
                ),
            ],
          );
        }),
    ]);
  }

  Widget _deviceCard(Map<String, dynamic> device, WindowsAccount account,
      {required bool files}) {
    final online = device['state'] == 'online';
    final title = device['alias'] as String;
    final displays = device['displayCount'];
    return Builder(builder: (context) {
      final glass = RymuGlassPalette.of(context);
      return RymuGlass(
        radius: 22,
        padding: const EdgeInsets.fromLTRB(20, 22, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              _computerIcon(
                  glass.tint, glass.ink, Icons.desktop_windows_outlined),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Tooltip(
                      message: title,
                      child: Text(title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ),
                    if (online && displays != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        displays == 1
                            ? t('1 display', 'شاشة واحدة')
                            : t('$displays displays', 'عدد الشاشات $displays'),
                        style: TextStyle(color: glass.muted, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
            ]),
            const SizedBox(height: 12),
            Divider(height: 1, color: glass.line),
            const SizedBox(height: 10),
            Row(children: [
              Expanded(
                child: _statusLabel(
                  online ? t('Online', 'متصل') : t('Offline', 'غير متصل'),
                  online: online,
                  ink: glass.ink,
                  muted: glass.muted,
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: !_busy &&
                        account.hasTransport &&
                        online &&
                        device['peerPublicKey'] is String
                    ? () => _connect(device, files: files)
                    : null,
                child:
                    Text(files ? t('Browse', 'تصفّح') : t('Connect', 'اتصال')),
              ),
            ]),
          ],
        ),
      );
    });
  }

  Widget _computerIcon(Color background, Color foreground, IconData icon) {
    return DecoratedBox(
      decoration: BoxDecoration(
          color: background, borderRadius: BorderRadius.circular(14)),
      child: SizedBox.square(
        dimension: 46,
        child: Icon(icon, size: 22, color: foreground),
      ),
    );
  }

  Widget _statusLabel(String status,
      {required bool online, required Color ink, required Color muted}) {
    return Row(
      children: [
        Icon(online ? Icons.circle : Icons.circle_outlined,
            size: 7, color: online ? ink : muted),
        const SizedBox(width: 6),
        Expanded(
            child: Text(status, style: TextStyle(color: muted, fontSize: 13))),
      ],
    );
  }

  Widget _hostCard() {
    final status = switch (_hostingIssue) {
      'service_unavailable' => t(
          'Waiting for a connection to Rymu. Retrying automatically.',
          'بانتظار الاتصال بريمو. ستُعاد المحاولة تلقائياً.'),
      final issue? => _message(issue),
      null when _hostReady => t('Ready to connect', 'جاهز للاتصال'),
      null when _wantsHosting => t('Connecting…', 'جارٍ الاتصال…'),
      _ => t('Hosting is off', 'الاستضافة متوقفة'),
    };
    final action = _wantsHosting
        ? OutlinedButton(
            onPressed: _stopHosting,
            style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Color(0x55ffffff))),
            child: Text(t('Stop hosting', 'إيقاف الاستضافة')))
        : FilledButton.icon(
            onPressed: _busy
                ? null
                : () => _run(() async {
                      _hostRequested = true;
                      _hostRetry = 0;
                      await _refresh();
                    }),
            style: FilledButton.styleFrom(
                backgroundColor: const Color(0xfff5f5f5),
                foregroundColor: const Color(0xff191919),
                disabledForegroundColor: const Color(0xffc0c0c0),
                disabledBackgroundColor: const Color(0x33ffffff)),
            icon: const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(t('Start hosting', 'بدء الاستضافة')));
    final details = Row(
      children: [
        _computerIcon(
            const Color(0x20ffffff), Colors.white, Icons.computer_rounded),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(t('This computer', 'هذا الكمبيوتر'),
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 19,
                      fontWeight: FontWeight.w700)),
              const SizedBox(height: 5),
              _statusLabel(status,
                  online: _hostReady,
                  ink: Colors.white,
                  muted: const Color(0xffd2d2d2)),
            ],
          ),
        ),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(24),
        gradient: const LinearGradient(
          begin: AlignmentDirectional.topStart,
          end: AlignmentDirectional.bottomEnd,
          colors: [Color(0xff393939), Color(0xff1e1e1e)],
        ),
        border: Border.all(color: const Color(0x36ffffff)),
        boxShadow: const [
          BoxShadow(
              color: Color(0x29000000), blurRadius: 20, offset: Offset(0, 7)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        child: LayoutBuilder(builder: (context, bounds) {
          return bounds.maxWidth < 330
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    details,
                    const SizedBox(height: 10),
                    Align(
                        alignment: AlignmentDirectional.centerEnd,
                        child: action),
                  ],
                )
              : Row(
                  children: [
                    Expanded(child: details),
                    const SizedBox(width: 16),
                    action,
                  ],
                );
        }),
      ),
    );
  }

  Widget _autoHostSetting(WindowsAccount a) => SwitchListTile(
        title: Text(a.packagedWindows
            ? t('Resume hosting when Rymu opens',
                'استئناف الاستضافة عند فتح ريمو')
            : t('Automatic hosting', 'الاستضافة التلقائية')),
        subtitle: Text(a.packagedWindows
            ? t('Keep this signed-in device ready for connections when Rymu opens. Windows startup is controlled separately below. Stop hosting turns this off.',
                'اجعل هذا الجهاز المسجّل جاهزاً للاتصال عند فتح ريمو. التشغيل مع ويندوز خيار مستقل أدناه. إيقاف الاستضافة يعطّل هذا الخيار.')
            : a.supportsAutoHost
                ? t('Starts after Windows sign-in and keeps your Rymu sign-in. Closing hides Rymu beside the clock; use Quit Rymu there to exit. Stop hosting disables automatic hosting.',
                    'تبدأ بعد دخول ويندوز مع حفظ تسجيل دخول ريمو. الإغلاق يخفي ريمو بجانب الساعة؛ للخروج استخدم «خروج كامل» من الأيقونة. إيقاف الاستضافة يعطّل تشغيلها التلقائي.')
                : t('Install Rymu to use this option.',
                    'ثبّت ريمو لاستخدام هذا الخيار.')),
        value: a.autoHost,
        onChanged: !a.supportsAutoHost || _busy
            ? null
            : (enabled) {
                if (enabled) {
                  unawaited(_run(() async {
                    a.setAutoHost(true);
                    _hostRetry = 0;
                    await _refresh();
                  }));
                } else {
                  _stopHosting();
                }
              },
      );

  Future<void> _openTransferFolder() => _run(() async {
        await Process.start('explorer.exe', [RymuNative.transferRoot()],
            mode: ProcessStartMode.detached);
      });

  Widget _packagedStartupSetting() {
    final state = _startupState;
    final detail = switch (state) {
      PackagedStartupState.disabledByUser => t(
          'Windows disabled startup for Rymu. Enable it in Windows Settings → Apps → Startup. Rymu cannot override your choice.',
          'تم تعطيل بدء ريمو في ويندوز. فعّله من إعدادات ويندوز ← التطبيقات ← بدء التشغيل. لا يستطيع ريمو تجاوز اختيارك.'),
      PackagedStartupState.disabledByPolicy ||
      PackagedStartupState.enabledByPolicy =>
        t('Your administrator manages this Windows startup setting.',
            'يدير مسؤول الجهاز إعداد التشغيل هذا.'),
      null when _startupError => t(
          'Could not read Windows startup settings. Retry to check the current state.',
          'تعذّرت قراءة إعداد بدء التشغيل. أعد المحاولة لمعرفة حالته الحالية.'),
      null => t('Checking Windows startup settings…',
          'جارٍ قراءة إعداد بدء التشغيل…'),
      _ => t(
          'Open Rymu after signing in to Windows. Hosting also requires a saved account and the hosting option above. Closing keeps Rymu beside the clock; Quit Rymu exits completely.',
          'افتح ريمو بعد تسجيل الدخول إلى ويندوز. الاستضافة تتطلب حساباً محفوظاً وتفعيل خيار الاستضافة أعلاه. الإغلاق يبقي ريمو بجانب الساعة؛ «خروج كامل» ينهي التطبيق.'),
    };
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SwitchListTile(
        title: Text(t('Start Rymu with Windows', 'تشغيل ريمو مع ويندوز')),
        subtitle: Text(detail),
        value: state?.enabledForWindows ?? false,
        onChanged: _startupBusy ||
                state == null ||
                state.managedByPolicy ||
                state == PackagedStartupState.disabledByUser
            ? null
            : (enabled) => unawaited(_refreshPackagedStartup(enabled: enabled)),
      ),
      if (_startupError)
        TextButton.icon(
          onPressed:
              _startupBusy ? null : () => unawaited(_refreshPackagedStartup()),
          icon: const Icon(Icons.refresh_rounded),
          label: Text(t('Retry', 'إعادة المحاولة')),
        ),
    ]);
  }

  void _pauseHosting() {
    final wasHosting = _hosting;
    _hosting = false;
    _lastHeartbeat = null;
    _hostingIssue = null;
    if (wasHosting) RymuNative.disableHost();
  }

  void _stopHosting() {
    if (!_active) return;
    setState(() {
      _hostRequested = false;
      _hostRevision++;
      _hostRetry = 0;
      try {
        try {
          _pauseHosting();
        } finally {
          _account!.setAutoHost(false);
        }
      } on ControlError catch (error) {
        _error = error.code;
      } on RymuNativeException {
        _error = 'native_setup_failed';
      }
    });
  }

  Widget _settings(BuildContext context) {
    final a = _account;
    final preferences = _settingsPanel(
      context,
      title: t('Preferences', 'التفضيلات'),
      icon: Icons.tune_rounded,
      rows: [
        _settingsAction(
          title: t('Interface language', 'لغة الواجهة'),
          action: SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: false, label: Text('English')),
              ButtonSegment(value: true, label: Text('العربية'))
            ],
            selected: {_ar},
            onSelectionChanged: a == null || _busy
                ? null
                : (v) => _run(() async {
                      a.saveSettings(
                          api: a.apiBase,
                          rendezvous: a.rendezvous,
                          relay: a.relay,
                          key: a.rendezvousKey,
                          ar: v.first);
                      _ar = v.first;
                      final language = _ar ? 'ar' : 'en';
                      await bind.mainSetLocalOption(
                          key: rymuLocalLanguageKey, value: language);
                      await Get.updateLocale(Locale(language));
                    }),
          ),
        ),
        if (a != null && a.signedIn)
          SwitchListTile(
            title: Text(t('View-only sessions', 'جلسات العرض فقط')),
            value: _viewOnly,
            onChanged: (value) => setState(() => _viewOnly = value),
          ),
        if (a != null && a.isHost) _autoHostSetting(a),
        if (a?.packagedWindows == true) _packagedStartupSetting(),
      ],
    );
    final connection = _settingsPanel(
      context,
      title: t('Connection & account', 'الاتصال والحساب'),
      icon: Icons.link_rounded,
      rows: [
        _settingsAction(
          title: t('Connection', 'الاتصال'),
          detail: switch (a?.transport) {
            final route? when route.isManaged =>
              t('Rymu manages your connection.', 'يدير ريمو اتصالك تلقائياً.'),
            final _? =>
              t('Using your private server.', 'يُستخدم خادم الاتصال الخاص بك.'),
            null => a?.signedIn == true
                ? _message('transport_unconfigured')
                : t('Sign in to load the connection from your account.',
                    'سجّل الدخول لتحميل إعداد الاتصال من حسابك.'),
          },
          action: OutlinedButton(
              onPressed: a == null || _busy ? null : () => _editRoute(context),
              child: Text(t('Advanced', 'متقدم'))),
        ),
        if (a?.isHost == true)
          _settingsAction(
            title: t('Local transfer folder', 'مجلد النقل المحلي'),
            detail: t(
                'Files received here are saved in Rymu / Files. Authorized account transfers do not need another host approval.',
                'تُحفظ الملفات المستلمة هنا في Rymu / Files. نقل الملفات المصرّح به ضمن حسابك لا يحتاج موافقة إضافية من المضيف.'),
            action: OutlinedButton(
              onPressed: _busy ? null : _openTransferFolder,
              child: Text(t('Open', 'فتح')),
            ),
          ),
        if (a != null && a.signedIn)
          _settingsAction(
            title: t('This device', 'هذا الجهاز'),
            detail: t(
                'Signing out removes this computer from your trusted devices.',
                'يزيل تسجيل الخروج هذا الكمبيوتر من أجهزتك الموثوقة.'),
            action: OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(() async {
                        _stopHosting();
                        await a.signOut();
                        if (!_active) return;
                        _devices = [];
                        _section = 0;
                        _search.clear();
                      }),
              child: Text(t('Sign out', 'تسجيل الخروج')),
            ),
          ),
        RymuAttribution(arabic: _ar),
      ],
    );
    return LayoutBuilder(builder: (context, bounds) {
      if (bounds.maxWidth < 720 ||
          MediaQuery.textScalerOf(context).scale(14) > 18) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [preferences, const SizedBox(height: 16), connection],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(child: preferences),
          const SizedBox(width: 16),
          Expanded(child: connection),
        ],
      );
    });
  }

  Widget _settingsAction({
    required String title,
    String? detail,
    required Widget action,
  }) =>
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: LayoutBuilder(builder: (context, bounds) {
          final theme = Theme.of(context).listTileTheme;
          final labels = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(title, style: theme.titleTextStyle),
              if (detail != null) ...[
                const SizedBox(height: 4),
                Text(detail, style: theme.subtitleTextStyle),
              ],
            ],
          );
          if (bounds.maxWidth < 320 ||
              MediaQuery.textScalerOf(context).scale(14) > 18) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [labels, const SizedBox(height: 8), action],
            );
          }
          return Row(children: [
            Expanded(child: labels),
            const SizedBox(width: 12),
            action,
          ]);
        }),
      );

  Widget _settingsPanel(BuildContext context,
      {required String title,
      required IconData icon,
      required List<Widget> rows}) {
    final glass = RymuGlassPalette.of(context);
    return RymuGlass(
      radius: 22,
      padding: const EdgeInsets.fromLTRB(8, 16, 8, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            child: Row(children: [
              Icon(icon, size: 18, color: glass.muted),
              const SizedBox(width: 8),
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(title,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700)),
                ),
              ),
            ]),
          ),
          const SizedBox(height: 6),
          ...ListTile.divideTiles(color: glass.line, tiles: rows),
        ],
      ),
    );
  }

  Future<void> _editRoute(BuildContext context) async {
    final a = _account!;
    final values = [a.apiBase, a.rendezvous, a.relay, a.rendezvousKey];
    final labels = [
      t('Control API URL', 'عنوان خدمة الحساب'),
      t('Rendezvous server', 'خادم التعارف'),
      t('Relay server', 'خادم التمرير'),
      t('Server public key', 'المفتاح العام للخادم')
    ];
    final result = await showDialog<List<String>>(
        context: context,
        builder: (ctx) => Directionality(
              textDirection: _ar ? TextDirection.rtl : TextDirection.ltr,
              child: AlertDialog(
                scrollable: true,
                title: Text(t('Connection settings', 'إعدادات الاتصال')),
                content: SizedBox(
                    width: 430,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < values.length; i++)
                          Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: TextFormField(
                                initialValue: values[i],
                                onChanged: (value) => values[i] = value,
                                textDirection: TextDirection.ltr,
                                decoration:
                                    InputDecoration(labelText: labels[i]),
                              )),
                      ],
                    )),
                actions: [
                  if (a.transport?.isManaged == false)
                    TextButton(
                        onPressed: () =>
                            Navigator.pop(ctx, [a.apiBase, '', '', '']),
                        child: Text(
                            t('Use Rymu connection', 'استخدام اتصال ريمو'))),
                  TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: Text(t('Cancel', 'إلغاء'))),
                  FilledButton(
                      onPressed: () => Navigator.pop(
                          ctx, values.map((v) => v.trim()).toList()),
                      child: Text(t('Save', 'حفظ'))),
                ],
              ),
            ));
    if (result == null || !_active) return;
    await _run(() async {
      final previous = a.transport;
      a.saveSettings(
          api: result[0],
          rendezvous: result[1],
          relay: result[2],
          key: result[3],
          ar: _ar);
      if (previous != a.transport) {
        _pauseHosting();
        _hostRetry = 0;
      }
      if (a.signedIn) await _refresh();
    });
  }
}
