import 'dart:async';

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common/shared_state.dart';
import 'package:flutter_hbb/common/widgets/toolbar.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse.dart';
import 'package:flutter_hbb/mobile/widgets/floating_mouse_widgets.dart';
import 'package:flutter_hbb/mobile/widgets/gesture_help.dart';
import 'package:flutter_hbb/models/chat_model.dart';
import 'package:flutter_keyboard_visibility/flutter_keyboard_visibility.dart';
import 'package:flutter_svg/svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';

import '../../common.dart';
import '../../rymu/glass.dart';
import '../../rymu_android/appearance.dart';
import '../../rymu_android/monitor_overview.dart';
import '../../rymu_android/remote_keyboard.dart';
import '../../rymu_android/screen_privacy.dart';
import '../../rymu_android/session_bar.dart';
import '../../rymu_android/touch_surface.dart';
import '../../common/widgets/overlay.dart';
import '../../common/widgets/dialog.dart';
import '../../common/widgets/remote_input.dart';
import '../../models/input_model.dart';
import '../../models/model.dart';
import '../../models/platform_model.dart';
import '../../models/shortcut_model.dart';
import '../../utils/image.dart';
import '../widgets/dialog.dart';
import '../widgets/custom_scale_widget.dart';

final initText = '1' * 1024;

// Workaround for Android (default input method, Microsoft SwiftKey keyboard) when using physical keyboard.
// When connecting a physical keyboard, `KeyEvent.physicalKey.usbHidUsage` are wrong is using Microsoft SwiftKey keyboard.
// https://github.com/flutter/flutter/issues/159384
// https://github.com/flutter/flutter/issues/159383
void _disableAndroidSoftKeyboard({bool? isKeyboardVisible}) {
  if (isAndroid) {
    if (isKeyboardVisible != true) {
      // `enable_soft_keyboard` will be set to `true` when clicking the keyboard icon, in `openKeyboard()`.
      gFFI.invokeMethod("enable_soft_keyboard", false);
    }
  }
}

bool handleMobileLocalKeyEvent(KeyEvent event,
    {required bool remoteFocused, required InputModel inputModel}) {
  if (event is KeyUpEvent && inputModel.isViewOnly) {
    // View-only skips normal modifier cleanup; stale physical keys would
    // otherwise look like touch selections in the input helper.
    inputModel.handleKeyUpEventModifiers(event);
  }
  if (!remoteFocused &&
      event is KeyUpEvent &&
      const [
        PhysicalKeyboardKey.controlLeft,
        PhysicalKeyboardKey.controlRight,
        PhysicalKeyboardKey.altLeft,
        PhysicalKeyboardKey.altRight,
        PhysicalKeyboardKey.shiftLeft,
        PhysicalKeyboardKey.shiftRight,
        PhysicalKeyboardKey.metaLeft,
        PhysicalKeyboardKey.metaRight,
      ].contains(event.physicalKey)) {
    // Local UI may consume key-ups while the remote input path still owns
    // the modifiers pressed before focus moved.
    inputModel.handleKeyEvent(event);
  }
  return false;
}

class RemotePage extends StatefulWidget {
  RemotePage(
      {Key? key,
      required this.id,
      this.password,
      this.isSharedPassword,
      this.forceRelay,
      this.rymuName,
      this.rymuHostId,
      this.rymuArabic = false,
      this.rymuViewOnly = false,
      this.rymuRestage})
      : super(key: key);

  final String id;
  final String? password;
  final bool? isSharedPassword;
  final bool? forceRelay;
  final String? rymuName;
  final String? rymuHostId;
  final bool rymuArabic;
  final bool rymuViewOnly;
  final Future<bool> Function()? rymuRestage;

  @override
  State<RemotePage> createState() => _RemotePageState(id);
}

class _RemotePageState extends State<RemotePage> with WidgetsBindingObserver {
  Timer? _timer;
  bool _showBar = !isWebDesktop;
  bool _showGestureHelp = false;
  String _value = '';
  Orientation? _currentOrientation;
  Timer? _viewportResizeTimer;
  final _uniqueKey = UniqueKey();
  Timer? _iosKeyboardWorkaroundTimer;

  final _blockableOverlayState = BlockableOverlayState();

  final keyboardVisibilityController = KeyboardVisibilityController();
  late final StreamSubscription<bool> keyboardSubscription;
  final FocusNode _mobileFocusNode = FocusNode();
  final FocusNode _physicalFocusNode = FocusNode();
  var _showEdit = false; // use soft keyboard

  Worker? _waylandKeyboardGateWorker;
  bool _waylandKeyboardGateInitialized = false;
  bool _rymuClipboardEnabled = false;
  String _rymuLanguage = 'auto';
  String _rymuQuality = kRemoteImageQualityBalanced;
  final _rymuKeys = RymuRemoteKeys();
  var _rymuMoreKeys = false;
  var _rymuImeVisible = false;
  var _rymuEditorFocused = false;
  var _rymuKeyboardRequest = 0;
  var _rymuInputEpoch = 0;
  var _rymuClosing = false;
  var _rymuForeground = true;
  Worker? _rymuSessionStateWorker;
  Future<void> _rymuInputQueue = Future.value();
  Set<int>? _rymuIncludedScreens;
  List<Rect> _rymuScreenTopology = const [];
  RymuMonitorOverview? _rymuOverview;
  Completer<bool>? _rymuPrivacyReply;

  bool get _rymu => isAndroid && widget.rymuName != null;
  bool get _rymuReady =>
      gFFI.ffiModel.pi.isSet.isTrue && gFFI.ffiModel.waitForFirstImage.isFalse;
  bool get _rymuCanInput =>
      _rymuReady &&
      _rymuForeground &&
      !_rymuClosing &&
      _rymuPrivacyReply == null &&
      !widget.rymuViewOnly &&
      !gFFI.ffiModel.viewOnly &&
      gFFI.ffiModel.keyboard &&
      inputModel.keyboardInputAllowed;
  String get _rymuPreferenceKey => widget.rymuHostId ?? widget.id;
  String? get _rymuHostLocale {
    final value = gFFI.ffiModel.pi.platformAdditions['rymu_ui_locale'];
    return value is String
        ? value.split(RegExp('[-_]')).first.toLowerCase()
        : null;
  }

  bool get _rymuArabic => switch (_rymuLanguage) {
        'ar' => true,
        'en' => false,
        _ => switch (_rymuHostLocale) {
            'ar' => true,
            'en' => false,
            _ => widget.rymuArabic,
          },
      };
  String _rymuText(String english, String arabic) =>
      rymuCopy(_rymuArabic, english, arabic);

  InputModel get inputModel => gFFI.inputModel;
  SessionID get sessionId => gFFI.sessionId;

  final TextEditingController _textController =
      TextEditingController(text: initText);

  _RemotePageState(String id) {
    initSharedStates(id);
    gFFI.chatModel.voiceCallStatus.value = VoiceCallStatus.notStarted;
    gFFI.dialogManager.loadMobileActionsOverlayVisible();
  }

  @override
  void initState() {
    super.initState();
    if (_rymu) {
      gFFI.ffiModel.setRymuReconnectHandler(widget.rymuRestage);
      gFFI.ffiModel.onRymuPrivacyUpdate = _onRymuPrivacyUpdate;
      PrivacyModeState.find(widget.id).value = '';
      _textController.addListener(_onRymuImeEdit);
      _mobileFocusNode.addListener(_onRymuEditorFocus);
      gFFI.ffiModel.addListener(_onRymuSessionState);
      _rymuSessionStateWorker = everAll(
          [gFFI.ffiModel.pi.isSet, gFFI.ffiModel.waitForFirstImage],
          (_) => _onRymuSessionState());
      final saved = bind.mainGetLocalOption(
          key: 'rymu-session-language-$_rymuPreferenceKey');
      if (saved == 'ar' || saved == 'en') _rymuLanguage = saved;
    }
    gFFI.ffiModel.updateEventListener(sessionId, widget.id);
    gFFI.start(
      widget.id,
      password: widget.password,
      isSharedPassword: widget.isSharedPassword,
      forceRelay: widget.forceRelay,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      gFFI.dialogManager
          .showLoading(translate('Connecting...'), onCancel: closeConnection);
    });
    WakelockManager.enable(_uniqueKey);
    _physicalFocusNode.requestFocus();
    HardwareKeyboard.instance.addHandler(_handleLocalKeyEvent);
    gFFI.inputModel.listenToMouse(true);
    gFFI.qualityMonitorModel.checkShowQualityMonitor(sessionId);
    keyboardSubscription =
        keyboardVisibilityController.onChange.listen(onSoftKeyboardChanged);
    gFFI.chatModel
        .changeCurrentKey(MessageKey(widget.id, ChatModel.clientModeID));
    _blockableOverlayState.applyFfi(gFFI);
    gFFI.imageModel.addCallbackOnFirstImage((String peerId) {
      if (_rymu) {
        unawaited(_prepareRymuSession());
        return;
      }
      gFFI.recordingModel
          .updateStatus(bind.sessionGetIsRecording(sessionId: gFFI.sessionId));
      if (gFFI.recordingModel.start) {
        showToast(translate('Automatically record outgoing sessions'));
      }
      _disableAndroidSoftKeyboard(
          isKeyboardVisible: keyboardVisibilityController.isVisible);
      // Seed shortcut action callbacks once the session is ready, so that
      // global keyboard shortcuts work even if the user never opens the
      // toolbar menu. The returned list is intentionally discarded — the
      // side effect of registering callbacks (inside toolbarControls) is
      // what we want here.
      if (mounted) {
        toolbarControls(context, widget.id, gFFI);
        // Mobile has no DesktopTabController, so tab-switch shortcuts will
        // log a no-handler debug line if a user binds one.
        registerSessionShortcutActions(gFFI);
        _registerMobileChatShortcut();
        registerToolbarShortcuts(context, widget.id, gFFI);
      }
    });
    WidgetsBinding.instance.addObserver(this);

    inputModel.keyboardInputAllowed = true;

