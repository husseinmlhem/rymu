import '../models/platform_model.dart';
import '../utils/android_documents.dart';

/// A controller-only preference. It does not share this folder with peers or
/// grant storage access: Android's persisted document-tree grant is still used.
class RymuReceivingFolder {
  static const option = 'rymu-receiving-folder';

  static String? get selected {
    final value = bind.getLocalFlutterOption(k: option);
    return AndroidDocuments.isRoot(value) ? value : null;
  }

  static Future<String> resolve() async =>
      selected ?? await AndroidDocuments.workspace();

  static Future<void> remember(String path) async {
    if (!AndroidDocuments.isRoot(path)) {
      throw ArgumentError('Select a document folder through Android');
    }
    await bind.setLocalFlutterOption(k: option, v: path);
  }

  static Future<void> useWorkspace() =>
      bind.setLocalFlutterOption(k: option, v: '');
}
