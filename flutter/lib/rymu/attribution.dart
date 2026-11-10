import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class RymuAttribution extends StatelessWidget {
  const RymuAttribution({super.key, required this.arabic});

  final bool arabic;

  Future<void> _open(BuildContext context, String address) async {
    var opened = false;
    try {
      opened = await launchUrl(Uri.parse(address),
          mode: LaunchMode.externalApplication);
    } catch (_) {
      // Report a failed external browser handoff in the current application.
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(arabic
              ? 'تعذّر فتح الرابط في المتصفح'
              : 'Could not open the link in your browser')));
    }
  }

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(arabic ? 'تصميم وتطوير حسين ملحم' : 'Created by حسين ملحم',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 4),
          Wrap(spacing: 8, children: [
            TextButton(
                onPressed: () => _open(context, 'https://www.husseinmlhem.com'),
                child: const Text('www.husseinmlhem.com',
                    textDirection: TextDirection.ltr)),
            TextButton(
                onPressed: () => _open(context, 'https://h-m.agency'),
                child:
                    const Text('h-m.agency', textDirection: TextDirection.ltr)),
          ]),
        ]),
      );
}
