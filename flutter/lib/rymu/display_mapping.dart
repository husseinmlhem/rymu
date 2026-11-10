import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';

import 'display_geometry.dart';
import 'native_bridge.dart';

const _key = 'rymu-display-map-v1';

class _Topology {
  _Topology(this.remote, this.local, this.profileKey);
  final List<RymuDisplay> remote, local;
  final String? profileKey;
}

_Topology? _read(FFI ffi) {
  final pi = ffi.ffiModel.pi;
  final remoteData = pi.platformAdditions['rymu_displays'];
  if (remoteData is! List || remoteData.length != pi.displays.length)
    return null;
  final remote =
      remoteData.map(RymuDisplay.parse).whereType<RymuDisplay>().toList();
  final local = RymuNative.displays()
      .map(RymuDisplay.parse)
      .whereType<RymuDisplay>()
      .toList();
  if (remote.length != remoteData.length || local.isEmpty) return null;
  for (final r in remote) {
    if (r.index >= pi.displays.length) return null;
    final d = pi.displays[r.index];
    if (d.x != r.x || d.y != r.y || d.width != r.width || d.height != r.height)
      return null;
  }
  final pair = RymuNative.pairIdentity(ffi.id);
  final remoteInput = topologyFingerprintInput(remote);
  final localInput = topologyFingerprintInput(local);
  final profileKey = pair == null || remoteInput == null || localInput == null
      ? null
      : '$_key-${sha256.convert(utf8.encode(jsonEncode([
              pair,
              remoteInput,
              localInput
            ])))}';
  return _Topology(remote, local, profileKey);
}

Map<String, String> _saved(String? key) {
  if (key == null) return {};
  try {
    final value = jsonDecode(bind.mainGetLocalOption(key: key));
    return Map<String, String>.from(value as Map);
  } catch (_) {
    return {};
  }
}

Future<void> _apply(
    FFI ffi, _Topology topology, Map<int, int> assignment) async {
  if (assignment.isEmpty ||
      assignment.values.toSet().length != assignment.length) return;
  final current = _read(ffi);
  if (current == null || _liveTopology(current) != _liveTopology(topology)) {
    throw StateError('The display topology changed');
  }
  final pi = ffi.ffiModel.pi;
  final locals = {for (final d in topology.local) d.index: d};
  Rect destination(int index) {
    final d = locals[index]!;
    return Rect.fromLTWH(d.x.toDouble(), d.y.toDouble(), d.width.toDouble(),
        d.height.toDouble());
  }

  final entries = assignment.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  openMonitorInTheSameTab(entries.first.key, ffi, pi);
  await tryMoveToScreenAndSetFullscreen(destination(entries.first.value));
  for (final entry in entries.skip(1)) {
    openMonitorInNewTabOrWindow(entry.key, ffi.id, pi,
        screenRect: destination(entry.value));
  }
}

String _liveTopology(_Topology topology) => jsonEncode([
      for (final group in [topology.remote, topology.local])
        [
          for (final d in group)
            [
              d.index,
              d.id,
              d.x,
              d.y,
              d.width,
              d.height,
              d.dpi,
              d.rotation,
              d.primary
            ]
        ],
    ]);

Future<void> restoreRymuDisplayMapping(FFI ffi) async {
  if (!isWindows) return;
  try {
    final topology = _read(ffi);
    if (topology?.profileKey == null) return;
    final selected = resolveAssignment(
        _saved(topology!.profileKey), topology.remote, topology.local);
    if (selected != null) await _apply(ffi, topology, selected);
  } catch (_) {
    // Do not restore any window from an incompatible profile.
  }
}

