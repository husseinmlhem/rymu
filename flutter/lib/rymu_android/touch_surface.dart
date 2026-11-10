import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

import '../consts.dart';
import '../models/input_model.dart';
import '../models/model.dart';
import 'monitor_overview.dart';

enum _Touch { tap, held, move, drag, transform, scroll }

/// The Rymu canvas owns these contacts. Physical mouse input stays on the
/// existing pointer path.
class RymuTouchSurface extends StatefulWidget {
  const RymuTouchSurface({
    super.key,
    required this.ffi,
    required this.canControl,
    required this.child,
    this.overview,
  });

  final FFI ffi;
  final bool Function() canControl;
  final Widget child;
  final RymuMonitorOverview? overview;

  @override
  State<RymuTouchSurface> createState() => _RymuTouchSurfaceState();
}

class _RymuTouchSurfaceState extends State<RymuTouchSurface> {
  final _contacts = <int, Offset>{};
  var _gesture = _Touch.tap;
  var _start = Offset.zero;
  var _direct = false;
  var _controlStarted = false;
  var _leftDown = false;
  var _physicalButtons = 0;
  var _scrollDistance = 0.0;
  ({Duration time, Offset position})? _lastTap;
  Timer? _hold;
  Future<void> _mouse = Future.value();

  InputModel get _input => widget.ffi.inputModel;
  CursorModel get _cursor => widget.ffi.cursorModel;
  CanvasModel get _canvas => widget.ffi.canvasModel;

  void _send(Future<void> Function() event, {bool release = false}) {
    final canControl = widget.canControl;
    _mouse = _mouse.then((_) async {
      if (release ? mounted || canControl() : mounted && canControl()) {
        await event();
      }
    }).catchError((Object _) {
      debugPrint('Rymu could not forward a touch event.');
    });
  }

  Future<void> _click(MouseButtons button, Offset position, bool direct) async {
    if (direct && !await _moveDirect(position)) return;
    if (mounted && widget.canControl()) await _input.tap(button);
  }

  Future<bool> _moveDirect(Offset position) async {
    final overview = widget.overview;
    if (overview == null) return _cursor.move(position.dx, position.dy);
    final remote = overview.remoteAt(position);
    if (remote == null) return false;
    await _moveOverviewPointer(remote);
    return true;
  }

  Future<void> _moveOverviewPointer(Offset remote) async {
    final origin = _cursor.offset - Offset(_cursor.x, _cursor.y);
    final local =
        (remote - origin) * _canvas.scale + Offset(_canvas.x, _canvas.y);
    _cursor.moveLocal(local.dx, local.dy);
    await _input.moveMouse(remote.dx, remote.dy);
  }

  void _transform(double factor, Offset previous, Offset current) {
    final overview = widget.overview;
    if (overview != null) {
      overview.transform(factor, previous, current);
    } else {
      _canvas.transformRymuMobileViewport(factor, previous, current);
    }
  }

  void _overviewMouseButtons(int buttons, Offset? position) {
    final input = _input;
    _send(() async {
      if (position != null && !await _moveDirect(position) && buttons != 0) {
        return;
      }
      for (final entry in {
        kPrimaryButton: MouseButtons.left,
        kSecondaryButton: MouseButtons.right,
        kMiddleMouseButton: MouseButtons.wheel,
      }.entries) {
        if ((_physicalButtons & entry.key) == (buttons & entry.key)) continue;
        if ((buttons & entry.key) == 0) {
          await input.tapUp(entry.value);
        } else {
          await input.tapDown(entry.value);
        }
      }
      _physicalButtons = buttons;
    }, release: buttons == 0);
  }

  void _releaseLeft() {
    final input = _input;
    _send(() async {
      if (!_leftDown) return;
      _leftDown = false;
      await input.tapUp(MouseButtons.left);
    }, release: true);
  }