    // Wayland sessions may use clipboard-based text input on the controlled side.
    // Require explicit user confirmation before allowing soft-keyboard and
    // clipboard-assisted text input. Physical keyboard events are not gated here.
    _waylandKeyboardGateWorker = ever(gFFI.ffiModel.pi.isSet, (bool isSet) {
      if (isSet) {
        _initWaylandKeyboardGateIfNeeded();
      }
    });
    if (gFFI.ffiModel.pi.isSet.value) {
      _initWaylandKeyboardGateIfNeeded();
    }
  }

  @override
  Future<void> dispose() async {
    _viewportResizeTimer?.cancel();
    HardwareKeyboard.instance.removeHandler(_handleLocalKeyEvent);
    WidgetsBinding.instance.removeObserver(this);
    if (_rymu) {
      _rymuClosing = true;
      _clearRymuOverview();
      gFFI.canvasModel.rymuMobileViewport = null;
      _rymuKeys.clear();
      _textController.removeListener(_onRymuImeEdit);
      _mobileFocusNode.removeListener(_onRymuEditorFocus);
      gFFI.ffiModel.removeListener(_onRymuSessionState);
      gFFI.ffiModel.onRymuPrivacyUpdate = null;
      _cancelRymuPrivacyRequest();
      _rymuSessionStateWorker?.dispose();
      gFFI.ffiModel.setRymuReconnectHandler(null);
      inputModel.enterOrLeave(false);
      unawaited(gFFI.invokeMethod('rymu_clipboard_active', false));
    }
    // Close the session up-front. `gFFI.close()` below only calls `sessionClose`
    // after several awaits (canvas save, image update, the `enable_soft_keyboard`
    // platform call), so if the app is backgrounded while this page is disposing,
    // dispose can be suspended before reaching it and the connection is never torn
    // down. The reconnect then re-attaches to the leaked session and is stuck on
    // "Connecting...". Dispatching it here makes teardown happen synchronously on
    // pop; the `sessionClose` in `gFFI.close()` becomes a no-op once removed.
    unawaited(bind.sessionClose(sessionId: sessionId));
    // https://github.com/flutter/flutter/issues/64935
    super.dispose();
    gFFI.dialogManager.hideMobileActionsOverlay(store: false);
    gFFI.inputModel.listenToMouse(false);
    gFFI.imageModel.disposeImage();
    gFFI.cursorModel.disposeImages();
    await gFFI.invokeMethod("enable_soft_keyboard", true);
    _mobileFocusNode.dispose();
    _physicalFocusNode.dispose();
    _textController.dispose();
    clearWaylandKeyboardPromptSuppressedForConnection(sessionId.toString());
    _waylandKeyboardGateWorker?.dispose();
    inputModel.keyboardInputAllowed = true;
    await gFFI.close();
    _timer?.cancel();
    _iosKeyboardWorkaroundTimer?.cancel();
    gFFI.dialogManager.dismissAll();
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
        overlays: SystemUiOverlay.values);
    WakelockManager.disable(_uniqueKey);
    await keyboardSubscription.cancel();
    removeSharedStates(widget.id);
    // `on_voice_call_closed` should be called when the connection is ended.
    // The inner logic of `on_voice_call_closed` will check if the voice call is active.
    // Only one client is considered here for now.
    gFFI.chatModel.onVoiceCallClosed("End connection");
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_rymu) {
      final foreground = state == AppLifecycleState.resumed;
      if (!mounted || foreground == _rymuForeground) return;
      setState(() => _rymuForeground = foreground);
      if (!_rymuForeground) {
        _hideRymuKeyboard(restoreFocus: false);
        inputModel.enterOrLeave(false);
      }
      return;
    }
    if (state == AppLifecycleState.resumed) {
      trySyncClipboard();
    }
  }

  // For client side
  // When swithing from other app to this app, try to sync clipboard.
  void trySyncClipboard() {
    gFFI.invokeMethod("try_sync_clipboard");
  }

  Future<void> _prepareRymuSession() async {
    if (!mounted) return;
    final preferences = 'rymu-touch-$_rymuPreferenceKey';
    final touch = bind.mainGetLocalOption(key: preferences) != 'mouse';
    if (gFFI.ffiModel.touchMode != touch) gFFI.ffiModel.toggleTouchMode();
    await bind.mainSetLocalOption(
        key: kCommConfKeyLang, value: _rymuArabic ? 'ar' : 'en');
    if (!mounted) return;
    await bind.sessionSetKeyboardMode(sessionId: sessionId, value: kKeyMapMode);
    if (!mounted) return;
    inputModel.keyboardMode =
        await bind.sessionGetKeyboardMode(sessionId: sessionId) ??
            kKeyLegacyMode;
    final quality = await bind.sessionGetImageQuality(sessionId: sessionId);
    if (quality == kRemoteImageQualityLow ||
        quality == kRemoteImageQualityBest) {
      _rymuQuality = quality!;
    } else {
      await bind.sessionSetImageQuality(
          sessionId: sessionId, value: _rymuQuality);
    }
    if (!mounted) return;
    await _setRymuClipboard(false);
    if (mounted) setState(() {});
  }

  Future<void> _setRymuClipboard(bool enabled) async {
    final disabled = bind.sessionGetToggleOptionSync(
            sessionId: sessionId, arg: kOptionDisableClipboard) ==
        true;
    if (disabled == enabled) {
      await bind.sessionToggleOption(
          sessionId: sessionId, value: kOptionDisableClipboard);
    }
    if (mounted) await gFFI.invokeMethod('rymu_clipboard_active', enabled);
    if (mounted) setState(() => _rymuClipboardEnabled = enabled);
  }

  bool _shouldGateKeyboardForWayland() {
    if (!(isAndroid || isIOS)) return false;
    final pi = gFFI.ffiModel.pi;
    return pi.platform == kPeerPlatformLinux && pi.isWayland;
  }

  void _initWaylandKeyboardGateIfNeeded() {
    if (!mounted) return;
    if (_waylandKeyboardGateInitialized) return;
    if (!_shouldGateKeyboardForWayland()) return;

    _waylandKeyboardGateInitialized = true;

    final allowWaylandKeyboard =
        mainGetPeerBoolOptionSync(widget.id, kPeerOptionAllowWaylandKeyboard);
    if (!shouldShowWaylandKeyboardPrompt(
      connectionId: sessionId.toString(),
      isWaylandPeer: _shouldGateKeyboardForWayland(),
      allowWaylandKeyboardRemembered: allowWaylandKeyboard,
    )) {
      inputModel.keyboardInputAllowed = true;
      return;
    }

    inputModel.keyboardInputAllowed = false;

    // Ensure soft keyboard is not active before user confirms.
    _showEdit = false;
    gFFI.invokeMethod("enable_soft_keyboard", false);
    _mobileFocusNode.unfocus();
    _physicalFocusNode.requestFocus();
    setState(() {});
  }

  // to-do: It should be better to use transparent color instead of the bgColor.
  // But for now, the transparent color will cause the canvas to be white.
  // I'm sure that the white color is caused by the Overlay widget in BlockableOverlay.
  // But I don't know why and how to fix it.
  Widget emptyOverlay(Color bgColor) => BlockableOverlay(
        /// the Overlay key will be set with _blockableOverlayState in BlockableOverlay
        /// see override build() in [BlockableOverlay]
        state: _blockableOverlayState,
        underlying: Container(
          color: bgColor,
        ),
      );

  void onSoftKeyboardChanged(bool visible) {
    if (!mounted) return;
    if (_rymu) {
      if (!_showEdit) return;
      if (visible) {
        _rymuImeVisible = true;
      } else if (_rymuImeVisible) {
        _hideRymuKeyboard();
      }
      return;
    }
    if (!visible) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: []);
      // [pi.version.isNotEmpty] -> check ready or not, avoid login without soft-keyboard
      if (gFFI.chatModel.chatWindowOverlayEntry == null &&
          gFFI.ffiModel.pi.version.isNotEmpty) {
        gFFI.invokeMethod("enable_soft_keyboard", false);
      }

      // Workaround for iOS: physical keyboard input fails after virtual keyboard is hidden
      // https://github.com/flutter/flutter/issues/39900
      // https://github.com/rustdesk/rustdesk/discussions/11843#discussioncomment-13499698 - Virtual keyboard issue
      if (isIOS) {
        _iosKeyboardWorkaroundTimer?.cancel();
        _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 100), () {
          if (!mounted || gFFI.chatModel.inputNode.hasFocus) return;
          _physicalFocusNode.unfocus();
          _iosKeyboardWorkaroundTimer = Timer(Duration(milliseconds: 50), () {
            if (!mounted || gFFI.chatModel.inputNode.hasFocus) return;
            _physicalFocusNode.requestFocus();
          });
        });
      }
    } else {
      _iosKeyboardWorkaroundTimer?.cancel();
      _iosKeyboardWorkaroundTimer = null;
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
            overlays: SystemUiOverlay.values);
        _mobileFocusNode.requestFocus();
      });
    }
    // update for Scaffold
    setState(() {});
  }

  void _onRymuSessionState() {
    if (mounted && !_rymuCanInput) _hideRymuKeyboard(restoreFocus: false);
    if (!_rymuReady) _cancelRymuPrivacyRequest();
    final overview = _rymuOverview;
    if (overview != null &&
        (!_rymuReady || !listEquals(overview.displays, _screenTopology(gFFI.ffiModel.pi)))) {
      _clearRymuOverview();
      if (mounted) setState(() {});
      final peer = gFFI.ffiModel.pi;
      if (_rymuReady && peer.displays.isNotEmpty) {
        _switchRymuDisplay(peer, 0);
      }
    }
  }

  bool get _rymuPrivacyActive => _rymuReady &&
      PrivacyModeState.find(widget.id).value == rymuPrivacyOverlay;

  bool get _rymuPrivacyAvailable {
    final peer = gFFI.ffiModel.pi;
    final implementations =
        peer.platformAdditions[kPlatformAdditionsSupportedPrivacyModeImpl];
    return _rymuCanInput &&
        peer.features.privacyMode &&
        gFFI.ffiModel.permissions['privacy_mode'] == true &&
        implementations is List &&
        implementations.any((entry) =>
            entry is List && entry.isNotEmpty && entry.first == rymuPrivacyOverlay);
  }

  void _onRymuPrivacyUpdate() {
    final reply = _rymuPrivacyReply;
    if (reply != null && !reply.isCompleted) {
      reply.complete(_rymuPrivacyActive);
    }
    if (mounted) setState(() {});
  }

  void _cancelRymuPrivacyRequest() {
    final reply = _rymuPrivacyReply;
    if (reply != null && !reply.isCompleted) {
      reply.completeError(StateError('Session disconnected'));
    }
  }

  Future<bool> _setRymuPrivacy(bool enabled) async {
    if (_rymuPrivacyReply != null || !_rymuReady ||
        (enabled && !_rymuPrivacyAvailable)) {
      throw StateError('Screen privacy is unavailable');
    }
    final reply = Completer<bool>();
    setState(() => _rymuPrivacyReply = reply);
    // Register the timeout before sending so a synchronous disconnect is handled.
    final result = reply.future.timeout(const Duration(seconds: 10));
    try {
      final results = await Future.wait<dynamic>([
        bind.sessionTogglePrivacyMode(
            sessionId: sessionId, implKey: rymuPrivacyOverlay, on: enabled),
        result,
      ], eagerError: true);
      final confirmed = results.last as bool;
      if (!enabled && !confirmed && mounted && _rymuReady && !_rymuClosing) {
        gFFI.ffiModel.setRymuReconnectHandler(widget.rymuRestage);
      }
      return confirmed;
    } finally {
      if (identical(_rymuPrivacyReply, reply)) {
        _rymuPrivacyReply = null;
        if (mounted) setState(() {});
      }
    }
  }

  void _onRymuEditorFocus() {
    if (!_showEdit) return;
    if (_mobileFocusNode.hasFocus) {
      _rymuEditorFocused = true;
    } else if (_rymuEditorFocused) {
      _hideRymuKeyboard(restoreFocus: false);
    }
  }

  Future<void> _openRymuKeyboard() async {
    if (!_rymuCanInput || _showEdit) return;
    final request = ++_rymuKeyboardRequest;
    await gFFI.invokeMethod('enable_soft_keyboard', true);
    if (!mounted || request != _rymuKeyboardRequest || !_rymuCanInput) return;
    _rymuKeys.clear();
    _textController.value = RymuRemoteKeys.editorValue;
    setState(() => _showEdit = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_showEdit || request != _rymuKeyboardRequest) return;
      _mobileFocusNode.requestFocus();
    });
  }

  void _hideRymuKeyboard({bool restoreFocus = true}) {
    _rymuKeyboardRequest++;
    if (!restoreFocus) _rymuInputEpoch++;
    _rymuKeys.clear();
    _rymuImeVisible = false;
    _rymuEditorFocused = false;
    if (!_showEdit || !mounted) return;
    setState(() {
      _showEdit = false;
      _rymuMoreKeys = false;
    });
    _mobileFocusNode.unfocus();
    unawaited(SystemChannels.textInput.invokeMethod<void>('TextInput.hide'));
    unawaited(gFFI.invokeMethod('enable_soft_keyboard', false));
    if (restoreFocus) _physicalFocusNode.requestFocus();
  }

  void _onRymuImeEdit() {
    if (!_showEdit || !_mobileFocusNode.hasFocus || !_rymuCanInput) return;
    final edit = _rymuKeys.commit(_textController.value);
    if (edit == null) return;
    _textController.value = RymuRemoteKeys.editorValue;
    _sendRymuKeyboardInput(edit);
  }

  void _sendRymuKeyboardInput(RymuKeyboardInput event) {
    if (!_rymuCanInput) return;
    setState(() {});
    final activeSession = sessionId;
    final epoch = _rymuInputEpoch;
    final alt = inputModel.alt;
    final ctrl = inputModel.ctrl;
    final shift = inputModel.shift;
    final command = inputModel.command;
    _rymuInputQueue = _rymuInputQueue.then((_) async {
      if (!mounted ||
          !_rymuCanInput ||
          activeSession != sessionId ||
          epoch != _rymuInputEpoch) {
        return;
      }
      switch (event) {
        case RymuKeyStroke(:final key, :final modifiers):
          await bind.sessionInputKey(
            sessionId: activeSession,
            name: key,
            down: false,
            press: true,
            alt: modifiers.contains(RymuModifier.alt) || alt,
            ctrl: modifiers.contains(RymuModifier.control) || ctrl,
            shift: modifiers.contains(RymuModifier.shift) || shift,
            command: modifiers.contains(RymuModifier.windows) || command,
          );
        case RymuCommittedText(:final text):
          await bind.sessionInputString(sessionId: activeSession, value: text);
      }
    }).catchError((Object _) {
      debugPrint('Rymu session keyboard input could not be sent.');
    });
  }

  void _handleIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    var i = newValue.length - 1;
    for (; i >= 0 && newValue[i] != '1'; --i) {}
    var j = oldValue.length - 1;
    for (; j >= 0 && oldValue[j] != '1'; --j) {}
    if (i < j) j = i;
    var subNewValue = newValue.substring(j + 1);
    var subOldValue = oldValue.substring(j + 1);

    // get common prefix of subNewValue and subOldValue
    var common = 0;
    for (;
        common < subOldValue.length &&
            common < subNewValue.length &&
            subNewValue[common] == subOldValue[common];
        ++common) {}

    // get newStr from subNewValue
    var newStr = "";
    if (subNewValue.length > common) {
      newStr = subNewValue.substring(common);
    }

    // Set the value to the old value and early return if is still composing. (1 && 2)
    // 1. The composing range is valid
    // 2. The new string is shorter than the composing range.
    if (_textController.value.isComposingRangeValid) {
      final composingLength = _textController.value.composing.end -
          _textController.value.composing.start;
      if (composingLength > newStr.length) {
        _value = oldValue;
        return;
      }
    }

    // Delete the different part in the old value.
    for (i = 0; i < subOldValue.length - common; ++i) {
      inputModel.inputKey('VK_BACK');
    }

    // Input the new string.
    if (newStr.length > 1) {
      bind.sessionInputString(sessionId: sessionId, value: newStr);
    } else {
      inputChar(newStr);
    }
  }

  void _handleNonIOSSoftKeyboardInput(String newValue) {
    var oldValue = _value;
    _value = newValue;
    if (oldValue.isNotEmpty &&
        newValue.isNotEmpty &&
        oldValue[0] == '1' &&
        newValue[0] != '1') {
      // clipboard
      oldValue = '';
    }
    // This length-only diff assumes the IME appends at the end. If an IME
    // leaves the caret inside paired punctuation, later insertions can replay
    // the closing symbol: "()" -> "(a)" sends ")" instead of "a". This is a
    // client text-diff issue, independent of the host keyboard layout.
    if (newValue.length == oldValue.length) {
      // ?
    } else if (newValue.length < oldValue.length) {
      final char = 'VK_BACK';
      inputModel.inputKey(char);
    } else {
      final content = newValue.substring(oldValue.length);
      if (content.length > 1) {
        if (oldValue != '' &&
            content.length == 2 &&
            (content == '""' ||
                content == '()' ||
                content == '[]' ||
                content == '<>' ||
                content == "{}" ||
                content == '”“' ||
                content == '《》' ||
                content == '（）' ||
                content == '【】')) {
          // can not only input content[0], because when input ], [ are also auo insert, which cause ] never be input
          bind.sessionInputString(sessionId: sessionId, value: content);
          _openKeyboardUnlocked();
          return;
        }
        bind.sessionInputString(sessionId: sessionId, value: content);
      } else {
        inputChar(content);
      }
    }
  }

  // handle mobile virtual keyboard
  void handleSoftKeyboardInput(String newValue) {
    if (!inputModel.keyboardInputAllowed) {
      return;
    }
    if (isIOS) {
      _handleIOSSoftKeyboardInput(newValue);
    } else {
      _handleNonIOSSoftKeyboardInput(newValue);
    }
  }

  void inputChar(String char) {
    if (!inputModel.keyboardInputAllowed) {
      return;
    }
    if (char == '\n') {
      char = 'VK_RETURN';
    } else if (char == ' ') {
      char = 'VK_SPACE';
    }
    inputModel.inputKey(char);
  }

  void openKeyboard() {
    final allowWaylandKeyboard =
        mainGetPeerBoolOptionSync(widget.id, kPeerOptionAllowWaylandKeyboard);
    if (shouldShowWaylandKeyboardPrompt(
      connectionId: sessionId.toString(),
      isWaylandPeer: _shouldGateKeyboardForWayland(),
      allowWaylandKeyboardRemembered: allowWaylandKeyboard,
    )) {
      inputModel.keyboardInputAllowed = false;
      showWaylandKeyboardInputWarningDialog(
        id: widget.id,
        connectionId: sessionId.toString(),
        ffi: gFFI,
        onEnable: () async {
          _openKeyboardUnlocked();
        },
      );
      return;
    }
    _openKeyboardUnlocked();
  }

  void _openKeyboardUnlocked() {
    inputModel.keyboardInputAllowed = true;
    gFFI.invokeMethod("enable_soft_keyboard", true);
    // destroy first, so that our _value trick can work
    _value = initText;
    _textController.text = _value;
    setState(() => _showEdit = false);
    _timer?.cancel();
    _timer = Timer(kMobileDelaySoftKeyboard, () {
      // show now, and sleep a while to requestFocus to
      // make sure edit ready, so that keyboard won't show/hide/show/hide happen
      setState(() => _showEdit = true);
      _timer?.cancel();
      _timer = Timer(kMobileDelaySoftKeyboardFocus, () {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual,
            overlays: SystemUiOverlay.values);
        _mobileFocusNode.requestFocus();
      });
    });
  }

  Widget _bottomWidget() => _showGestureHelp
      ? getGestureHelp()
      : (_showBar && gFFI.ffiModel.pi.displays.isNotEmpty
          ? getBottomAppBar()
          : Offstage());

  Widget _viewerBody() {
    final canvasColor =
        _rymu ? RymuGlassPalette.of(context).canvas : MyTheme.canvasColor;
    final canvas = Overlay(
      key: _rymu ? ObjectKey(_rymuOverview) : null,
      initialEntries: [
        OverlayEntry(builder: (context) {
          return ColoredBox(
            color: _rymu ? canvasColor : kColorCanvas,
            child: isWebDesktop
                ? getBodyForDesktopWithListener()
                : SafeArea(
                    child: LayoutBuilder(builder: (context, constraints) {
                      final orientation =
                          constraints.maxWidth > constraints.maxHeight
                              ? Orientation.landscape
                              : Orientation.portrait;
                      if (_rymu) {
                        return RymuTouchSurface(
                          ffi: gFFI,
                          overview: _rymuOverview,
                          canControl: () => mounted && _rymuCanInput,
                          child: getBodyForMobile(),
                        );
                      }
                      if (orientation != _currentOrientation) {
                        _currentOrientation = orientation;
                        _viewportResizeTimer?.cancel();
                        _viewportResizeTimer =
                            Timer(const Duration(milliseconds: 200), () {
                          if (!mounted || _rymuClosing) return;
                          gFFI.dialogManager
                              .resetMobileActionsOverlay(ffi: gFFI);
                          gFFI.canvasModel.updateViewStyle();
                        });
                      }
                      return ColoredBox(
                        color: canvasColor,
                        child: inputModel.isPhysicalMouse.value
                            ? getBodyForMobile()
                            : RawTouchGestureDetectorRegion(
                                child: getBodyForMobile(), ffi: gFFI),
                      );
                    }),
                  ),
          );
        }),
      ],
    );
    if (!_rymu) return canvas;

    // Keep the editor outside the legacy OverlayEntry so opening Text
    // reliably attaches the Android text input connection on the next frame.
    return Stack(fit: StackFit.expand, children: [
      canvas,
      if (_showEdit)
        Positioned(
          bottom: 0,
          left: 0,
          width: 1,
          height: 1,
          child: ExcludeSemantics(
            child: IgnorePointer(
              child: Opacity(
                opacity: 0,
                child: TextField(
                  controller: _textController,
                  focusNode: _mobileFocusNode,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  maxLines: null,
                  autocorrect: false,
                  onTapOutside: (_) {},
                ),
              ),
            ),
          ),
        ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    final keyboardIsVisible =
        keyboardVisibilityController.isVisible && _showEdit;
    final showActionButton =
        !_rymu && (!_showBar || keyboardIsVisible || _showGestureHelp);
    final viewer = Obx(() {
      final ready = gFFI.ffiModel.pi.isSet.isTrue;
      return getRawPointerAndKeyBody(_viewerBody(), ready: ready);
    });

    return PopScope<void>(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (_rymu) {
          if (_showEdit) {
            _hideRymuKeyboard();
          } else {
            _closeRymuSession();
          }
        } else {
          clientClose(sessionId, gFFI);
        }
      },
      child: Scaffold(
          // workaround for https://github.com/rustdesk/rustdesk/issues/3131
          floatingActionButtonLocation: keyboardIsVisible
              ? FABLocation(FloatingActionButtonLocation.endFloat, 0, -35)
              : null,
          floatingActionButton: !showActionButton
              ? null
              : FloatingActionButton(
                  mini: !keyboardIsVisible,
                  child: Icon(
                    (keyboardIsVisible || _showGestureHelp)
                        ? Icons.expand_more
                        : Icons.expand_less,
                    color: Colors.white,
                  ),
                  backgroundColor: MyTheme.accent,
                  onPressed: () {
                    setState(() {
                      if (keyboardIsVisible) {
                        _showEdit = false;
                        gFFI.invokeMethod("enable_soft_keyboard", false);
                        _mobileFocusNode.unfocus();
                        _physicalFocusNode.requestFocus();
                      } else if (_showGestureHelp) {
                        _showGestureHelp = false;
                      } else {
                        _showBar = !_showBar;
                      }
                    });
                  }),
          bottomNavigationBar: _rymu
              ? (_showEdit
                  ? null
                  : ListenableBuilder(
                      listenable: gFFI.ffiModel,
                      builder: (context, _) => Obx(_rymuSessionBar),
                    ))
              : Obx(() => Stack(
                    alignment: Alignment.bottomCenter,
                    children: [
                      gFFI.ffiModel.pi.isSet.isTrue &&
                              gFFI.ffiModel.waitForFirstImage.isTrue
                          ? emptyOverlay(MyTheme.canvasColor)
                          : () {
                              gFFI.ffiModel.tryShowAndroidActionsOverlay();
                              return Offstage();
                            }(),
                      _bottomWidget(),
                      gFFI.ffiModel.pi.isSet.isFalse
                          ? emptyOverlay(MyTheme.canvasColor)
                          : Offstage(),
                    ],
                  )),
          body: _rymu
              ? Column(children: [
                  Obx(() => _rymuPrivacyActive || _rymuPrivacyReply != null
                      ? RymuScreenPrivacyStatus(
                          arabic: _rymuArabic,
                          pending: _rymuPrivacyReply != null,
                          onDisconnect: _closeRymuSession,
                        )
                      : const SizedBox.shrink()),
                  Expanded(child: viewer),
                  if (_showEdit)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: RymuRemoteKeyboard(
                        arabic: _rymuArabic,
                        expanded: _rymuMoreKeys,
                        keys: _rymuKeys,
                        onModifier: (modifier) {
                          if (_rymuCanInput) {
                            setState(() => _rymuKeys.toggle(modifier));
                          }
                        },
                        onKey: (key, modifiers) => _sendRymuKeyboardInput(
                            _rymuKeys.stroke(key, modifiers)),
                        onExpand: () {
                          setState(() => _rymuMoreKeys = !_rymuMoreKeys);
                        },
                        onHide: _hideRymuKeyboard,
                        displayControl: ListenableBuilder(
                          listenable: gFFI.ffiModel,
                          builder: (context, _) => Obx(_rymuDisplayControl),
                        ),
                      ),
                    ),
                ])
              : viewer),
    );
  }

  bool _handleLocalKeyEvent(KeyEvent event) =>
      (!_rymu || !widget.rymuViewOnly) &&
      handleMobileLocalKeyEvent(event,
          remoteFocused: _physicalFocusNode.hasPrimaryFocus,
          inputModel: inputModel);

  Widget getRawPointerAndKeyBody(Widget child, {required bool ready}) {
    if (_rymu && widget.rymuViewOnly) return child;
    if (_rymuOverview != null) {
      return ready ? RawKeyFocusScope(focusNode: _physicalFocusNode,
          inputModel: inputModel, child: child) : child;
    }
    final ffiModel = Provider.of<FfiModel>(context);
    return RawPointerMouseRegion(
      cursor: ffiModel.keyboard ? SystemMouseCursors.none : MouseCursor.defer,
      inputModel: inputModel,
      // Disable RawKeyFocusScope before the connecting is established.
      // The "Delete" key on the soft keyboard may be grabbed when inputting the password dialog.
      child: ready
          ? RawKeyFocusScope(
              focusNode: _physicalFocusNode,
              inputModel: inputModel,
              child: child)
          : child,
    );
  }

  Widget _rymuSessionBar() {
    final active = _rymuReady;
    final status = active
        ? _rymuCanInput
            ? _rymuText('Connected', 'متصل')
            : _rymuText('View only', 'عرض فقط')
        : _rymuText('Connecting…', 'جارٍ الاتصال…');
    return RymuAndroidSessionBar(
      name: widget.rymuName!,
      status: status,
      arabic: _rymuArabic,
      displayControl: _rymuDisplayControl(),
      onText: _rymuCanInput ? _openRymuKeyboard : null,
      onSettings: active ? _showRymuControls : null,
      onDisconnect: _closeRymuSession,
    );
  }

  void _closeRymuSession() {
    _rymuClosing = true;
    _hideRymuKeyboard(restoreFocus: false);
    gFFI.ffiModel.setRymuReconnectHandler(null);
    closeConnection();
  }

  List<Rect> _screenTopology(PeerInfo peer) => [
        for (final display in peer.displays)
          Rect.fromLTWH(display.x, display.y, display.width.toDouble(),
              display.height.toDouble()),
      ];

  List<int> _sessionScreens(PeerInfo peer) {
    final included = _rymuIncludedScreens;
    if (included != null &&
        listEquals(_rymuScreenTopology, _screenTopology(peer))) {
      return included.toList()..sort();
    }
    return List.generate(peer.displays.length, (index) => index);
  }

  Widget _rymuDisplayControl() {
    final peer = gFFI.ffiModel.pi;
    final count = _rymuReady ? peer.displays.length : 0;
    final screens = count == 0 ? const <int>[] : _sessionScreens(peer);
    return RymuSessionDisplayControl(
      arabic: _rymuArabic,
      current: count == 0 ? 0 : peer.currentDisplay.clamp(0, count - 1).toInt() + 1,
      count: count,
      overview: _rymuOverview != null,
      cycleCount: screens.length,
      onNext: screens.length > 1 ? _nextRymuDisplay : null,
      onChoose: count > 0 ? _chooseRymuSessionScreens : null,
    );
  }

  void _nextRymuDisplay() {
    if (!_rymuReady) return;
    final peer = gFFI.ffiModel.pi;
    final screens = _sessionScreens(peer);
    if (screens.length < 2) return;
    final next = (screens.indexOf(peer.currentDisplay) + 1) % screens.length;
    _switchRymuDisplay(peer, screens[next]);
  }

  void _switchRymuDisplay(PeerInfo peer, int index) {
    if (_rymuOverview != null) {
      _clearRymuOverview();
      setState(() {});
    }
    if (index == peer.currentDisplay) return;
    gFFI.canvasModel.fitRymuMobileViewport(force: true);
    openMonitorInTheSameTab(index, gFFI, peer);
  }

  Future<void> _chooseRymuSessionScreens() async {
    final peer = gFFI.ffiModel.pi;
    final topology = _screenTopology(peer);
    if (!_rymuReady || topology.isEmpty) return;
    final reopenKeyboard = _showEdit;
    if (reopenKeyboard) _hideRymuKeyboard();
    final chosen = await showModalBottomSheet<Set<int>>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => FractionallySizedBox(
        heightFactor: .8,
        child: RymuSessionScreensSheet(
          arabic: _rymuArabic,
          sizes: topology.map((display) => display.size).toList(),
          current: peer.currentDisplay,
          selected: _sessionScreens(peer).toSet(),
          overviewActive: _rymuOverview != null,
          onOverview: peer.platform == kPeerPlatformWindows &&
              peer.isSupportMultiUiSession && topology.length > 1
              ? () {
                  Navigator.pop(context);
                  _showRymuOverview();
                } : null,
          onFit: () {
            Navigator.pop(context);
            final overview = _rymuOverview;
            if (overview != null) {
              overview.fit();
            } else {
              gFFI.canvasModel.fitRymuMobileViewport(force: true);
            }
          },
          onZoom: (factor) {
            Navigator.pop(context);
            final overview = _rymuOverview;
            if (overview != null) {
              final center = overview.viewport.center(Offset.zero);
              overview.transform(factor, center, center);
            } else {
              final canvas = gFFI.canvasModel;
              final center = canvas.size.center(Offset.zero);
              canvas.transformRymuMobileViewport(factor, center, center);
            }
          },
        ),
      ),
    );
    if (!mounted) return;
    if (chosen != null && _rymuReady &&
        listEquals(topology, _screenTopology(peer))) {
      setState(() {
        _rymuScreenTopology = topology;
        _rymuIncludedScreens = chosen.isEmpty || chosen.length == topology.length
            ? null
            : Set.unmodifiable(chosen);
      });
      if (_rymuOverview != null || (chosen.isNotEmpty && !chosen.contains(peer.currentDisplay))) {
        _switchRymuDisplay(peer, _sessionScreens(peer).first);
      }
    }
    if (reopenKeyboard && _rymuCanInput) await _openRymuKeyboard();
  }

  void _clearRymuOverview() {
    gFFI.imageModel.rymuOverview = null;
    _rymuOverview?.dispose();
    _rymuOverview = null;
  }

  void _showRymuOverview() {
    final peer = gFFI.ffiModel.pi;
    if (!_rymuReady || peer.platform != kPeerPlatformWindows ||
        !peer.isSupportMultiUiSession || peer.displays.length < 2) return;
    if (_rymuOverview != null) {
      _rymuOverview!.fit();
      return;
    }
    final topology = _screenTopology(peer);
    if (topology.any((screen) => screen.isEmpty)) return;
    final overview = RymuMonitorOverview(topology);
    setState(() => _rymuOverview = overview);
    gFFI.imageModel.disposeImage();
    gFFI.imageModel.rymuOverview = overview;
    openMonitorInTheSameTab(kAllDisplayValue, gFFI, peer, updateCursorPos: false);
  }

  Future<void> _showRymuControls() async {
    var changingAudio = false;
    final hostKeyboard =
        gFFI.ffiModel.pi.platformAdditions['rymu_keyboard_layout'];
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => StatefulBuilder(builder: (context, refresh) {
        final canInput = _rymuCanInput;
        final clipboardAvailable =
            canInput && gFFI.ffiModel.permissions['clipboard'] != false;
        return Directionality(
          textDirection: _rymuArabic ? TextDirection.rtl : TextDirection.ltr,
          child: SafeArea(
            top: false,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                  maxHeight: MediaQuery.sizeOf(context).height * .8),
              child: ListView(shrinkWrap: true, children: [
                ListTile(
                    title:
                        Text(_rymuText('Session settings', 'إعدادات الجلسة'))),
                ListenableBuilder(
                  listenable: gFFI.ffiModel,
                  builder: (context, _) => Obx(() => RymuScreenPrivacyTile(
                        arabic: _rymuArabic,
                        active: _rymuPrivacyActive,
                        available: _rymuPrivacyAvailable,
                        onChanged: _setRymuPrivacy,
                      )),
                ),
                if (canInput)
                  RymuInputModeSelector(
                    arabic: _rymuArabic,
                    direct: gFFI.ffiModel.touchMode,
                    onChanged: (direct) async {
                      if (gFFI.ffiModel.touchMode != direct) gFFI.ffiModel.toggleTouchMode();
                      refresh(() {});
                      await bind.mainSetLocalOption(
                          key: 'rymu-touch-$_rymuPreferenceKey',
                          value: gFFI.ffiModel.touchMode ? 'touch' : 'mouse');
                    },
                  ),
                _rymuPreference(
                  _rymuText('Quality', 'الجودة'),
                  _rymuQuality,
                  {
                    kRemoteImageQualityBalanced: _rymuText('Auto', 'تلقائية'),
                    kRemoteImageQualityLow:
                        _rymuText('Data Saver', 'توفير البيانات'),
                    kRemoteImageQualityBest:
                        _rymuText('High Quality', 'جودة عالية'),
                  },
                  (value) async {
                    refresh(() => _rymuQuality = value);
                    await bind.sessionSetImageQuality(
                        sessionId: sessionId, value: value);
                  },
                ),
                ListenableBuilder(
                  listenable: gFFI.ffiModel,
                  builder: (context, _) {
                    if (gFFI.ffiModel.permissions['audio'] != true) {
                      return const SizedBox.shrink();
                    }
                    const option = 'disable-audio';
                    return SwitchListTile(
                      title: Text(_rymuText('Computer audio', 'صوت الكمبيوتر')),
                      value: bind.sessionGetToggleOptionSync(
                              sessionId: sessionId, arg: option) == false,
                      onChanged: changingAudio ? null : (_) async {
                        if (!_rymuReady || changingAudio ||
                            gFFI.ffiModel.permissions['audio'] != true) return;
                        refresh(() => changingAudio = true);
                        try {
                          await bind.sessionToggleOption(
                              sessionId: sessionId, value: option);
                        } catch (_) {
                          if (context.mounted) {
                            showToast(_rymuText('Could not change computer audio.',
                                'تعذّر تغيير صوت الكمبيوتر.'));
                          }
                        } finally {
                          if (context.mounted) {
                            refresh(() => changingAudio = false);
                          }
                        }
                      },
                    );
                  },
                ),
                _rymuPreference(
                  _rymuText('Session language', 'لغة الجلسة'),
                  _rymuLanguage,
                  {
                    'auto': _rymuText('Auto', 'تلقائية'),
                    'en': 'English',
                    'ar': 'العربية'
                  },
                  (value) async {
                    setState(() => _rymuLanguage = value);
                    refresh(() {});
                    await bind.mainSetLocalOption(
                        key: 'rymu-session-language-$_rymuPreferenceKey',
                        value: value);
                    await bind.mainSetLocalOption(
                        key: kCommConfKeyLang,
                        value: _rymuArabic ? 'ar' : 'en');
                  },
                ),
                if (_rymuLanguage == 'auto' &&
                    !{'ar', 'en'}.contains(_rymuHostLocale))
                  ListTile(
                      subtitle: Text(_rymuText(
                          'Remote language unknown. Using the phone’s language.',
                          'لغة الكمبيوتر غير معروفة. تُستخدم لغة الهاتف.'))),
                ListTile(
                  title: Text(_rymuText(
                      'Remote keyboard layout', 'تخطيط لوحة مفاتيح الكمبيوتر')),
                  subtitle: hostKeyboard is String && hostKeyboard.isNotEmpty
                      ? Text(hostKeyboard, textDirection: TextDirection.ltr)
                      : Text(_rymuText('Unknown', 'غير معروف')),
                ),
                SwitchListTile(
                  title: Text(_rymuText('Text clipboard', 'حافظة النصوص')),
                  subtitle: Text(_rymuText(
                      'Applies to this session while Rymu is in use.',
                      'تُستخدم في هذه الجلسة عندما يكون ريمو في الواجهة.')),
                  value: _rymuClipboardEnabled && clipboardAvailable,
                  onChanged: !clipboardAvailable
                      ? null
                      : (value) async {
                          await _setRymuClipboard(value);
                          if (context.mounted) refresh(() {});
                        },
                ),
                if (_rymuClipboardEnabled && clipboardAvailable)
                  ListTile(
                      title: Text(_rymuText(
                          'Send phone clipboard', 'إرسال حافظة الهاتف')),
                      onTap: trySyncClipboard),
                SwitchListTile(
                  title: Text(
                      _rymuText('Connection diagnostics', 'تشخيص الاتصال')),
                  value: bind.sessionGetToggleOptionSync(
                          sessionId: sessionId,
                          arg: kOptionShowQualityMonitor) ==
                      true,
                  onChanged: (_) async {
                    await bind.sessionToggleOption(
                        sessionId: sessionId, value: kOptionShowQualityMonitor);
                    await gFFI.qualityMonitorModel
                        .checkShowQualityMonitor(sessionId);
                    if (context.mounted) refresh(() {});
                  },
                ),
              ]),
            ),
          ),
        );
      }),
    );
    if (mounted) _physicalFocusNode.requestFocus();
  }

  Widget _rymuPreference(String label, String selected,
          Map<String, String> options, ValueChanged<String> changed) =>
      Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 16, 6),
        child: DropdownButtonFormField<String>(
          isExpanded: true,
          value: selected,
          decoration: InputDecoration(labelText: label),
          items: options.entries
              .map((option) => DropdownMenuItem(
                  value: option.key, child: Text(option.value)))
              .toList(),
          onChanged: (value) {
            if (value != null) changed(value);
          },
        ),
      );

  Widget getBottomAppBar() {
    final ffiModel = Provider.of<FfiModel>(context);
    return BottomAppBar(
      elevation: 10,
      color: MyTheme.accent,
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: <Widget>[
          Row(
              children: <Widget>[
                    IconButton(
                      color: Colors.white,
                      icon: Icon(Icons.clear),
                      onPressed: () {
                        clientClose(sessionId, gFFI);
                      },
                    ),
                    IconButton(
                      color: Colors.white,
                      icon: Icon(Icons.tv),
                      onPressed: () {
                        setState(() => _showEdit = false);
                        showOptions(context, widget.id, gFFI.dialogManager);
                      },
                    )
                  ] +
                  (isWebDesktop || ffiModel.viewOnly || !ffiModel.keyboard
                      ? []
                      : gFFI.ffiModel.isPeerAndroid
                          ? [
                              IconButton(
                                  color: Colors.white,
                                  icon: Icon(Icons.keyboard),
                                  onPressed: openKeyboard),
                              IconButton(
                                color: Colors.white,
                                icon: const Icon(Icons.build),
                                onPressed: () => gFFI.dialogManager
                                    .toggleMobileActionsOverlay(ffi: gFFI),
                              )
                            ]
                          : [
                              IconButton(
                                  color: Colors.white,
                                  icon: Icon(Icons.keyboard),
                                  onPressed: openKeyboard),
                              IconButton(
                                color: Colors.white,
                                icon: Icon(gFFI.ffiModel.touchMode
                                    ? Icons.touch_app
                                    : Icons.mouse),
                                onPressed: () => setState(
                                    () => _showGestureHelp = !_showGestureHelp),
                              ),
                            ]) +
                  (isWeb
                      ? []
                      : <Widget>[
                          futureBuilder(
                              future: gFFI.invokeMethod(
                                  "get_value", "KEY_IS_SUPPORT_VOICE_CALL"),
                              hasData: (isSupportVoiceCall) => IconButton(
                                    color: Colors.white,
                                    icon: isAndroid && isSupportVoiceCall
                                        ? SvgPicture.asset('assets/chat.svg',
                                            colorFilter: ColorFilter.mode(
                                                Colors.white, BlendMode.srcIn))
                                        : Icon(Icons.message),
                                    onPressed: () =>
                                        isAndroid && isSupportVoiceCall
                                            ? showChatOptions(widget.id)
                                            : onPressedTextChat(widget.id),
                                  ))
                        ]) +
                  [
                    IconButton(
                      color: Colors.white,
                      icon: Icon(Icons.more_vert),
                      onPressed: () {
                        setState(() => _showEdit = false);
                        showActions(widget.id);
                      },
                    ),
                  ]),
          Obx(() => IconButton(
                color: Colors.white,
                icon: Icon(Icons.expand_more),
                onPressed: gFFI.ffiModel.waitForFirstImage.isTrue
                    ? null
                    : () {
                        setState(() => _showBar = !_showBar);
                      },
              )),
        ],
      ),
    );
  }

  bool get showCursorPaint =>
      !gFFI.ffiModel.isPeerAndroid &&
      !gFFI.canvasModel.cursorEmbedded &&
      !gFFI.inputModel.relativeMouseMode.value;

  Widget getBodyForMobile() {
    return Container(
        color: _rymu ? RymuGlassPalette.of(context).canvas : MyTheme.canvasColor,
        child: Stack(children: () {
          final paints = [
            if (_rymuOverview != null)
              RymuMonitorOverviewView(overview: _rymuOverview!,
                  cursor: gFFI.cursorModel, arabic: _rymuArabic,
                  showCursor: showCursorPaint)
            else ImagePaint(ffiModel: gFFI.ffiModel),
            Positioned(
              top: 10,
              right: 10,
              child: QualityMonitor(gFFI.qualityMonitorModel),
            ),
            if (!_rymu)
              Obx(() {
                final chatKeyboardRequested =
                    gFFI.chatModel.softKeyboardRequested.value;
                return KeyHelpTools(
                    keyboardIsVisible: keyboardVisibilityController.isVisible &&
                        (_showEdit || chatKeyboardRequested),
                    showGestureHelp: _showGestureHelp);
              }),
            if (!_rymu)
              SizedBox(
                width: 0,
                height: 0,
                child: !_showEdit
                    ? Container()
                    : TextFormField(
                        textInputAction: TextInputAction.newline,
                        autocorrect: false,
                        // Flutter 3.16.9 Android.
                        // `enableSuggestions` causes secure keyboard to be shown.
                        // https://github.com/flutter/flutter/issues/139143
                        // https://github.com/flutter/flutter/issues/146540
                        // enableSuggestions: false,
                        autofocus: true,
                        focusNode: _mobileFocusNode,
                        maxLines: null,
                        controller: _textController,
                        // trick way to make backspace work always
                        keyboardType: TextInputType.multiline,
                        // `onChanged` may be called depending on the input method if this widget is wrapped in
                        // `Focus(onKeyEvent: ..., child: ...)`
                        // For `Backspace` button in the soft keyboard:
                        // en/fr input method:
                        //      1. The button will not trigger `onKeyEvent` if the text field is not empty.
                        //      2. The button will trigger `onKeyEvent` if the text field is empty.
                        // ko/zh/ja input method: the button will trigger `onKeyEvent`
                        //                     and the event will not popup if `KeyEventResult.handled` is returned.
                        onChanged: handleSoftKeyboardInput,
                      ).workaroundFreezeLinuxMint(),
              ),
          ];
          if (showCursorPaint && _rymuOverview == null) {
            paints.add(CursorPaint(widget.id));
          }
          if (!_rymu) {
            paints.add(gFFI.ffiModel.touchMode
                ? FloatingMouse(ffi: gFFI)
                : FloatingMouseWidgets(ffi: gFFI));
          }
          return paints;
        }()));
  }

  Widget getBodyForDesktopWithListener() {
    final ffiModel = Provider.of<FfiModel>(context);
    var paints = <Widget>[ImagePaint(ffiModel: ffiModel)];
    if (showCursorPaint) {
      final cursor = bind.sessionGetToggleOptionSync(
          sessionId: sessionId, arg: 'show-remote-cursor');
      if (ffiModel.keyboard || cursor) {
        paints.add(CursorPaint(widget.id));
      }
    }
    return Container(
        color: MyTheme.canvasColor, child: Stack(children: paints));
  }

  List<TTextMenu> _getMobileActionMenus() {
    if (gFFI.ffiModel.pi.platform != kPeerPlatformAndroid ||
        !gFFI.ffiModel.keyboard) {
      return [];
    }
    final enabled = versionCmp(gFFI.ffiModel.pi.version, '1.2.7') >= 0;
    if (!enabled) return [];
    return [
      TTextMenu(
        child: Text(translate('Back')),
        onPressed: () => gFFI.inputModel.onMobileBack(),
      ),
      TTextMenu(
        child: Text(translate('Home')),
        onPressed: () => gFFI.inputModel.onMobileHome(),
      ),
      TTextMenu(
        child: Text(translate('Apps')),
        onPressed: () => gFFI.inputModel.onMobileApps(),
      ),
      TTextMenu(
        child: Text(translate('Volume up')),
        onPressed: () => gFFI.inputModel.onMobileVolumeUp(),
      ),
      TTextMenu(
        child: Text(translate('Volume down')),
        onPressed: () => gFFI.inputModel.onMobileVolumeDown(),
      ),
      TTextMenu(
        child: Text(translate('Power')),
        onPressed: () => gFFI.inputModel.onMobilePower(),
      ),
    ];
  }

  void showActions(String id) async {
    final size = MediaQuery.of(context).size;
    final x = 120.0;
    final y = size.height;
    final mobileActionMenus = _getMobileActionMenus();
    final menus = toolbarControls(context, id, gFFI);

    final List<PopupMenuEntry<int>> more = [
      ...mobileActionMenus
          .asMap()
          .entries
          .map((e) =>
              PopupMenuItem<int>(child: e.value.getChild(), value: e.key))
          .toList(),
      if (mobileActionMenus.isNotEmpty) PopupMenuDivider(),
      ...menus
          .asMap()
          .entries
          .map((e) => PopupMenuItem<int>(
              child: e.value.getChild(),
              value: e.key + mobileActionMenus.length))
          .toList(),
    ];
    () async {
      var index = await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(x, y, x, y),
        items: more,
        elevation: 8,
      );
      if (index != null) {
        if (index < mobileActionMenus.length) {
          mobileActionMenus[index].onPressed?.call();
        } else if (index < mobileActionMenus.length + more.length) {
          menus[index - mobileActionMenus.length].onPressed?.call();
        }
      }
    }();
  }

  void _registerMobileChatShortcut() {
    if (!isMobile) return;
    gFFI.shortcutModel.register(kShortcutActionToggleChat,
        () => onPressedTextChat(widget.id, requestSoftKeyboard: false));
  }

  onPressedTextChat(String id, {bool requestSoftKeyboard = true}) {
    if (gFFI.chatModel.chatWindowOverlayEntry == null) {
      setState(() => _showEdit = false);
    }
    gFFI.chatModel.changeCurrentKey(MessageKey(id, ChatModel.clientModeID));
    gFFI.chatModel.toggleChatOverlay(requestSoftKeyboard: requestSoftKeyboard);
  }

  showChatOptions(String id) async {
    onPressVoiceCall() => bind.sessionRequestVoiceCall(sessionId: sessionId);
    onPressEndVoiceCall() => bind.sessionCloseVoiceCall(sessionId: sessionId);

    makeTextMenu(String label, Widget icon, VoidCallback onPressed,
            {TextStyle? labelStyle}) =>
        TTextMenu(
          child: Text(translate(label), style: labelStyle),
          trailingIcon: Transform.scale(
            scale: (isDesktop || isWebDesktop) ? 0.8 : 1,
            child: IgnorePointer(
              child: IconButton(
                onPressed: null,
                icon: icon,
              ),
            ),
          ),
          onPressed: onPressed,
        );

    final isInVoice = [
      VoiceCallStatus.waitingForResponse,
      VoiceCallStatus.connected
    ].contains(gFFI.chatModel.voiceCallStatus.value);
    final menus = [
      makeTextMenu('Text chat', Icon(Icons.message, color: MyTheme.accent),
          () => onPressedTextChat(widget.id)),
      isInVoice
          ? makeTextMenu(
              'End voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter:
                    ColorFilter.mode(Colors.redAccent, BlendMode.srcIn),
              ),
              onPressEndVoiceCall,
              labelStyle: TextStyle(color: Colors.redAccent))
          : makeTextMenu(
              'Voice call',
              SvgPicture.asset(
                'assets/call_wait.svg',
                colorFilter: ColorFilter.mode(MyTheme.accent, BlendMode.srcIn),
              ),
              onPressVoiceCall),
    ];

    final menuItems = menus
        .asMap()
        .entries
        .map((e) => PopupMenuItem<int>(child: e.value.getChild(), value: e.key))
        .toList();
    Future.delayed(Duration.zero, () async {
      final size = MediaQuery.of(context).size;
      final x = 120.0;
      final y = size.height;
      var index = await showMenu(
        context: context,
        position: RelativeRect.fromLTRB(x, y, x, y),
        items: menuItems,
        elevation: 8,
      );
      if (index != null && index < menus.length) {
        menus[index].onPressed?.call();
      }
    });
  }

  /// aka changeTouchMode
  BottomAppBar getGestureHelp() {
    return BottomAppBar(
        child: SingleChildScrollView(
            controller: ScrollController(),
            padding: EdgeInsets.symmetric(vertical: 10),
            child: GestureHelp(
              touchMode: gFFI.ffiModel.touchMode,
              onTouchModeChange: (t) {
                gFFI.ffiModel.toggleTouchMode();
                final v = gFFI.ffiModel.touchMode ? 'Y' : 'N';
                bind.mainSetLocalOption(key: kOptionTouchMode, value: v);
              },
              virtualMouseMode: gFFI.ffiModel.virtualMouseMode,
              inputModel: gFFI.inputModel,
            )));
  }

  // * Currently mobile does not enable map mode
  // void changePhysicalKeyboardInputMode() async {
  //   var current = await bind.sessionGetKeyboardMode(id: widget.id) ?? "legacy";
  //   gFFI.dialogManager.show((setState, close) {
  //     void setMode(String? v) async {
  //       await bind.sessionSetKeyboardMode(id: widget.id, value: v ?? "");
  //       setState(() => current = v ?? '');
  //       Future.delayed(Duration(milliseconds: 300), close);
  //     }
  //
  //     return CustomAlertDialog(
  //         title: Text(translate('Physical Keyboard Input Mode')),
  //         content: Column(mainAxisSize: MainAxisSize.min, children: [
  //           getRadio('Legacy mode', 'legacy', current, setMode),
  //           getRadio('Map mode', 'map', current, setMode),
  //         ]));
  //   }, clickMaskDismiss: true);
  // }
}

