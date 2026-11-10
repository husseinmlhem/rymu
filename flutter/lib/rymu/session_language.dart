import 'package:flutter/material.dart';
import 'package:flutter_hbb/models/model.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:get/get.dart';

const rymuLocalLanguageKey = 'rymu-ui-language';
const _sessionLanguageKey = 'rymu-session-language';

Future<void> applyRymuSessionLanguage(PeerInfo info) async {
  final saved = bind.mainGetLocalOption(key: _sessionLanguageKey);
  final local = bind.mainGetLocalOption(key: rymuLocalLanguageKey);
  final actual = info.platformAdditions['rymu_ui_locale'];
  final String language;
  if (saved == 'en' || saved == 'ar') {
    language = saved;
  } else if (actual == 'ar' || actual == 'en') {
    language = actual as String;
  } else if (local == 'en' || local == 'ar') {
    language = local;
  } else {
    language = Get.deviceLocale?.languageCode == 'ar' ? 'ar' : 'en';
  }
  if (Get.locale?.languageCode != language)
    await Get.updateLocale(Locale(language));
}

Future<void> showRymuSessionLanguage(
    BuildContext context, PeerInfo info) async {
  final ar = Directionality.of(context) == TextDirection.rtl;
  String t(String en, String arText) => ar ? arText : en;
  final saved = bind.mainGetLocalOption(key: _sessionLanguageKey);
  final remoteUi = info.platformAdditions['rymu_ui_locale'];
  final remoteLayout = info.platformAdditions['rymu_keyboard_layout'];
  final selection = await showDialog<String>(
      context: context,
      builder: (dialog) => SimpleDialog(
            title: Text(t('Language and keyboard', 'اللغة ولوحة المفاتيح')),
            children: [
              Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Text(t('Remote UI: ', 'واجهة الكمبيوتر البعيد: ') +
                      (remoteUi == 'ar'
                          ? 'العربية'
                          : remoteUi == 'en'
                              ? 'English'
                              : t('Unknown', 'غير معروفة')))),
              Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
                  child: Text(t('Keyboard layout at connection: ',
                          'تخطيط لوحة المفاتيح عند الاتصال: ') +
                      (remoteLayout is String
                          ? '\u2066$remoteLayout\u2069'
                          : t('Unknown', 'غير معروف')))),
              for (final option in ['auto', 'en', 'ar'])
                SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialog, option),
                    child: Text(
                        '${option == (saved.isEmpty ? 'auto' : saved) ? '✓  ' : ''}'
                        '${option == 'auto' ? t('Follow remote language', 'اتّباع لغة الكمبيوتر البعيد') : option == 'en' ? 'English' : 'العربية'}')),
            ],
          ));
  if (selection == null) return;
  await bind.mainSetLocalOption(key: _sessionLanguageKey, value: selection);
  await applyRymuSessionLanguage(info);
}
