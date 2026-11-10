import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/file_model.dart';
import 'package:flutter_hbb/rymu/file_locations.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the concrete Windows locations returned by the host', () {
    final locations = RymuFileLocation.decode(r'''
      [
        {"kind":"desktop","path":"D:\\OneDrive\\Desktop","available":true},
        {"kind":"network","path":"Y:\\","available":false},
        {"kind":"music","path":null,"available":false}
      ]
    ''');
    expect(locations.first.path, r'D:\OneDrive\Desktop');
    expect(locations[1].isDrive, isTrue);
    expect(locations[1].available, isFalse);
    expect(locations.last.path, isNull);
    expect(
      () => RymuFileLocation.decode(
          '[{"kind":"network","path":null,"available":true}]'),
      throwsFormatException,
    );
  });

  test('chooses a different Windows name before sending a colliding upload',
      () {
    expect(
      windowsUploadCopyName('Report.pdf', {'report.pdf', 'report (2).pdf'},
          directory: false),
      'Report (3).pdf',
    );
    expect(
      windowsUploadCopyName('March.2026', {'march.2026'}, directory: true),
      'March.2026 (2)',
    );
  });

  testWidgets('This PC keeps an offline mapping disabled until refreshed',
      (tester) async {
    var driveAvailable = false;
    var loads = 0;
    String? selected;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              selected = await showDialog<String>(
                context: context,
                builder: (_) => RymuWindowsLocations(
                  arabic: true,
                  load: () async {
                    loads++;
                    return [
                      const RymuFileLocation(
                          'desktop', r'D:\OneDrive\Desktop', true),
                      RymuFileLocation('network', r'Y:\', driveAvailable),
                    ];
                  },
                ),
              );
            },
            child: const Text('Open'),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(find.text('سطح المكتب'), findsOneWidget);
    await tester.tap(find.text('هذا الكمبيوتر'));
    await tester.pumpAndSettle();
    expect(find.text('غير متاح'), findsOneWidget);
    final networkTile = find.widgetWithText(ListTile, 'قرص شبكة');
    expect(tester.widget<ListTile>(networkTile).enabled, isFalse);

    driveAvailable = true;
    await tester.tap(find.byTooltip('تحديث المواقع'));
    await tester.pumpAndSettle();
    expect(loads, 2);
    expect(tester.widget<ListTile>(networkTile).enabled, isTrue);
    await tester.tap(networkTile);
    await tester.pumpAndSettle();
    expect(selected, r'Y:\');
  });
}