class KeyHelpTools extends StatefulWidget {
  final bool keyboardIsVisible;
  final bool showGestureHelp;

  /// need to show by external request, etc [keyboardIsVisible] or [changeTouchMode]
  bool get requestShow => keyboardIsVisible || showGestureHelp;

  KeyHelpTools(
      {required this.keyboardIsVisible, required this.showGestureHelp});

  @override
  State<KeyHelpTools> createState() => _KeyHelpToolsState();
}

class _KeyHelpToolsState extends State<KeyHelpTools> {
  var _more = true;
  var _fn = false;
  var _pin = false;
  final _keyboardVisibilityController = KeyboardVisibilityController();
  final _key = GlobalKey();

  InputModel get inputModel => gFFI.inputModel;

  Widget wrap(String text, void Function() onPressed,
      {bool? active, IconData? icon}) {
    return TextButton(
        style: TextButton.styleFrom(
          minimumSize: Size(0, 0),
          padding: EdgeInsets.symmetric(vertical: 10, horizontal: 9.75),
          //adds padding inside the button
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          //limits the touch area to the button area
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(5.0),
          ),
          backgroundColor: active == true ? MyTheme.accent80 : null,
        ),
        child: icon != null
            ? Icon(icon, size: 14, color: Colors.white)
            : Text(translate(text),
                style: TextStyle(color: Colors.white, fontSize: 11)),
        onPressed: onPressed);
  }

  _updateRect() {
    RenderObject? renderObject = _key.currentContext?.findRenderObject();
    if (renderObject == null) {
      return;
    }
    if (renderObject is RenderBox) {
      final size = renderObject.size;
      Offset pos = renderObject.localToGlobal(Offset.zero);
      gFFI.cursorModel.keyHelpToolsVisibilityChanged(
          Rect.fromLTWH(pos.dx, pos.dy, size.width, size.height),
          widget.keyboardIsVisible);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboard = HardwareKeyboard.instance;
    // Keep touch selections visible without physical modifiers opening the bar.
    final hasTouchModifier = (inputModel.ctrl && !keyboard.isControlPressed) ||
        (inputModel.alt && !keyboard.isAltPressed) ||
        (inputModel.shift && !keyboard.isShiftPressed) ||
        (inputModel.command && !keyboard.isMetaPressed);
    if (!_pin && !hasTouchModifier && !widget.requestShow) {
      gFFI.cursorModel
          .keyHelpToolsVisibilityChanged(null, widget.keyboardIsVisible);
      return Offstage();
    }
    final size = MediaQuery.of(context).size;

    final pi = gFFI.ffiModel.pi;
    final isMac = pi.platform == kPeerPlatformMacOS;
    final isWin = pi.platform == kPeerPlatformWindows;
    final isLinux = pi.platform == kPeerPlatformLinux;
    final modifiers = <Widget>[
      wrap('Ctrl ', () {
        setState(() => inputModel.ctrl = !inputModel.ctrl);
      }, active: inputModel.ctrl),
      wrap(' Alt ', () {
        setState(() => inputModel.alt = !inputModel.alt);
      }, active: inputModel.alt),
      wrap('Shift', () {
        setState(() => inputModel.shift = !inputModel.shift);
      }, active: inputModel.shift),
      wrap(isMac ? ' Cmd ' : ' Win ', () {
        setState(() => inputModel.command = !inputModel.command);
      }, active: inputModel.command),
    ];
    final keys = <Widget>[
      wrap(
          ' Fn ',
          () => setState(
                () {
                  _fn = !_fn;
                  if (_fn) {
                    _more = false;
                  }
                },
              ),
          active: _fn),
      wrap(
          '',
          () => setState(
                () => _pin = !_pin,
              ),
          active: _pin,
          icon: Icons.push_pin),
      wrap(
          ' ... ',
          () => setState(
                () {
                  _more = !_more;
                  if (_more) {
                    _fn = false;
                  }
                },
              ),
          active: _more),
    ];
    final fn = <Widget>[
      SizedBox(width: 9999),
    ];
    for (var i = 1; i <= 12; ++i) {
      final name = 'F$i';
      fn.add(wrap(name, () {
        inputModel.inputKey('VK_$name');
      }));
    }
    final more = <Widget>[
      SizedBox(width: 9999),
      wrap('Esc', () {
        inputModel.inputKey('VK_ESCAPE');
      }),
      wrap('Tab', () {
        inputModel.inputKey('VK_TAB');
      }),
      wrap('Home', () {
        inputModel.inputKey('VK_HOME');
      }),
      wrap('End', () {
        inputModel.inputKey('VK_END');
      }),
      wrap('Ins', () {
        inputModel.inputKey('VK_INSERT');
      }),
      wrap('Del', () {
        inputModel.inputKey('VK_DELETE');
      }),
      wrap('PgUp', () {
        inputModel.inputKey('VK_PRIOR');
      }),
      wrap('PgDn', () {
        inputModel.inputKey('VK_NEXT');
      }),
      // to-do: support PrtScr on Mac
      if (isWin || isLinux)
        wrap('PrtScr', () {
          inputModel.inputKey('VK_SNAPSHOT');
        }),
      if (isWin || isLinux)
        wrap('ScrollLock', () {
          inputModel.inputKey('VK_SCROLL');
        }),
      if (isWin || isLinux)
        wrap('Pause', () {
          inputModel.inputKey('VK_PAUSE');
        }),
      if (isWin || isLinux)
        // Maybe it's better to call it "Menu"
        // https://en.wikipedia.org/wiki/Menu_key
        wrap('Menu', () {
          inputModel.inputKey('Apps');
        }),
      wrap('Enter', () {
        inputModel.inputKey('VK_ENTER');
      }),
      SizedBox(width: 9999),
      wrap('', () {
        inputModel.inputKey('VK_LEFT');
      }, icon: Icons.keyboard_arrow_left),
      wrap('', () {
        inputModel.inputKey('VK_UP');
      }, icon: Icons.keyboard_arrow_up),
      wrap('', () {
        inputModel.inputKey('VK_DOWN');
      }, icon: Icons.keyboard_arrow_down),
      wrap('', () {
        inputModel.inputKey('VK_RIGHT');
      }, icon: Icons.keyboard_arrow_right),
      wrap(isMac ? 'Cmd+C' : 'Ctrl+C', () {
        sendPrompt(isMac, 'VK_C');
      }),
      wrap(isMac ? 'Cmd+V' : 'Ctrl+V', () {
        sendPrompt(isMac, 'VK_V');
      }),
      wrap(isMac ? 'Cmd+S' : 'Ctrl+S', () {
        sendPrompt(isMac, 'VK_S');
      }),
    ];
    final space = size.width > 320 ? 4.0 : 2.0;
    // 500 ms is long enough for this widget to be built!
    Future.delayed(Duration(milliseconds: 500), () {
      _updateRect();
    });
    return Container(
        key: _key,
        color: Color(0xAA000000),
        padding: EdgeInsets.only(
            top: _keyboardVisibilityController.isVisible ? 24 : 4, bottom: 8),
        child: Wrap(
          spacing: space,
          runSpacing: space,
          children: <Widget>[SizedBox(width: 9999)] +
              modifiers +
              keys +
              (_fn ? fn : []) +
              (_more ? more : []),
        ));
  }
}