Future<void> recoverRymuWindowAfterDisplayChange() async {
  if (!isWindows || stateGlobal.windowId == 0) return;
  try {
    final display = RymuNative.displays()
        .map(RymuDisplay.parse)
        .whereType<RymuDisplay>()
        .toList();
    if (display.isEmpty) return;
    final controller = WindowController.fromWindowId(stateGlobal.windowId);
    final frame = await controller.getFrame();
    bool reachable(RymuDisplay d) =>
        frame
            .intersect(Rect.fromLTWH(d.x.toDouble(), d.y.toDouble(),
                d.width.toDouble(), d.height.toDouble()))
            .size
            .shortestSide >=
        48;
    if (display.any(reachable)) return;
    final home =
        display.firstWhere((d) => d.primary, orElse: () => display.first);
    stateGlobal.setFullscreen(false);
    await controller.setFrame(Rect.fromLTWH(
        home.x + 42.0,
        home.y + 42.0,
        math.min(home.width - 84.0, 900.0),
        math.min(home.height - 84.0, 580.0)));
  } catch (_) {
    // This is also called as a window closes; there may no longer be an HWND.
  }
}

Future<void> showRymuDisplayMapping(BuildContext context, FFI ffi) async {
  final rtl = Directionality.of(context) == TextDirection.rtl;
  String t(String en, String ar) => rtl ? ar : en;
  _Topology? topology;
  try {
    topology = _read(ffi);
  } catch (_) {/* Display query unavailable. */}
  if (topology == null || topology.remote.isEmpty) {
    await showDialog<void>(
        context: context,
        builder: (dialog) => AlertDialog(
              title: Text(t('Displays changed', 'تغيّرت الشاشات')),
              content: Text(t(
                  'Reconnect to refresh the verified display information.',
                  'أعد الاتصال لتحديث معلومات الشاشات.')),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(dialog),
                    child: const Text('OK'))
              ],
            ));
    return;
  }
  final snapshot = topology;
  final old = resolveAssignment(
      _saved(snapshot.profileKey), snapshot.remote, snapshot.local);
  final assignment = old ??
      {
        for (var i = 0;
            i < math.min(snapshot.remote.length, snapshot.local.length);
            i++)
          snapshot.remote[i].index: snapshot.local[i].index,
      };
  bool save = snapshot.profileKey != null;
  bool inProgress = false;
  String? error;
  await showDialog<void>(
      context: context,
      builder: (dialog) => StatefulBuilder(
            builder: (dialog, refresh) => AlertDialog(
              title: Text(t('Map displays', 'توزيع الشاشات')),
              content: SizedBox(
                  width: 550,
                  child: SingleChildScrollView(
                      child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(t(
                          'Place one remote display on each selected local monitor.',
                          'اختر شاشة محلية لكل شاشة بعيدة.')),
                      const SizedBox(height: 14),
                      _TopologyDiagram(snapshot.remote),
                      const SizedBox(height: 8),
                      for (final remote in snapshot.remote)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          title: Text(
                              '${t('Remote', 'بعيدة')} ${remote.index + 1}'),
                          subtitle: Text(
                              '${remote.width} × ${remote.height}'
                              '${remote.dpi == null ? '' : ' · ${(remote.dpi! / 0.96).round()}%'}',
                              textDirection: TextDirection.ltr),
                          trailing: DropdownButton<int>(
                            value: assignment[remote.index] ?? -1,
                            items: [
                              DropdownMenuItem(
                                  value: -1, child: Text(t('Skip', 'تخطَّ'))),
                              for (final local in snapshot.local)
                                DropdownMenuItem(
                                    value: local.index,
                                    child: Text(
                                        '${t('Local', 'محلية')} ${local.index + 1}${local.primary ? ' · ${t('Primary', 'الرئيسية')}' : ''}')),
                            ],
                            onChanged: inProgress
                                ? null
                                : (value) => refresh(() {
                                      if (value == null || value < 0) {
                                        assignment.remove(remote.index);
                                      } else {
                                        assignment.removeWhere((key, v) =>
                                            key != remote.index && v == value);
                                        assignment[remote.index] = value;
                                      }
                                    }),
                          ),
                        ),
                      CheckboxListTile(
                          contentPadding: EdgeInsets.zero,
                          value: save,
                          title: Text(t(
                              'Restore for these computers and displays',
                              'استعادة التوزيع لهذا الجهاز وهذه الشاشات')),
                          subtitle: snapshot.profileKey == null
                              ? Text(t(
                                  'Stable monitor identity is unavailable.',
                                  'لم يتمكن ريمو من تحديد الشاشات بثبات.'))
                              : null,
                          onChanged: snapshot.profileKey == null || inProgress
                              ? null
                              : (value) =>
                                  refresh(() => save = value ?? false)),
                      if (error != null) Text(error!),
                    ],
                  ))),
              actions: [
                TextButton(
                    onPressed: inProgress
                        ? null
                        : () async {
                            if (snapshot.profileKey != null) {
                              await bind.mainSetLocalOption(
                                  key: snapshot.profileKey!, value: '');
                            }
                            refresh(() => assignment.clear());
                          },
                    child: Text(t('Reset', 'إعادة ضبط'))),
                TextButton(
                    onPressed: inProgress ? null : () => Navigator.pop(dialog),
                    child: Text(t('Cancel', 'إلغاء'))),
                FilledButton(
                  onPressed: inProgress || assignment.isEmpty
                      ? null
                      : () async {
                          refresh(() {
                            inProgress = true;
                            error = null;
                          });
                          try {
                            await _apply(ffi, snapshot, assignment);
                            if (save && snapshot.profileKey != null) {
                              final remote = {
                                for (final d in snapshot.remote) d.index: d.id!
                              };
                              final local = {
                                for (final d in snapshot.local) d.index: d.id!
                              };
                              await bind.mainSetLocalOption(
                                  key: snapshot.profileKey!,
                                  value: jsonEncode({
                                    for (final a in assignment.entries)
                                      remote[a.key]!: local[a.value]!,
                                  }));
                            }
                            if (dialog.mounted) Navigator.pop(dialog);
                          } catch (_) {
                            if (dialog.mounted)
                              refresh(() {
                                inProgress = false;
                                error = t(
                                    'The display setup changed. Reconnect and retry.',
                                    'تغيّر إعداد الشاشات. أعد الاتصال وحاول مجدداً.');
                              });
                          }
                        },
                  child: Text(t('Apply', 'تطبيق')),
                ),
              ],
            ),
          ));
}