  void _down(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse && widget.overview != null) {
      _overviewMouseButtons(event.buttons, event.localPosition);
      return;
    }
    if (!kTouchBasedDeviceKinds.contains(event.kind) ||
        event.buttons != kPrimaryButton) {
      return;
    }
    _contacts[event.pointer] = event.localPosition;
    if (_contacts.length == 1) {
      _gesture = _Touch.tap;
      _start = event.localPosition;
      _direct = widget.ffi.ffiModel.touchMode;
      _controlStarted = widget.canControl();
      if (_controlStarted) {
        final start = _start;
        final direct = _direct;
        _hold = Timer(kLongPressTimeout, () {
          if (_contacts.length != 1 || _gesture != _Touch.tap) return;
          _gesture = _Touch.held;
          _lastTap = null;
          _send(() => _click(MouseButtons.right, start, direct));
        });
      }
      return;
    }
    _hold?.cancel();
    _lastTap = null;
    if (_gesture == _Touch.drag) _releaseLeft();
    _gesture = _contacts.length == 2 ? _Touch.transform : _Touch.scroll;
    _scrollDistance = 0;
  }

  void _move(PointerMoveEvent event) {
    if (event.kind == PointerDeviceKind.mouse && widget.overview != null) {
      _overviewMouseButtons(event.buttons, event.localPosition);
      return;
    }
    final previous = _contacts[event.pointer];
    if (previous == null) return;
    final position = event.localPosition;
    _contacts[event.pointer] = position;
    final delta = position - previous;
    if (_gesture == _Touch.transform) {
      if (_contacts.length != 2) return;
      final other = _contacts.entries
          .firstWhere((entry) => entry.key != event.pointer)
          .value;
      final distance = (previous - other).distance;
      final next = (position - other).distance;
      _transform(distance > 0 && next > 0 ? next / distance : 1,
          (previous + other) / 2, (position + other) / 2);
      return;
    }
    if (_gesture == _Touch.scroll) {
      if (_contacts.length < 3 || !_controlStarted) return;
      _scrollDistance += delta.dy / _contacts.length;
      final steps = (_scrollDistance / 8).truncate();
      if (steps != 0) {
        _scrollDistance -= steps * 8;
        _send(() => _input.scroll(steps));
      }
      return;
    }
    if (_gesture == _Touch.held) return;
    if (_gesture == _Touch.tap) {
      final slop =
          MediaQuery.gestureSettingsOf(context).touchSlop ?? kTouchSlop;
      if ((position - _start).distance <= slop) return;
      _hold?.cancel();
      final tap = _lastTap;
      final secondTap = tap != null &&
          event.timeStamp - tap.time <= kDoubleTapTimeout &&
          (_start - tap.position).distance <= kDoubleTapSlop;
      _lastTap = null;
      if (_controlStarted && (_direct || secondTap)) {
        _gesture = _Touch.drag;
        final start = _start;
        final direct = _direct;
        _send(() async {
          if (direct && !await _moveDirect(start)) return;
          if (!mounted || !widget.canControl()) return;
          await _input.tapDown(MouseButtons.left);
          _leftDown = true;
        });
      } else {
        _gesture = _Touch.move;
      }
    }
    if (!_controlStarted) {
      _transform(1, previous, position);
      return;
    }
    final direct = _direct;
    _send(() async {
      if (direct) {
        if (_leftDown) await _moveDirect(position);
      } else {
        final overview = widget.overview;
        if (overview != null) {
          await _moveOverviewPointer(
              overview.movePointer(_cursor.offset, delta));
          return;
        }
        if (!_cursor.getVisibleRect().inflate(1).contains(_cursor.offset)) {
          final center = _canvas.size.center(Offset.zero);
          _cursor.moveLocal(center.dx, center.dy);
        }
        await _cursor.updatePan(delta, position, false);
      }
    });
  }

  void _end(PointerEvent event, {required bool cancelled}) {
    if (event.kind == PointerDeviceKind.mouse && widget.overview != null) {
      _overviewMouseButtons(0, null);
      return;
    }
    if (_contacts.remove(event.pointer) == null || _contacts.isNotEmpty) return;
    _hold?.cancel();
    if (_gesture == _Touch.drag) _releaseLeft();
    if (cancelled) _lastTap = null;
    if (cancelled || _gesture != _Touch.tap || !_controlStarted) return;
    final position = event.localPosition;
    final direct = _direct;
    _lastTap = (time: event.timeStamp, position: position);
    _send(() => _click(MouseButtons.left, position, direct));
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
        builder: (context, constraints) {
          final size = constraints.biggest;
          final canvas = _canvas;
          final overview = widget.overview;
          if (overview != null && overview.viewport != size) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && identical(widget.overview, overview)) {
                overview.resize(size);
              }
            });
          }
          if (canvas.rymuMobileViewport != size) {
            canvas.rymuMobileViewport = size;
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && canvas.rymuMobileViewport == size) {
                canvas.fitRymuMobileViewport();
              }
            });
          }
          return SizedBox.expand(
            child: Listener(
              behavior: HitTestBehavior.opaque,
              onPointerHover: (event) {
                if (widget.overview != null &&
                    event.kind == PointerDeviceKind.mouse) {
                  _send(() async {
                    await _moveDirect(event.localPosition);
                  });
                }
              },
              onPointerSignal: (event) {
                if (widget.overview != null && event is PointerScrollEvent) {
                  final steps = (-event.scrollDelta.dy / 30).round();
                  if (steps != 0) _send(() => _input.scroll(steps));
                }
              },
              onPointerDown: _down,
              onPointerMove: _move,
              onPointerUp: (event) => _end(event, cancelled: false),
              onPointerCancel: (event) => _end(event, cancelled: true),
              child: ClipRect(child: widget.child),
            ),
          );
        },
      );

  @override
  void dispose() {
    _hold?.cancel();
    if (_gesture == _Touch.drag || _leftDown) _releaseLeft();
    if (_physicalButtons != 0) _overviewMouseButtons(0, null);
    super.dispose();
  }
}