class ImagePaint extends StatelessWidget {
  final FfiModel ffiModel;
  ImagePaint({Key? key, required this.ffiModel}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<ImageModel>(context);
    final c = Provider.of<CanvasModel>(context);
    var s = c.scale;
    if (ffiModel.isPeerLinux) {
      final displays = ffiModel.pi.getCurDisplays();
      if (displays.isNotEmpty) {
        s = s / displays[0].scale;
      }
    }
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
          image: m.image, x: c.x / s, y: (c.y + adjust) / s, scale: s),
    );
  }
}

class CursorPaint extends StatelessWidget {
  late final String id;
  CursorPaint(this.id);

  @override
  Widget build(BuildContext context) {
    final m = Provider.of<CursorModel>(context);
    final c = Provider.of<CanvasModel>(context);
    final ffiModel = Provider.of<FfiModel>(context);
    final s = c.scale;
    double hotx = m.hotx;
    double hoty = m.hoty;
    var image = m.image;
    if (image == null) {
      if (preDefaultCursor.image != null) {
        image = preDefaultCursor.image;
        hotx = preDefaultCursor.image!.width / 2;
        hoty = preDefaultCursor.image!.height / 2;
      }
    }
    if (preForbiddenCursor.image != null &&
        !ffiModel.viewOnly &&
        !ffiModel.keyboard &&
        !ShowRemoteCursorState.find(id).value) {
      image = preForbiddenCursor.image;
      hotx = preForbiddenCursor.image!.width / 2;
      hoty = preForbiddenCursor.image!.height / 2;
    }
    if (image == null) {
      return Offstage();
    }

    final minSize = 12.0;
    double mins =
        minSize / (image.width > image.height ? image.width : image.height);
    double factor = 1.0;
    if (s < mins) {
      factor = s / mins;
    }
    final s2 = s < mins ? mins : s;
    final adjust = c.getAdjustY();
    return CustomPaint(
      painter: ImagePainter(
          image: image,
          x: (m.x - hotx) * factor + c.x / s2,
          y: (m.y - hoty) * factor + (c.y + adjust) / s2,
          scale: s2),
    );
  }
}