class _TopologyDiagram extends StatelessWidget {
  const _TopologyDiagram(this.displays);
  final List<RymuDisplay> displays;
  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final left = displays.map((d) => d.x).reduce(math.min);
    final top = displays.map((d) => d.y).reduce(math.min);
    final right = displays.map((d) => d.x + d.width).reduce(math.max);
    final bottom = displays.map((d) => d.y + d.height).reduce(math.max);
    final desktop = math.Rectangle(left, top, right - left, bottom - top);
    return SizedBox(
        height: 116,
        child: LayoutBuilder(builder: (context, constraints) {
          final viewport = fitTopology(desktop, constraints.maxWidth, 116);
          return Stack(children: [
            for (final d in displays)
              _screen(
                  d, fitDisplayInOverview(d.bounds, desktop, viewport), dark),
          ]);
        }));
  }

  Widget _screen(RymuDisplay display, math.Rectangle<double> box, bool dark) =>
      Positioned(
        left: box.left,
        top: box.top,
        width: box.width,
        height: box.height,
        child: DecoratedBox(
            decoration: BoxDecoration(
                color: dark ? const Color(0xff303030) : const Color(0xffededed),
                border: Border.all(color: const Color(0xff808080)),
                borderRadius: BorderRadius.circular(6)),
            child: Center(
                child: Text('${display.index + 1}',
                    style: TextStyle(
                        color: dark ? Colors.white : const Color(0xff1d1d1d),
                        fontWeight: FontWeight.w600)))),
      );
}
