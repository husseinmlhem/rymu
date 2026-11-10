import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_hbb/rymu/account_callback_page.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('received callback explains the remaining app step in both languages',
      () {
    final en = const AccountCallbackPage(valid: true, arabic: false).html;
    final ar = const AccountCallbackPage(valid: true, arabic: true).html;
    expect(en, contains('lang="en" dir="ltr"'));
    expect(ar, contains('lang="ar" dir="rtl"'));
    expect(en, contains('The app will finish linking this device'));
    expect(ar, contains('سيكمل التطبيق ربط هذا الجهاز'));
    expect(en, isNot(contains('Successfully signed in')));
    expect(en, contains('<details>'));
    expect(en, isNot(contains('window.close')));
    expect(en, isNot(contains('app.rymu:')));
  });

  test('rejected callback has an honest retry state with no credential echo',
      () {
    final page = const AccountCallbackPage(valid: false, arabic: true).html;
    expect(page, contains('لم يتمكّن ريمو من قبول هذه العودة'));
    expect(page, contains('ابدأ تسجيل الدخول من جديد'));
    expect(page, isNot(contains('اكتملت خطوة المتصفح')));
    expect(page, isNot(contains('location.search')));
    expect(page, contains("history.replaceState(null, '', location.pathname)"));
  });

  test('CSP permits only exact embedded style and script with no remote assets',
      () {
    const page = AccountCallbackPage(valid: true, arabic: false);
    for (final tag in ['style', 'script']) {
      final content =
          RegExp('<$tag>([\\s\\S]*?)</$tag>').firstMatch(page.html)!.group(1)!;
      final hash = base64.encode(sha256.convert(utf8.encode(content)).bytes);
      expect(page.contentSecurityPolicy, contains("$tag-src 'sha256-$hash'"));
    }
    expect(page.contentSecurityPolicy, contains("default-src 'none'"));
    expect(page.contentSecurityPolicy, contains("frame-ancestors 'none'"));
    expect(page.contentSecurityPolicy, isNot(contains('unsafe-inline')));
    expect(page.html, isNot(matches(r'(?:src|href)="https?://')));
    expect(page.html, contains('prefers-reduced-motion:reduce'));
  });
}