void showOptions(
    BuildContext context, String id, OverlayDialogManager dialogManager) async {
  var displays = <Widget>[];
  final pi = gFFI.ffiModel.pi;
  final image = gFFI.ffiModel.getConnectionImageText();
  if (image != null) {
    displays.add(Padding(padding: const EdgeInsets.only(top: 8), child: image));
  }
  final privacyModeState = PrivacyModeState.find(id);
  if (pi.displays.length > 1 &&
      pi.currentDisplay != kAllDisplayValue &&
      (privacyModeState.isEmpty ||
          allowDisplaySwitchInPrivacyMode(pi, privacyModeState.value))) {
    final cur = pi.currentDisplay;
    final children = <Widget>[];
    final isDarkTheme = MyTheme.currentThemeMode() == ThemeMode.dark;
    final numColorSelected = Colors.white;
    final numColorUnselected = isDarkTheme ? Colors.grey : Colors.black87;
    // We can't use `Theme.of(context).primaryColor` here, the color is:
    // - light theme: 0xff2196f3 (Colors.blue)
    // - dark theme: 0xff212121 (the canvas color?)
    final numBgSelected =
        Theme.of(context).colorScheme.primary.withOpacity(0.6);
    for (var i = 0; i < pi.displays.length; ++i) {
      children.add(InkWell(
          onTap: () {
            if (i == cur) return;
            openMonitorInTheSameTab(i, gFFI, pi);
            gFFI.dialogManager.dismissAll();
          },
          child: Ink(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).hintColor),
                  borderRadius: BorderRadius.circular(2),
                  color: i == cur ? numBgSelected : null),
              child: Center(
                  child: Text((i + 1).toString(),
                      style: TextStyle(
                          color:
                              i == cur ? numColorSelected : numColorUnselected,
                          fontWeight: FontWeight.bold))))));
    }
    displays.add(Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Wrap(
          alignment: WrapAlignment.center,
          spacing: 8,
          children: children,
        )));
  }
  if (displays.isNotEmpty) {
    displays.add(const Divider(color: MyTheme.border));
  }

  List<TRadioMenu<String>> viewStyleRadios =
      await toolbarViewStyle(context, id, gFFI);
  List<TRadioMenu<String>> imageQualityRadios =
      await toolbarImageQuality(context, id, gFFI);
  List<TRadioMenu<String>> codecRadios = await toolbarCodec(context, id, gFFI);
  List<TToggleMenu> cursorToggles = await toolbarCursor(context, id, gFFI);
  List<TToggleMenu> displayToggles =
      await toolbarDisplayToggle(context, id, gFFI);
  if (isMobile) {
    displayToggles.insert(
        0,
        TToggleMenu(
            child: Text(translate('Lock canvas')),
            value: gFFI.canvasModel.locked,
            onChanged: (value) => gFFI.canvasModel.setLocked(value == true)));
  }

  List<TToggleMenu> privacyModeList = [];
  if ((gFFI.ffiModel.pi.features.privacyMode && gFFI.ffiModel.keyboard) ||
      privacyModeState.isNotEmpty) {
    privacyModeList = toolbarPrivacyMode(privacyModeState, context, id, gFFI);
    if (privacyModeList.length == 1) {
      displayToggles.add(privacyModeList[0]);
    }
  }

  dialogManager.show((setState, close, context) {
    var viewStyle =
        (viewStyleRadios.isNotEmpty ? viewStyleRadios[0].groupValue : '').obs;
    var imageQuality =
        (imageQualityRadios.isNotEmpty ? imageQualityRadios[0].groupValue : '')
            .obs;
    var codec = (codecRadios.isNotEmpty ? codecRadios[0].groupValue : '').obs;
    final radios = [
      for (var e in viewStyleRadios)
        Obx(() => getRadio<String>(
            e.child,
            e.value,
            viewStyle.value,
            e.onChanged != null
                ? (v) {
                    e.onChanged?.call(v);
                    if (v != null) viewStyle.value = v;
                  }
                : null)),
      // Show custom scale controls when custom view style is selected
      Obx(() => viewStyle.value == kRemoteViewStyleCustom
          ? MobileCustomScaleControls(ffi: gFFI)
          : const SizedBox.shrink()),
      const Divider(color: MyTheme.border),
      for (var e in imageQualityRadios)
        Obx(() => getRadio<String>(
            e.child,
            e.value,
            imageQuality.value,
            e.onChanged != null
                ? (v) {
                    e.onChanged?.call(v);
                    if (v != null) imageQuality.value = v;
                  }
                : null)),
      const Divider(color: MyTheme.border),
      for (var e in codecRadios)
        Obx(() => getRadio<String>(
            e.child,
            e.value,
            codec.value,
            e.onChanged != null
                ? (v) {
                    e.onChanged?.call(v);
                    if (v != null) codec.value = v;
                  }
                : null)),
      if (codecRadios.isNotEmpty) const Divider(color: MyTheme.border),
    ];
    final rxCursorToggleValues = cursorToggles.map((e) => e.value.obs).toList();
    final cursorTogglesList = cursorToggles
        .asMap()
        .entries
        .map((e) => Obx(() => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: rxCursorToggleValues[e.key].value,
            onChanged: e.value.onChanged != null
                ? (v) {
                    e.value.onChanged?.call(v);
                    if (v != null) rxCursorToggleValues[e.key].value = v;
                  }
                : null,
            title: e.value.child)))
        .toList();

    final rxToggleValues = displayToggles.map((e) => e.value.obs).toList();
    final displayTogglesList = displayToggles
        .asMap()
        .entries
        .map((e) => Obx(() => CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            value: rxToggleValues[e.key].value,
            onChanged: e.value.onChanged != null
                ? (v) {
                    e.value.onChanged?.call(v);
                    if (v != null) rxToggleValues[e.key].value = v;
                  }
                : null,
            title: e.value.child)))
        .toList();
    final toggles = [
      ...cursorTogglesList,
      if (cursorToggles.isNotEmpty) const Divider(color: MyTheme.border),
      ...displayTogglesList,
    ];

    Widget privacyModeWidget = Offstage();
    if (privacyModeList.length > 1) {
      privacyModeWidget = ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: Text(translate('Privacy mode')),
        onTap: () => setPrivacyModeDialog(
            dialogManager, privacyModeList, privacyModeState),
      );
    }

    var popupDialogMenus = List<Widget>.empty(growable: true);
    final resolution = getResolutionMenu(gFFI, id);
    if (resolution != null) {
      popupDialogMenus.add(ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: resolution.child,
        onTap: () {
          close();
          resolution.onPressed?.call();
        },
      ));
    }
    final virtualDisplayMenu = getVirtualDisplayMenu(gFFI, id);
    if (virtualDisplayMenu != null) {
      popupDialogMenus.add(ListTile(
        contentPadding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        title: virtualDisplayMenu.child,
        onTap: () {
          close();
          virtualDisplayMenu.onPressed?.call();
        },
      ));
    }
    if (popupDialogMenus.isNotEmpty) {
      popupDialogMenus.add(const Divider(color: MyTheme.border));
    }

    return CustomAlertDialog(
      content: Column(
          mainAxisSize: MainAxisSize.min,
          children: displays +
              radios +
              popupDialogMenus +
              toggles +
              [privacyModeWidget]),
    );
  }, clickMaskDismiss: true, backDismiss: true).then((value) {
    _disableAndroidSoftKeyboard();
  });
}

