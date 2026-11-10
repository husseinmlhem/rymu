import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/generated_bridge.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/rymu/attribution.dart';
import 'package:flutter_hbb/rymu/file_locations.dart';
import 'package:flutter_hbb/rymu_android/receiving_folder.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:uuid/uuid.dart';

final _id = UuidValue('00000000-0000-0000-0000-000000000000');

class _Binding extends Fake implements RustdeskImpl {
  final options = <String, String>{};
  @override
  String getLocalFlutterOption({required String k, dynamic hint}) =>
      options[k] ?? '';
  @override
  Future<void> setLocalFlutterOption(
          {required String k, required String v, dynamic hint}) async =>
      options[k] = v;
  @override
  Future<String> mainGetHomeDir({dynamic hint}) async => '/old-home';
  @override
  Future<String> sessionGetPeerOption(
          {required UuidValue sessionId,
          required String name,
          dynamic hint}) async =>
      name == 'local_dir' ? '/old-peer-folder' : '';
}

class _Session extends Fake implements FFI {}

class _Directories extends FileFetcher {
  _Directories() : super(() => _id);
  final opened = <String>[];
  @override
  Future<FileDirectory> fetchDirectory(
      String path, bool isLocal, bool showHidden) async {
    opened.add(path);
    return FileDirectory()..path = path;
  }
}

class _RemoteFolder extends Fake implements FileController {
  List<RymuFileLocation> locations = [];
  final opened = <String>[];
  @override
  Future<List<RymuFileLocation>> windowsLocations() async => locations;
  @override
  Future<bool> openDirectory(String path, {bool isBack = false}) async {
    opened.add(path);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('new transfers reuse the selected receiving folder without a picker',
      () async {
    final binding = _Binding();
    platformFFI.setBindingForTesting(binding);
    const folder = '/@rustdesk/tree/authorized-grant/Transfers';
    await RymuReceivingFolder.remember(folder);
    final session = _Session();
    for (var attempt = 0; attempt < 2; attempt++) {
      expect(await RymuReceivingFolder.resolve(), folder);
      final directories = _Directories();
      final controller = FileController(
        isLocal: true,
        getSessionID: () => _id,
        rootState: WeakReference(session),
        jobController: JobController(() => _id, () => null),
        fileFetcher: directories,
        getOtherSideDirectoryData: () =>
            DirectoryData(FileDirectory(), DirectoryOptions()),
      )..startingDirectory = () async => r'C:\Receiving';
      await controller.onReady();
      expect(controller.directory.value.path, r'C:\Receiving');
      expect(directories.opened, [r'C:\Receiving']);
    }
    await expectLater(
        RymuReceivingFolder.remember('/ungranted/path'), throwsArgumentError);
    expect(RymuReceivingFolder.selected, folder);
    await RymuReceivingFolder.useWorkspace();
    expect(RymuReceivingFolder.selected, isNull);
  });

  testWidgets('remote shortcut opens only the designated exchange location',
      (tester) async {
    final controller = _RemoteFolder()
      ..locations = [
        const RymuFileLocation('profile', r'C:\Users\Example', true),
        const RymuFileLocation(
            'exchange', r'C:\Users\Example\Rymu\Files', true),
      ];
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Builder(
                builder: (context) => TextButton(
                    onPressed: () => openRymuTransferFolder(context, controller,
                        arabic: false),
                    child: const Text('Folder'))))));
    await tester.tap(find.text('Folder'));
    await tester.pumpAndSettle();
    expect(controller.opened, [r'C:\Users\Example\Rymu\Files']);
    controller.locations = [
      const RymuFileLocation('profile', r'C:\Users\Example', true)
    ];
    await tester.tap(find.text('Folder'));
    await tester.pumpAndSettle();
    expect(controller.opened, hasLength(1));
    expect(
        find.textContaining('transfer folder is unavailable'), findsOneWidget);
  });

  testWidgets('Arabic credits fit narrow settings and open the requested links',
      (tester) async {
    final links = <String>[];
    const launcher = MethodChannel('plugins.flutter.io/url_launcher');
    final messenger = tester.binding.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(launcher, (call) async {
      links.add(call.arguments['url'] as String);
      expect(call.arguments['useWebView'], isFalse);
      return true;
    });
    addTearDown(() => messenger.setMockMethodCallHandler(launcher, null));
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: Directionality(
      textDirection: TextDirection.rtl,
      child: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
          child: const RymuAttribution(arabic: true)),
    ))));
    expect(find.text('تصميم وتطوير حسين ملحم'), findsOneWidget);
    await tester.tap(find.text('www.husseinmlhem.com'));
    await tester.pump();
    await tester.tap(find.text('h-m.agency'));
    await tester.pump();
    expect(
        links, ['https://www.husseinmlhem.com', 'https://h-m.agency']);
    expect(tester.takeException(), isNull);
  });
}
