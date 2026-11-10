import 'dart:io' as io;

import 'package:flutter_tools/src/base/context.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/template.dart';
import 'package:flutter_tools/src/features.dart';
import 'package:flutter_tools/src/flutter_plugins.dart';
import 'package:flutter_tools/src/globals.dart' as globals;
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/version.dart';
import 'package:mustache_template/mustache_template.dart';

// Use the pinned Flutter generator for metadata. The wrapper supplies NTFS
// junctions for Windows plugins after generation.
class _ManualLinks extends FeatureFlags {
  const _ManualLinks();

  @override
  bool isEnabled(Feature feature) => false;
}

class _Renderer extends TemplateRenderer {
  const _Renderer();

  @override
  String renderString(String template, dynamic context,
      {bool htmlEscapeValues = false}) {
    return Template(template, lenient: true, htmlEscapeValues: htmlEscapeValues)
        .renderString(context);
  }
}

Future<void> main(List<String> arguments) async {
  if (arguments.length != 2 || !io.Platform.isWindows) {
    throw ArgumentError('Pass the Windows Flutter project and SDK directory.');
  }
  final logger = BufferLogger.test(verbose: true);
  await context.run(
    overrides: {
      Logger: () => logger,
      TemplateRenderer: () => const _Renderer(),
      FeatureFlags: () => const _ManualLinks(),
      FlutterVersion: () =>
          FlutterVersion(fs: globals.fs, flutterRoot: arguments[1]),
    },
    body: () async {
      final project =
          FlutterProject.fromDirectory(globals.fs.directory(arguments[0]));
      await refreshPluginsList(project, forceCocoaPodsOnly: true);
      await injectPlugins(project, windowsPlatform: true);
      io.stdout.writeln(project.windows.generatedPluginCmakeFile.path);
    },
  );
}