TTextMenu? getVirtualDisplayMenu(FFI ffi, String id) {
  if (!showVirtualDisplayMenu(ffi)) {
    return null;
  }
  return TTextMenu(
    child: Text(translate("Virtual display")),
    onPressed: () {
      ffi.dialogManager.show((setState, close, context) {
        final children = getVirtualDisplayMenuChildren(ffi, id, close);
        return CustomAlertDialog(
          title: Text(translate('Virtual display')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

TTextMenu? getResolutionMenu(FFI ffi, String id) {
  final ffiModel = ffi.ffiModel;
  final pi = ffiModel.pi;
  final resolutions = pi.resolutions;
  final display = pi.tryGetDisplayIfNotAllDisplay(display: pi.currentDisplay);

  final visible =
      ffiModel.keyboard && (resolutions.length > 1) && display != null;
  if (!visible) return null;

  return TTextMenu(
    child: Text(translate("Resolution")),
    onPressed: () {
      ffi.dialogManager.show((setState, close, context) {
        final children = resolutions
            .map((e) => getRadio<String>(
                  Text('${e.width}x${e.height}'),
                  '${e.width}x${e.height}',
                  '${display.width}x${display.height}',
                  (value) {
                    close();
                    bind.sessionChangeResolution(
                      sessionId: ffi.sessionId,
                      display: pi.currentDisplay,
                      width: e.width,
                      height: e.height,
                    );
                  },
                ))
            .toList();
        return CustomAlertDialog(
          title: Text(translate('Resolution')),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        );
      }, clickMaskDismiss: true, backDismiss: true).then((value) {
        _disableAndroidSoftKeyboard();
      });
    },
  );
}

void sendPrompt(bool isMac, String key) {
  final old = isMac ? gFFI.inputModel.command : gFFI.inputModel.ctrl;
  if (isMac) {
    gFFI.inputModel.command = true;
  } else {
    gFFI.inputModel.ctrl = true;
  }
  gFFI.inputModel.inputKey(key);
  if (isMac) {
    gFFI.inputModel.command = old;
  } else {
    gFFI.inputModel.ctrl = old;
  }
}

class FABLocation extends FloatingActionButtonLocation {
  FloatingActionButtonLocation location;
  double offsetX;
  double offsetY;
  FABLocation(this.location, this.offsetX, this.offsetY);

  @override
  Offset getOffset(ScaffoldPrelayoutGeometry scaffoldGeometry) {
    final offset = location.getOffset(scaffoldGeometry);
    return Offset(offset.dx + offsetX, offset.dy + offsetY);
  }
}
