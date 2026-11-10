import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/file_model.dart';

Future<String> rymuTransferFolderPath(FileController controller) async {
  final locations = await controller.windowsLocations();
  final exchange = locations
      .where((location) => location.kind == 'exchange' && location.available);
  if (exchange.length != 1) {
    throw StateError('The Rymu transfer folder is unavailable');
  }
  return exchange.single.path!;
}

Future<void> openRymuTransferFolder(
    BuildContext context, FileController controller,
    {required bool arabic}) async {
  var opened = false;
  try {
    opened = await controller
        .openDirectory(await rymuTransferFolderPath(controller));
  } catch (_) {
    // A missing/denied exchange folder must not redirect into a broader root.
  }
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(arabic
            ? 'مجلد نقل ريمو غير متاح حالياً. أعد الاتصال أو اختر موقعاً متاحاً.'
            : 'The Rymu transfer folder is unavailable. Reconnect or choose an available location.')));
  }
}

Future<void> showRymuWindowsLocations(
    BuildContext context, FileController controller,
    {bool? arabic, bool showDrives = false}) async {
  final useArabic =
      arabic ?? Localizations.localeOf(context).languageCode == 'ar';
  final path = await showDialog<String>(
    context: context,
    builder: (_) => RymuWindowsLocations(
      load: controller.windowsLocations,
      arabic: useArabic,
      showDrives: showDrives,
    ),
  );
  if (path == null || !context.mounted) return;
  final opened = await controller.openDirectory(path);
  if (!opened && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(useArabic
          ? 'هذا الموقع غير متاح حالياً'
          : 'This location is unavailable'),
    ));
  }
}

class RymuWindowsLocations extends StatefulWidget {
  const RymuWindowsLocations({
    super.key,
    required this.load,
    required this.arabic,
    this.showDrives = false,
  });

  final Future<List<RymuFileLocation>> Function() load;
  final bool arabic;
  final bool showDrives;

  @override
  State<RymuWindowsLocations> createState() => _RymuWindowsLocationsState();
}

class _RymuWindowsLocationsState extends State<RymuWindowsLocations> {
  late Future<List<RymuFileLocation>> _locations;
  late bool _showDrives;

  String _text(String en, String ar) => widget.arabic ? ar : en;

  @override
  void initState() {
    super.initState();
    _showDrives = widget.showDrives;
    _locations = widget.load();
  }

  @override
  Widget build(BuildContext context) {
    final height = (MediaQuery.sizeOf(context).height * 0.54)
        .clamp(112.0, 420.0)
        .toDouble();
    return Directionality(
      textDirection: widget.arabic ? TextDirection.rtl : TextDirection.ltr,
      child: AlertDialog(
        scrollable: true,
        title: Row(children: [
          if (_showDrives)
            IconButton(
              tooltip: _text('Locations', 'المواقع'),
              icon: const Icon(Icons.arrow_back),
              onPressed: () => setState(() => _showDrives = false),
            ),
          Expanded(
              child: Text(_showDrives
                  ? _text('This PC', 'هذا الكمبيوتر')
                  : _text('Windows locations', 'مواقع ويندوز'))),
          IconButton(
            tooltip: _text('Refresh locations', 'تحديث المواقع'),
            icon: const Icon(Icons.refresh),
            onPressed: () {
              final fresh = widget.load();
              setState(() {
                _locations = fresh;
              });
            },
          ),
        ]),
        content: SizedBox(
          width: 420,
          height: height,
          child: FutureBuilder<List<RymuFileLocation>>(
            future: _locations,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (!snapshot.hasData) {
                return Center(
                    child: Text(_text('Windows locations could not be loaded.',
                        'تعذّر تحميل مواقع ويندوز.')));
              }
              final visible = snapshot.data!
                  .where((location) => location.isDrive == _showDrives);
              return ListView(children: [
                if (!_showDrives)
                  ListTile(
                    leading: const Icon(Icons.computer),
                    title: Text(_text('This PC', 'هذا الكمبيوتر')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => setState(() => _showDrives = true),
                  ),
                for (final location in visible)
                  _locationTile(context, location),
                if (_showDrives && visible.isEmpty)
                  ListTile(
                      title: Text(
                          _text('No known drives', 'لا توجد أقراص معروفة'))),
              ]);
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(_text('Close', 'إغلاق')),
          ),
        ],
      ),
    );
  }

  Widget _locationTile(BuildContext context, RymuFileLocation location) {
    final (title, icon) = switch (location.kind) {
      'desktop' => (
          _text('Desktop', 'سطح المكتب'),
          Icons.desktop_windows_outlined
        ),
      'downloads' => (_text('Downloads', 'التنزيلات'), Icons.download_outlined),
      'documents' => (
          _text('Documents', 'المستندات'),
          Icons.description_outlined
        ),
      'pictures' => (_text('Pictures', 'الصور'), Icons.image_outlined),
      'videos' => (_text('Videos', 'الفيديوهات'), Icons.videocam_outlined),
      'music' => (_text('Music', 'الموسيقى'), Icons.music_note_outlined),
      'profile' => (
          _text('User folder', 'مجلد المستخدم'),
          Icons.person_outline
        ),
      'exchange' => (
          _text('Rymu exchange', 'مجلد تبادل ريمو'),
          Icons.folder_outlined
        ),
      'network' => (_text('Network drive', 'قرص شبكة'), Icons.lan_outlined),
      'removable' => (
          _text('Removable drive', 'قرص قابل للإزالة'),
          Icons.usb_outlined
        ),
      'optical' => (_text('Optical drive', 'قرص ضوئي'), Icons.album_outlined),
      'ram' => (_text('RAM drive', 'قرص ذاكرة'), Icons.memory_outlined),
      _ => (_text('Drive', 'قرص'), Icons.storage_outlined),
    };
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: location.available
          ? Text(location.path!,
              textDirection: TextDirection.ltr, overflow: TextOverflow.ellipsis)
          : Text(_text('Unavailable', 'غير متاح')),
      trailing: location.isDrive
          ? Text(location.path ?? '', textDirection: TextDirection.ltr)
          : null,
      enabled: location.available,
      onTap: location.available
          ? () => Navigator.of(context).pop(location.path)
          : null,
    );
  }
}
