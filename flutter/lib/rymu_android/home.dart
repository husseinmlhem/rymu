import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../consts.dart';
import '../mobile/pages/file_manager_page.dart';
import '../mobile/pages/remote_page.dart';
import '../models/platform_model.dart' show bind;
import '../rymu/account_transport.dart';
import '../rymu/attribution.dart';
import '../rymu/glass.dart';
import '../rymu/native_bridge.dart';
import '../rymu/startup_mark.dart';
import 'account.dart';
import 'appearance.dart';
import 'receiving_folder.dart';
import '../utils/android_documents.dart';

class RymuAndroidHome extends StatefulWidget {
  const RymuAndroidHome({super.key});

  @override
  State<RymuAndroidHome> createState() => _RymuAndroidHomeState();
}

class _RymuAndroidHomeState extends State<RymuAndroidHome>
    with WidgetsBindingObserver {
  final _config = AndroidAccountConfig();
  late final _account = AndroidAccount(_config);
  final _alias = TextEditingController();
  final _languagePicker = GlobalKey<FormFieldState<String>>();
  List<AndroidHost> _hosts = [];
  String _language = 'auto';
  int _tab = 0;
  bool _ready = false;
  bool _busy = false;
  bool _checkingCallback = false;
  bool _callbackNotified = false;
  String? _queuedCallback;
  bool _sessionVisible = false;
  bool _viewOnly = false;
  bool _hostsCurrent = false;
  AndroidTransportSettings _transport = AndroidTransportSettings.defaults;
  Timer? _poll;
  int _nextHeartbeat = 0;
  String? _notice;

  AccountTransport? get _connection => _transport.configured
      ? AccountTransport.manual(
          _transport.rendezvous, _transport.relay, _transport.serverKey)
      : _account.managedTransport;

  bool get _arabic =>
      _language == 'ar' ||
      (_language == 'auto' &&
          WidgetsBinding.instance.platformDispatcher.locale.languageCode ==
              'ar');

  String t(String english, String arabic) => rymuCopy(_arabic, english, arabic);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    rymuAndroidChannel.setMethodCallHandler((call) async {
      if (call.method == 'oauthCallback') {
        _callbackNotified = true;
        await _checkCallback();
      }
    });
    unawaited(_restore());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_ready ||
          _busy ||
          !mounted ||
          _sessionVisible ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      final enrollment = _account.enrollment;
      if (enrollment?['verificationCode'] != null &&
          enrollment?['proof'] == null) {
        if (_notice != 'authorization_expired') {
          unawaited(_tryApproval(quiet: true));
        }
      } else if (_account.session != null &&
          DateTime.now().millisecondsSinceEpoch >= _nextHeartbeat) {
        unawaited(_refresh(sendPresence: true));
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    rymuAndroidChannel.setMethodCallHandler(null);
    _poll?.cancel();
    _alias.dispose();
    _account.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _ready) {
      if (_account.session != null && !_sessionVisible) {
        unawaited(_refresh());
      } else {
        unawaited(_checkCallback());
      }
    }
  }

  @override
  void didChangeLocales(List<Locale>? locales) {
    if (mounted && _language == 'auto') setState(() {});
  }

  Future<void> _restore() async {
    await _run(() async {
      final language = bind.mainGetLocalOption(key: 'rymu-language');
      if (language == 'ar' || language == 'en') _language = language;
      _viewOnly = bind.mainGetLocalOption(key: 'rymu-mobile-view-only') == 'Y';
      _transport = AndroidTransportSettings.fromLocalOption(
          bind.mainGetLocalOption(key: AndroidTransportSettings.localOption));
      await _account.restore();
      if (_account.session != null) {
        await _reload(sendPresence: true);
      } else if (_account.accountEnrollment) {
        await _completePhoneSetup();
      }
    });
    if (!mounted) return;
    setState(() => _ready = true);
    await _checkCallback();
  }

  Future<void> _run(Future<void> Function() action,
      {bool quietPending = false}) async {
    if (_busy || !mounted) return;
    final wasSignedIn = _account.session != null;
    setState(() {
      _busy = true;
      if (!quietPending) _notice = null;
    });
    try {
      await action();
    } on AccountProblem catch (error) {
      if (error.code == 'trust_pending' && quietPending) return;
      if (const {
            'reauthentication_required',
            'refresh_interrupted',
            'invalid_refresh',
            'token_reuse',
            'device_revoked',
            'invalid_token',
            'access_denied',
            'invalid_access_token',
            'unauthorized',
          }.contains(error.code) &&
          _account.session != null) {
        final hadConnection = _connection != null;
        _hosts = [];
        _hostsCurrent = false;
        try {
          try {
            await _account.clearLocal();
          } finally {
            if (hadConnection) RymuNative.clearTransport();
          }
        } on PlatformException {
          _notice = 'storage_unavailable';
          return;
        } on RymuNativeException {
          _notice = 'transport_invalid';
          return;
        }
      }
      _notice = error.code;
    } on PlatformException {
      _notice = 'storage_unavailable';
    } catch (_) {
      _notice = 'request_failed';
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          if (wasSignedIn != (_account.session != null)) _tab = 0;
        });
        if (!_checkingCallback && _ready) unawaited(_checkCallback());
      }
    }
  }

  Future<void> _checkCallback() async {
    if (!_ready || _busy || _checkingCallback || !mounted) return;
    _checkingCallback = true;
    try {
      var callback = _queuedCallback;
      if (callback == null) {
        _callbackNotified = false;
        callback =
            await rymuAndroidChannel.invokeMethod<String>('takeCallback');
      }
      if (!mounted) return;
      if (_busy) {
        _queuedCallback = callback;
        return;
      }
      _queuedCallback = null;
      final readyCallback = callback;
      if (readyCallback != null && _account.pendingLogin != null) {
        await _run(() async {
          await _account.finishLogin(readyCallback);
          if (_account.accountEnrollment) await _completePhoneSetup();
        });
      }
    } on PlatformException {
      if (mounted) setState(() => _notice = 'storage_unavailable');
    } finally {
      _checkingCallback = false;
      if (_callbackNotified) unawaited(_checkCallback());
    }
  }

  Future<void> _reload({required bool sendPresence}) async {
    try {
      if (sendPresence) {
        _nextHeartbeat = DateTime.now().millisecondsSinceEpoch + 60000;
        await _account.heartbeat();
      }
      _hosts = await _readHosts();
      _hostsCurrent = true;
    } catch (_) {
      _hostsCurrent = false;
      rethrow;
    }
  }

  Future<List<AndroidHost>> _readHosts() async {
    final previous = _connection;
    final hosts = await _account.hosts();
    if (mounted && previous != null && previous != _connection) {
      RymuNative.clearTransport();
    }
    return hosts;
  }

  Future<void> _refresh({bool sendPresence = false}) =>
      _run(() => _reload(sendPresence: sendPresence));

  Future<void> _tryApproval({required bool quiet}) => _run(() async {
        await _account.finishEnrollment();
        await _reload(sendPresence: true);
      }, quietPending: quiet);

  Future<void> _completePhoneSetup() async {
    await _account.beginEnrollment('Android device');
    await _reload(sendPresence: true);
  }

  Future<void> _startSignIn() async {
    await _account.beginLogin();
    await _openBrowser(_account.pendingLogin!['url'] as String);
  }

  Future<void> _openBrowser(String path) async {
    final uri = _config.checkedBrowserUrl(path);
    if (!await launchUrl(uri, mode: LaunchMode.externalApplication)) {
      throw const AccountProblem('browser_unavailable');
    }
  }

  Future<void> _changeLanguage(String value) => _run(() async {
        try {
          await bind.mainSetLocalOption(key: 'rymu-language', value: value);
          _language = value;
        } catch (_) {
          _languagePicker.currentState?.reset();
          rethrow;
        }
      });

  Future<void> _connect(AndroidHost host, {required bool files}) =>
      _run(() async {
        if (!_hostsCurrent || !host.connectable) {
          throw const AccountProblem('host_unavailable');
        }
        if (_connection == null) {
          throw const AccountProblem('transport_unconfigured');
        }
        await bind.mainSetLocalOption(
            key: kCommConfKeyLang, value: _arabic ? 'ar' : 'en');
        if (!await _stage(host, files: files) || !mounted) return;
        _sessionVisible = true;
        try {
          await Navigator.of(context)
              .push<void>(MaterialPageRoute(builder: (context) {
            final locale = Locale(_arabic ? 'ar' : 'en');
            return Theme(
              data: rymuAndroidTheme(MediaQuery.platformBrightnessOf(context)),
              child: Localizations.override(
                context: context,
                locale: locale,
                child: Directionality(
                  textDirection:
                      _arabic ? TextDirection.rtl : TextDirection.ltr,
                  child: files
                      ? FileManagerPage(id: host.peerId!, rymuArabic: _arabic)
                      : RemotePage(
                          id: host.peerId!,
                          rymuName: host.alias,
                          rymuHostId: host.id,
                          rymuArabic: _arabic,
                          rymuViewOnly: _viewOnly,
                          rymuRestage: () => _restage(host)),
                ),
              ),
            );
          }));
        } finally {
          _sessionVisible = false;
        }
        if (mounted) await _reload(sendPresence: false);
      });

  Future<bool> _restage(AndroidHost original) async {
    if (!_sessionVisible || !mounted) return false;
    try {
      final hosts = await _readHosts();
      final sameHost = hosts.any((host) =>
          host.id == original.id &&
          host.peerId == original.peerId &&
          host.peerPublicKey == original.peerPublicKey &&
          host.state != 'pending');
      if (!sameHost) return false;
      return await _stage(original, files: false, reconnecting: true);
    } on AccountProblem catch (error) {
      if (error.code == 'network_unavailable') rethrow;
      return false;
    } on RymuNativeException {
      return false;
    }
  }

  Future<bool> _stage(AndroidHost host,
      {required bool files, bool reconnecting = false}) async {
    final access = await _account.accessToken();
    final seed = await _account.signingSeed();
    if (!mounted || (reconnecting && !_sessionVisible)) return false;
    final route = _connection;
    if (route == null) throw const AccountProblem('transport_unconfigured');
    RymuNative.stageSession(
      peerId: host.peerId!,
      hostId: host.id,
      peerPublicKey: host.peerPublicKey!,
      accessToken: access,
      signingSeed: seed,
      apiBase: _config.api.toString(),
      transport: route,
      viewOnly: _viewOnly && !files,
      files: files,
    );
    return true;
  }

  String _message(String code) => switch (code) {
        'configuration_missing' => t('This build needs an account service URL.',
            'تحتاج هذه النسخة إلى عنوان خدمة الحساب.'),
        'transport_unconfigured' => t(
            'Waiting for connection settings from Rymu. Refresh Devices to try again.',
            'بانتظار إعدادات الاتصال من ريمو. حدّث الأجهزة لإعادة المحاولة.'),
        'transport_invalid' => t(
            'Check the private rendezvous address, relay address and server public key.',
            'تحقّق من عنوان خادم التعارف وعنوان خادم التمرير والمفتاح العام للخادم.'),
        'network_unavailable' => t(
            'Cannot reach Rymu. Check your connection and try again.',
            'تعذّر الوصول إلى ريمو. تحقّق من اتصالك وحاول مجدداً.'),
        'host_unavailable' => t(
            'On Windows, open Rymu and select Start hosting. Then refresh here.',
            'افتح ريمو على ويندوز واختر «بدء الاستضافة»، ثم حدّث القائمة هنا.'),
        'browser_unavailable' =>
          t('Could not open your browser.', 'تعذّر فتح المتصفح.'),
        'invalid_oauth_callback' => t(
            'This browser response does not match your sign-in.',
            'استجابة المتصفح لا تطابق طلب تسجيل الدخول.'),
        'authorization_expired' => t('Your sign-in expired. Start again.',
            'انتهت صلاحية طلب تسجيل الدخول. ابدأ من جديد.'),
        'device_conflict' => t(
            'This phone is already registered. Review it under Manage trusted devices in your account.',
            'هذا الهاتف مسجّل بالفعل. راجعه من «إدارة الأجهزة الموثوقة» في حسابك.'),
        'trust_pending' => _account.accountEnrollment
            ? t('Device setup is pending. Finish sign-in to retry.',
                'إعداد الجهاز قيد الانتظار. اختر «إكمال تسجيل الدخول» للمحاولة مجدداً.')
            : t('Approval is pending. Check the device code in your account.',
                'الموافقة معلّقة. تحقّق من رمز الجهاز في حسابك.'),
        'storage_unavailable' => t(
            'Secure storage is unavailable. Reopen Rymu and try again.',
            'التخزين الآمن غير متاح. أعد فتح ريمو وحاول مجدداً.'),
        'saved_account_invalid' => t(
            'Could not restore your sign-in. Sign in again.',
            'تعذّرت استعادة تسجيل الدخول. سجّل الدخول مجدداً.'),
        'refresh_interrupted' => t(
            'Sign-in renewal was interrupted. Sign in again.',
            'توقّف تجديد تسجيل الدخول. سجّل الدخول مجدداً.'),
        'account_suspended' => t('Access to this account is paused.',
            'الوصول إلى هذا الحساب معلّق.'),
        'rate_limited' => t('Too many requests. Try again in a minute.',
            'طلبات كثيرة. حاول مجدداً بعد دقيقة.'),
        'signed_out_locally' => t(
            'Signed out on this phone. Revoke it from your account to end server access.',
            'تم تسجيل الخروج من الهاتف. ألغِ الثقة به في حسابك لإنهاء وصوله.'),
        'reauthentication_required' ||
        'invalid_refresh' ||
        'invalid_token' ||
        'token_reuse' ||
        'device_revoked' ||
        'unauthorized' =>
          t('Sign in again to use this device.',
              'سجّل الدخول مجدداً لاستخدام هذا الجهاز.'),
        _ => t('Rymu could not finish this request. Try again.',
            'تعذّر إكمال الطلب في ريمو. حاول مجدداً.'),
      };

  @override
  Widget build(BuildContext context) {
    final theme = rymuAndroidTheme(MediaQuery.platformBrightnessOf(context));
    final signedIn = _account.session != null;
    final icons = theme.brightness == Brightness.dark
        ? Brightness.light
        : Brightness.dark;
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: icons,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarIconBrightness: icons,
      ),
      child: Localizations.override(
        context: context,
        locale: Locale(_arabic ? 'ar' : 'en'),
        child: Theme(
          data: theme,
          child: Directionality(
            textDirection: _arabic ? TextDirection.rtl : TextDirection.ltr,
            child: PopScope(
              canPop: _tab == 0,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop && _tab != 0) setState(() => _tab = 0);
              },
              child: ColoredBox(
                color: theme.scaffoldBackgroundColor,
                child: DisplayFeatureSubScreen(
                  child: LayoutBuilder(builder: (context, viewport) {
                    final wide = viewport.maxWidth >= 600;
                    final inset = viewport.maxWidth >= 840 ? 28.0 : 20.0;
                    final appTheme = Theme.of(context);
                    final palette = RymuGlassPalette(theme.brightness);
                    return Scaffold(
                      bottomNavigationBar:
                          signedIn ? _navigation(wide: wide) : null,
                      body: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: wide
                              ? LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  colors: [
                                    Color.alphaBlend(
                                        palette.surface, palette.canvas),
                                    palette.canvas,
                                  ],
                                )
                              : null,
                        ),
                        child: SafeArea(
                          bottom: !signedIn,
                          child: Align(
                            alignment: Alignment.topCenter,
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 1120),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  _header(appTheme, signedIn),
                                  SizedBox(
                                    height: 2,
                                    child: _busy
                                        ? const LinearProgressIndicator(
                                            minHeight: 2)
                                        : null,
                                  ),
                                  Expanded(
                                    child: _pageContent(context, appTheme,
                                        signedIn: signedIn,
                                        wide: wide,
                                        inset: inset),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _pageContent(BuildContext context, ThemeData theme,
      {required bool signedIn, required bool wide, required double inset}) {
    final children = [
      if (_notice case final notice?) ...[
        Semantics(
          liveRegion: true,
          child: _Panel(children: [Text(_message(notice))]),
        ),
        const SizedBox(height: 12),
      ],
      if (!_ready)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40),
          child: Column(children: [
            const RymuStartupMark(),
            const SizedBox(height: 20),
            Text(t('Loading account…', 'جارٍ تحميل الحساب…')),
          ]),
        )
      else if (_tab == 2)
        ..._settings(context, theme, wide: wide)
      else if (!signedIn)
        ..._signIn(theme, wide: wide)
      else
        ..._deviceList(theme, files: _tab == 1, wide: wide),
    ];
    final padding = EdgeInsets.fromLTRB(inset, 16, inset, 20);
    final key = PageStorageKey('rymu-android-$_tab-$signedIn');
    if (!wide) return ListView(key: key, padding: padding, children: children);

    return LayoutBuilder(builder: (context, bounds) {
      return SingleChildScrollView(
        key: key,
        padding: padding,
        child: ConstrainedBox(
          constraints: BoxConstraints(
              minHeight: math.max(0, bounds.maxHeight - padding.vertical)),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      );
    });
  }

  Widget _header(ThemeData theme, bool signedIn) => Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(20, 8, 12, 4),
        child: Row(children: [
          ExcludeSemantics(
            child: SvgPicture.asset(
              'assets/rymu-mark.svg',
              width: 32,
              height: 24,
              colorFilter: ColorFilter.mode(
                  theme.colorScheme.onSurface, BlendMode.srcIn),
            ),
          ),
          const SizedBox(width: 8),
          Text('Rymu',
              textDirection: TextDirection.ltr,
              style: theme.textTheme.titleLarge
                  ?.copyWith(fontWeight: FontWeight.w700)),
          const Spacer(),
          if (signedIn && _tab != 2)
            IconButton(
              tooltip: t('Refresh devices', 'تحديث الأجهزة'),
              onPressed: _busy ? null : () => _refresh(),
              icon: const Icon(Icons.refresh_rounded),
            )
          else if (!signedIn)
            IconButton(
              tooltip: _tab == 2
                  ? t('Back to sign in', 'العودة إلى تسجيل الدخول')
                  : t('Settings', 'الإعدادات'),
              onPressed: _ready
                  ? () => setState(() => _tab = _tab == 2 ? 0 : 2)
                  : null,
              icon: Icon(_tab == 2
                  ? Icons.arrow_back_rounded
                  : Icons.settings_outlined),
            )
          else
            const SizedBox(height: 48),
        ]),
      );

  Widget _navigation({required bool wide}) => SafeArea(
        top: false,
        minimum: EdgeInsets.fromLTRB(16, 0, 16, wide ? 12 : 8),
        child: Align(
          heightFactor: 1,
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: wide ? 392 : 568),
            child: RymuGlass(
              radius: 22,
              blur: wide,
              child: NavigationBar(
                height: 64 +
                    math.max(0,
                            MediaQuery.textScalerOf(context).scale(14) - 14) *
                        2,
                selectedIndex: _tab,
                onDestinationSelected: (index) => setState(() => _tab = index),
                destinations: [
                  NavigationDestination(
                    icon: const Icon(Icons.devices_outlined),
                    selectedIcon: const Icon(Icons.devices_rounded),
                    label: t('Devices', 'الأجهزة'),
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.folder_outlined),
                    selectedIcon: const Icon(Icons.folder_rounded),
                    label: t('Files', 'الملفات'),
                  ),
                  NavigationDestination(
                    icon: const Icon(Icons.settings_outlined),
                    selectedIcon: const Icon(Icons.settings_rounded),
                    label: t('Settings', 'الإعدادات'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _heading(ThemeData theme, String title, {required bool wide}) =>
      Padding(
        padding: EdgeInsets.only(bottom: wide ? 20 : 16),
        child: Semantics(
          header: true,
          child: Text(title,
              textAlign: wide ? TextAlign.center : null,
              style: (wide
                      ? theme.textTheme.headlineMedium
                      : theme.textTheme.headlineSmall)
                  ?.copyWith(fontWeight: FontWeight.w700)),
        ),
      );

  List<Widget> _signIn(ThemeData theme, {required bool wide}) {
    final login = _account.pendingLogin;
    final enrollment = _account.enrollment;
    final signInCode = login?['verificationCode'] as String?;
    final approvalCode = enrollment != null && enrollment['proof'] == null
        ? (enrollment['verificationCode'] as String?)
        : null;
    return [
      if (!_config.valid)
        _Panel(children: [Text(_message('configuration_missing'))])
      else if (login != null)
        _Panel(children: [
          Text(t('Continue in your browser', 'تابع في المتصفح'),
              style: theme.textTheme.headlineSmall),
          if (signInCode != null) ...[
            Text(t('Confirm the same code before approving sign-in.',
                'تأكّد من تطابق الرمز قبل الموافقة على تسجيل الدخول.')),
            _Code(signInCode),
          ] else
            Text(t('Continue with the same Rymu account you use on Windows.',
                'تابع بحساب ريمو نفسه الذي تستخدمه على ويندوز.')),
          FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(() => _openBrowser(login['url'] as String)),
              child: Text(t('Open browser', 'فتح المتصفح'))),
          _restartButton(),
        ])
      else if (_account.accountEnrollment)
        _Panel(children: [
          Text(t('Finish signing in', 'إكمال تسجيل الدخول'),
              style: theme.textTheme.headlineSmall),
          Text(t('Connect this device to your Rymu account.',
              'اربط هذا الجهاز بحساب ريمو.')),
          FilledButton(
              onPressed: _busy ? null : () => _run(_completePhoneSetup),
              child: Text(t('Finish sign-in', 'إكمال تسجيل الدخول'))),
          _restartButton(),
        ])
      else if (approvalCode != null)
        _Panel(children: [
          Text(t('Trust this device', 'الوثوق بهذا الجهاز'),
              style: theme.textTheme.headlineSmall),
          Text(t('Approve this device in your Rymu account using this code.',
              'وافق على الجهاز في حساب ريمو باستخدام هذا الرمز.')),
          _Code(approvalCode),
          FilledButton(
              onPressed: _busy
                  ? null
                  : () =>
                      _run(() => _openBrowser(enrollment!['url'] as String)),
              child: Text(t('Open account', 'فتح الحساب'))),
          TextButton(
              onPressed: _busy ? null : () => _tryApproval(quiet: false),
              child: Text(t('Check approval', 'التحقّق من الموافقة'))),
          _restartButton(),
        ])
      else if (enrollment != null)
        _Panel(children: [
          Text(t('Name this device', 'سمِّ هذا الجهاز'),
              style: theme.textTheme.headlineSmall),
          TextField(
            controller: _alias,
            decoration:
                InputDecoration(labelText: t('Device name', 'اسم الجهاز')),
            textCapitalization: TextCapitalization.words,
            maxLength: 60,
          ),
          FilledButton(
              onPressed: _busy
                  ? null
                  : () {
                      final alias = _alias.text.trim();
                      _run(() => _account.beginEnrollment(alias.isEmpty
                          ? t('Android device', 'جهاز أندرويد')
                          : alias));
                    },
              child: Text(t('Request trust', 'طلب الموافقة'))),
          _restartButton(),
        ])
      else
        _signInWelcome(theme, wide: wide),
    ];
  }

  Widget _signInWelcome(ThemeData theme, {required bool wide}) {
    final content = [
      Text(t('Connect to your computer', 'اتصل بكمبيوترك'),
          style: theme.textTheme.headlineSmall
              ?.copyWith(fontWeight: FontWeight.w700)),
      Text(
        t('Use the same Rymu account as on Windows.',
            'استخدم حساب ريمو نفسه الذي تستخدمه على ويندوز.'),
        style: theme.textTheme.bodyMedium
            ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
      ),
      const SizedBox(height: 2),
      FilledButton(
          onPressed: _busy ? null : () => _run(_startSignIn),
          child: Text(t('Sign in', 'تسجيل الدخول'))),
    ];
    if (!wide) return _Panel(children: content);

    final palette = RymuGlassPalette(theme.brightness);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: RymuGlass(
          radius: 26,
          padding: const EdgeInsets.all(24),
          child: Row(children: [
            ExcludeSemantics(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: palette.tint,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: SizedBox.square(
                  dimension: 136,
                  child: Icon(Icons.devices_outlined,
                      color: palette.ink, size: 62),
                ),
              ),
            ),
            const SizedBox(width: 26),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < content.length; i++) ...[
                    if (i > 0) const SizedBox(height: 10),
                    content[i],
                  ],
                ],
              ),
            ),
          ]),
        ),
      ),
    );
  }

  Widget _restartButton() => TextButton(
        onPressed: _busy ? null : () => _run(_account.clearLocal),
        child: Text(t('Start over', 'البدء من جديد')),
      );

  List<Widget> _deviceList(ThemeData theme,
          {required bool files, required bool wide}) =>
      [
        _heading(
          theme,
          files ? t('File transfer', 'نقل الملفات') : t('My devices', 'أجهزتي'),
          wide: wide,
        ),
        if (files) ...[
          _receivingFolderPanel(),
          const SizedBox(height: 12),
        ],
        if (_hostsCurrent &&
            _connection == null &&
            _hosts.any((host) => host.connectable))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _Panel(children: [Text(_message('transport_unconfigured'))]),
          ),
        if (_hosts.isEmpty && (_hostsCurrent || _notice == null))
          Center(
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: wide ? 520 : double.infinity),
              child: _Panel(children: [
                Text(t('No Windows computers yet', 'لا توجد أجهزة ويندوز بعد'),
                    style: theme.textTheme.titleMedium),
                Text(t(
                    'On Windows, sign in to the same Rymu account and select Start hosting.',
                    'على ويندوز، سجّل الدخول إلى حساب ريمو نفسه واختر «بدء الاستضافة».')),
              ]),
            ),
          )
        else if (_hosts.isNotEmpty && wide)
          _deviceGrid(theme, files: files)
        else
          for (final host in _hosts) ...[
            _hostCard(theme, host, files: files),
            const SizedBox(height: 12),
          ],
        if (_hostsCurrent &&
            _hosts.isNotEmpty &&
            _hosts.every((host) => !host.connectable) &&
            _hosts.any((host) => host.state != 'pending'))
          Padding(
            padding:
                EdgeInsets.symmetric(horizontal: 2, vertical: wide ? 12 : 4),
            child: Text(
              t('To bring a computer online, start hosting in Rymu on Windows.',
                  'ليظهر الكمبيوتر متصلاً، اختر «بدء الاستضافة» في ريمو على ويندوز.'),
              textAlign: wide ? TextAlign.center : null,
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
          ),
      ];

  Widget _deviceGrid(ThemeData theme, {required bool files}) {
    return LayoutBuilder(builder: (context, bounds) {
      const gap = 16.0;
      final scaled = MediaQuery.textScalerOf(context).scale(14) > 20;
      final columns =
          scaled ? 1 : math.min(_hosts.length, bounds.maxWidth >= 840 ? 3 : 2);
      final tileWidth = columns == 1
          ? math.min(bounds.maxWidth, 560.0)
          : (bounds.maxWidth - (columns - 1) * gap) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        alignment: WrapAlignment.center,
        children: [
          for (final host in _hosts)
            SizedBox(
              width: tileWidth,
              child: _hostCard(theme, host, files: files, tile: true),
            ),
        ],
      );
    });
  }

  Widget _hostCard(ThemeData theme, AndroidHost host,
      {required bool files, bool tile = false}) {
    final status = !_hostsCurrent
        ? t('Status unavailable', 'الحالة غير متاحة')
        : host.state == 'pending'
            ? t('Pending approval', 'بانتظار الموافقة')
            : host.online
                ? host.connectable
                    ? t('Online', 'متصل')
                    : t('Connection unavailable', 'الاتصال غير متاح')
                : t('Offline', 'غير متصل');
    final count = host.displayCount;
    final online = _hostsCurrent && host.connectable;
    final canConnect = online && _connection != null;
    return RymuGlass(
      padding: EdgeInsets.all(tile ? 18 : 14),
      child: LayoutBuilder(builder: (context, constraints) {
        final palette = RymuGlassPalette.of(context);
        final secondary =
            theme.textTheme.bodySmall?.copyWith(color: palette.muted);
        final lastSeen = host.lastSeenAt;
        final statusLabel = Row(children: [
          Icon(
            online ? Icons.circle : Icons.circle_outlined,
            size: 8,
            color: online ? palette.ink : palette.muted,
          ),
          const SizedBox(width: 5),
          Flexible(child: Text(status, style: secondary)),
        ]);
        final alias = Text(host.alias,
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w600),
            maxLines: tile ? 1 : 2,
            overflow: TextOverflow.ellipsis);
        final details = Row(
          crossAxisAlignment:
              tile ? CrossAxisAlignment.start : CrossAxisAlignment.center,
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: palette.tint,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Icon(Icons.desktop_windows_outlined,
                  size: 22, color: palette.ink),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (tile)
                    Tooltip(message: host.alias, child: alias)
                  else
                    alias,
                  const SizedBox(height: 3),
                  if (!tile) statusLabel,
                  if (!files && online && count != null && count > 0)
                    Text(
                      count == 1
                          ? t('1 display', 'شاشة واحدة')
                          : t('$count displays', 'عدد الشاشات $count'),
                      style: secondary,
                    ),
                  if (!host.online && lastSeen != null)
                    Text(
                      t('Last seen ${_shortTime(context, lastSeen)}',
                          'آخر ظهور ${_shortTime(context, lastSeen)}'),
                      style: secondary,
                      maxLines: tile ? 1 : null,
                      overflow: tile ? TextOverflow.ellipsis : null,
                    ),
                ],
              ),
            ),
          ],
        );
        if (!tile && !canConnect) return details;
        final connect = FilledButton(
          onPressed:
              _busy || !canConnect ? null : () => _connect(host, files: files),
          child: Text(
              files ? t('Open files', 'فتح الملفات') : t('Connect', 'اتصال')),
        );
        if (tile) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              details,
              const SizedBox(height: 12),
              Divider(height: 1, color: palette.line),
              const SizedBox(height: 8),
              Row(children: [
                Expanded(child: statusLabel),
                const SizedBox(width: 8),
                connect,
              ]),
            ],
          );
        }
        if (constraints.maxWidth < 250 ||
            MediaQuery.textScalerOf(context).scale(14) > 20) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [details, const SizedBox(height: 12), connect],
          );
        }
        return Row(children: [
          Expanded(child: details),
          const SizedBox(width: 10),
          connect,
        ]);
      }),
    );
  }

  String _shortTime(BuildContext context, int epoch) {
    final when = DateTime.fromMillisecondsSinceEpoch(epoch);
    final localization = MaterialLocalizations.of(context);
    return '${localization.formatShortDate(when)} ${localization.formatTimeOfDay(TimeOfDay.fromDateTime(when))}';
  }

  Future<void> _editTransport(BuildContext context) => _run(() async {
        final values = [
          _transport.rendezvous,
          _transport.relay,
          _transport.serverKey
        ];
        final labels = [
          t('Rendezvous server', 'خادم التعارف'),
          t('Relay server', 'خادم التمرير'),
          t('Server public key', 'المفتاح العام للخادم'),
        ];
        final route = await showDialog<AndroidTransportSettings>(
          context: context,
          builder: (dialogContext) => Directionality(
            textDirection: _arabic ? TextDirection.rtl : TextDirection.ltr,
            child: AlertDialog(
              insetPadding: const EdgeInsets.all(16),
              title: Text(t('Private connection server', 'خادم الاتصال الخاص')),
              scrollable: true,
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < labels.length; i++) ...[
                    if (i > 0) const SizedBox(height: 12),
                    TextFormField(
                      initialValue: values[i],
                      textDirection: TextDirection.ltr,
                      decoration: InputDecoration(labelText: labels[i]),
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (value) => values[i] = value,
                    ),
                  ],
                ],
              ),
              actions: [
                if (_transport.configured)
                  TextButton(
                      onPressed: () => Navigator.of(dialogContext)
                          .pop(const AndroidTransportSettings('', '', '')),
                      child:
                          Text(t('Use Rymu connection', 'استخدام اتصال ريمو'))),
                TextButton(
                    onPressed: () => Navigator.of(dialogContext).pop(),
                    child: Text(t('Cancel', 'إلغاء'))),
                FilledButton(
                    onPressed: () => Navigator.of(dialogContext).pop(
                        AndroidTransportSettings(values[0].trim(),
                            values[1].trim(), values[2].trim())),
                    child: Text(t('Save', 'حفظ'))),
              ],
            ),
          ),
        );
        if (route == null || !mounted) return;
        try {
          if ([route.rendezvous, route.relay, route.serverKey]
              .every((value) => value.isEmpty)) {
            RymuNative.clearTransport();
          } else {
            RymuNative.configureTransport(
              AccountTransport.manual(
                  route.rendezvous, route.relay, route.serverKey),
            );
          }
        } on RymuNativeException {
          throw const AccountProblem('transport_invalid');
        }
        await bind.mainSetLocalOption(
            key: AndroidTransportSettings.localOption,
            value: route.toLocalOption());
        _transport = route;
        if (!route.configured && _account.session != null) {
          await _reload(sendPresence: false);
        }
      });

  Widget _receivingFolderPanel() {
    final selected = RymuReceivingFolder.selected;
    return _Panel(children: [
      Text(t('Receiving folder', 'مجلد الاستلام'),
          style: Theme.of(context).textTheme.titleMedium),
      Text(
          selected == null
              ? t('Rymu workspace', 'مساحة ريمو')
              : AndroidDocuments.displayPath(selected),
          textDirection: TextDirection.ltr),
      Text(t(
          'Choose a folder once. Later transfers reuse it while Android access remains allowed. During a transfer, the folder button opens it immediately.',
          'اختر المجلد مرة واحدة؛ يُستخدم في النقل اللاحق ما دامت صلاحية أندرويد متاحة. أثناء النقل يفتحه زر المجلد مباشرة.')),
      Wrap(spacing: 8, runSpacing: 4, children: [
        OutlinedButton.icon(
          onPressed: _busy
              ? null
              : () => _run(() async {
                    final chosen = await AndroidDocuments.selectFolder();
                    final path = chosen?['path'];
                    if (path is String) {
                      await RymuReceivingFolder.remember(path);
                    }
                  }),
          icon: const Icon(Icons.folder_open_outlined),
          label: Text(t('Change folder', 'تغيير المجلد')),
        ),
        if (selected != null)
          TextButton(
              onPressed:
                  _busy ? null : () => _run(RymuReceivingFolder.useWorkspace),
              child: Text(t('Use Rymu workspace', 'استخدام مساحة ريمو'))),
      ]),
    ]);
  }

  List<Widget> _settings(BuildContext context, ThemeData theme,
      {required bool wide}) {
    // Two columns at tablet widths only while their labels have room to wrap.
    wide = wide && MediaQuery.textScalerOf(context).scale(14) < 21;
    final preferences = _Panel(children: [
      if (wide)
        Text(t('Preferences', 'التفضيلات'),
            style: theme.textTheme.titleMedium
                ?.copyWith(fontWeight: FontWeight.w700)),
      Text(t('App language', 'لغة التطبيق')),
      DropdownButtonFormField<String>(
        key: _languagePicker,
        value: _language,
        isExpanded: true,
        isDense: false,
        itemHeight: null,
        decoration: const InputDecoration(),
        onChanged: _busy
            ? null
            : (value) {
                if (value != null && value != _language) {
                  unawaited(_changeLanguage(value));
                }
              },
        items: [
          DropdownMenuItem(
              value: 'auto',
              child: Text(t('Use device language', 'لغة الجهاز'))),
          const DropdownMenuItem(value: 'en', child: Text('English')),
          const DropdownMenuItem(value: 'ar', child: Text('العربية')),
        ],
      ),
      SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(t('View only by default', 'عرض فقط افتراضياً')),
          value: _viewOnly,
          onChanged: _busy
              ? null
              : (value) => _run(() async {
                    await bind.mainSetLocalOption(
                        key: 'rymu-mobile-view-only', value: value ? 'Y' : 'N');
                    _viewOnly = value;
                  })),
    ]);
    final advanced = ListTile(
      contentPadding: EdgeInsets.zero,
      leading: const Icon(Icons.tune_rounded),
      title: Text(t('Advanced connection', 'إعدادات الاتصال المتقدمة')),
      subtitle: Text(_transport.configured
          ? t('Private server', 'خادم خاص')
          : _connection != null
              ? t('Managed by Rymu', 'اتصال ريمو التلقائي')
              : t('Connection settings', 'إعدادات الاتصال')),
      trailing: const Icon(Icons.chevron_right_rounded),
      onTap: _busy ? null : () => _editTransport(context),
    );
    final accountActions = [
      if (_config.valid)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.person_outline_rounded),
          title: Text(t('Manage trusted devices', 'إدارة الأجهزة الموثوقة')),
          trailing: const Icon(Icons.open_in_new_rounded),
          onTap: _busy
              ? null
              : () => _run(() =>
                  _openBrowser(_config.site.resolve('/account').toString())),
        ),
      if (_account.session != null)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.logout_rounded),
          title: Text(t('Sign out', 'تسجيل الخروج')),
          onTap: _busy
              ? null
              : () => _run(() async {
                    final hadConnection = _connection != null;
                    try {
                      await _account.signOut();
                    } on AccountProblem {
                      _notice = 'signed_out_locally';
                    } finally {
                      _hosts = [];
                      _hostsCurrent = false;
                      if (hadConnection) RymuNative.clearTransport();
                    }
                  }),
        ),
    ];

    return [
      _heading(theme, t('Settings', 'الإعدادات'), wide: wide),
      if (wide)
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: preferences),
            const SizedBox(width: 16),
            Expanded(
              child: _Panel(children: [
                Text(t('Connection & account', 'الاتصال والحساب'),
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w700)),
                advanced,
                ...accountActions,
              ]),
            ),
          ],
        )
      else ...[
        preferences,
        const SizedBox(height: 12),
        _Panel(children: [advanced]),
        if (accountActions.isNotEmpty) ...[
          const SizedBox(height: 12),
          _Panel(children: accountActions),
        ],
      ],
      const SizedBox(height: 12),
      _receivingFolderPanel(),
      const SizedBox(height: 12),
      _Panel(children: [RymuAttribution(arabic: _arabic)]),
      if (_config.valid)
        Align(
          alignment: wide ? Alignment.center : AlignmentDirectional.centerStart,
          child: TextButton(
            onPressed: _busy
                ? null
                : () => _run(() =>
                    _openBrowser(_config.site.resolve('/source').toString())),
            child: Text(
                t('RustDesk source and licenses', 'مصدر RustDesk والتراخيص')),
          ),
        ),
    ];
  }
}

class _Panel extends StatelessWidget {
  const _Panel({required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => RymuGlass(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(height: 10),
              children[i],
            ],
          ],
        ),
      );
}

class _Code extends StatelessWidget {
  const _Code(this.value);
  final String value;
  @override
  Widget build(BuildContext context) => SelectableText(value,
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      style: Theme.of(context)
          .textTheme
          .headlineMedium
          ?.copyWith(letterSpacing: 3));
}
