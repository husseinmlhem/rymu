import 'dart:convert';

import 'package:crypto/crypto.dart';

class AccountCallbackPage {
  const AccountCallbackPage({required this.valid, required this.arabic});

  final bool valid;
  final bool arabic;

  String get contentSecurityPolicy =>
      "default-src 'none'; base-uri 'none'; form-action 'none'; "
      "frame-ancestors 'none'; img-src data:; "
      "style-src 'sha256-${_hash(_style)}'; "
      "script-src 'sha256-${_hash(_script)}'";

  static String _hash(String value) =>
      base64.encode(sha256.convert(utf8.encode(value)).bytes);

  String get html {
    String t(String en, String ar) => arabic ? ar : en;
    final state = valid
        ? t('Browser step complete', 'اكتملت خطوة المتصفح')
        : t('This step needs another try',
            'تحتاج هذه الخطوة إلى المحاولة مجددًا');
    final title = valid
        ? t('Back to Rymu.', 'ارجع إلى ريمو.')
        : t('Let’s try that again.', 'لنحاول مرة أخرى.');
    final description = valid
        ? t('Your browser response has reached Rymu. The app will finish linking this device and show you the result.',
            'وصل رد المتصفح إلى ريمو. سيكمل التطبيق ربط هذا الجهاز، وستظهر النتيجة فيه.')
        : t('Rymu could not accept this return. Go back to the app and start sign-in again.',
            'لم يتمكّن ريمو من قبول هذه العودة. ارجع إلى التطبيق وابدأ تسجيل الدخول من جديد.');
    final icon =
        valid ? '<path d="m6 12 4 4 8-8"/>' : '<path d="M12 7v6m0 4h.01"/>';
    final favicon = base64.encode(utf8.encode(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120"><rect width="120" height="120" rx="28" fill="#171717"/><g transform="translate(16 39) scale(.73)" fill="white">$_mark</g></svg>'));
    return '''<!doctype html>
<html lang="${arabic ? 'ar' : 'en'}" dir="${arabic ? 'rtl' : 'ltr'}">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light">
<title>${t('Return to Rymu', 'العودة إلى ريمو')}</title>
<link rel="icon" href="data:image/svg+xml;base64,$favicon">
<style>$_style</style>
<script>$_script</script>
</head>
<body>
<div class="shell">
  <header class="header">
    <div class="brand"><span class="brand-mark" aria-hidden="true"><svg viewBox="0 0 120 56">$_mark</svg></span><span dir="ltr">rymu</span></div>
    <span class="header-label">${t('YOUR DEVICES, TOGETHER', 'أجهزتك، معًا')}</span>
  </header>
  <main class="card" aria-labelledby="page-title">
    <section class="content">
      <div class="status"><span class="status-icon" aria-hidden="true"><svg viewBox="0 0 24 24">$icon</svg></span>$state</div>
      <h1 id="page-title">$title</h1>
      <p class="description">$description</p>
      <div class="next-step">
        <span class="window-icon" aria-hidden="true"><svg viewBox="0 0 24 24"><rect x="3" y="4" width="18" height="14" rx="3"/><path d="M3 8h18m-9 10v3m-4 0h8"/></svg></span>
        <div><strong>${t('Switch to the Rymu app', 'انتقل إلى نافذة ريمو')}</strong><span>${t('Choose Rymu in your taskbar or beside the clock.', 'اختر ريمو من شريط المهام أو من أيقونته بجانب الساعة.')}</span></div>
      </div>
      <details>
        <summary>${t('How do I get back?', 'كيف أعود إلى التطبيق؟')}<svg aria-hidden="true" viewBox="0 0 24 24"><path d="m7 10 5 5 5-5"/></svg></summary>
        <div class="help">
          <p>${t('Press', 'اضغط')} <span class="shortcut" dir="ltr"><kbd>Alt</kbd><span>+</span><kbd>Tab</kbd></span> ${t('and choose Rymu, or open it from the Start menu.', 'واختر ريمو، أو افتحه من قائمة ابدأ.')}</p>
          <p>${valid ? t('Check the result in the app. If it asks you to try again, start sign-in there.', 'راجع النتيجة داخل التطبيق. إذا طلب إعادة المحاولة، ابدأ تسجيل الدخول من هناك.') : t('Choose Sign in in Rymu to begin a new attempt.', 'اختر تسجيل الدخول في ريمو لبدء محاولة جديدة.')}</p>
        </div>
      </details>
      <p class="close-note">${t('You can close this browser tab.', 'يمكنك إغلاق علامة التبويب هذه.')}</p>
    </section>
    <aside class="visual" aria-hidden="true">
      <div class="orbit orbit-one"></div><div class="orbit orbit-two"></div>
      <div class="browser-tile"><span class="browser-dots"><i></i><i></i><i></i></span><span class="tile-line"></span><span class="tile-line short"></span><span class="tile-check"><svg viewBox="0 0 24 24">$icon</svg></span></div>
      <div class="transfer"><i></i><i></i><i></i></div>
      <div class="app-tile"><svg viewBox="0 0 120 56">$_mark</svg></div>
      <div class="visual-copy"><strong>${t('One account. Your world.', 'حساب واحد. كل أجهزتك.')}</strong><span>${t('Pick up where you left off.', 'أكمل من حيث توقّفت.')}</span></div>
    </aside>
  </main>
  <footer><span dir="ltr">RYMU</span><span>${t('Free essentials. Always.', 'الميزات الأساسية مجانية دائمًا.')}</span></footer>
</div>
</body>
</html>''';
  }

  static const _mark =
      '<path d="M4 19c0-3 2.1-5.6 5.1-6.1l11.3-2.4c3.5-.58 6.6 2.2 6.6 5.8V46a6 6 0 0 1-6 6H10a6 6 0 0 1-6-6z M43 4h34a7 7 0 0 1 7 7v34a7 7 0 0 1-7 7H43a7 7 0 0 1-7-7V11a7 7 0 0 1 7-7z M116 19c0-3-2.1-5.6-5.1-6.1l-11.3-2.4c-3.5-.58-6.6 2.2-6.6 5.8V46a6 6 0 0 0 6 6h11a6 6 0 0 0 6-6z"/>';

  static const _script =
      "try { history.replaceState(null, '', location.pathname); } catch (_) {}";

  static const _style = '''
:root{color-scheme:light;font-family:system-ui,"Segoe UI",Tahoma,Arial,sans-serif;color:#171717;background:#f7f7f7;font-synthesis:none}
*{box-sizing:border-box}body{margin:0;background:radial-gradient(ellipse at 75% 0,#e7e7e7,transparent 48%),radial-gradient(ellipse at 0 100%,#ededed,transparent 50%);min-height:100vh}
.shell{width:min(1080px,calc(100% - 64px));min-height:100vh;display:flex;flex-direction:column;justify-content:center;margin:auto;padding:36px 0}
.header{display:flex;align-items:center;justify-content:space-between;gap:20px;margin-bottom:30px}.brand{display:flex;align-items:center;gap:12px;font-size:28px;letter-spacing:-1.1px;font-weight:700}.brand-mark{width:40px;height:40px;border-radius:12px;background:#171717;display:grid;place-items:center;box-shadow:inset 0 1px #ffffff30,0 4px 8px #0000000d}.brand-mark svg{width:29px;fill:#fff}.header-label{font-size:11px;letter-spacing:1.4px;font-weight:600;color:#626262}
.card{display:grid;grid-template-columns:minmax(0,1.25fr) minmax(0,.85fr);border:1px solid #fff;border-radius:32px;background:#ffffffb8;box-shadow:0 28px 68px -32px #0003,inset 0 1px #fff;backdrop-filter:blur(24px);overflow:hidden;animation:enter .45s ease-out both}
.content{padding:50px 48px 38px}.status{display:flex;align-items:center;gap:9px;color:#525252;font-size:13px;font-weight:600;line-height:1.6}.status-icon{display:grid;place-items:center;flex:none;width:24px;height:24px;border-radius:50%;background:#e9e9e9;color:#1c1c1c}.status svg{width:16px;height:16px;fill:none;stroke:currentColor;stroke-width:2;stroke-linecap:round;stroke-linejoin:round}
h1{font-size:clamp(34px,3.6vw,49px);font-weight:700;line-height:1.13;letter-spacing:-2.1px;margin:23px 0 18px}.description{font-size:16px;line-height:1.75;color:#555;margin:0 0 29px;max-width:440px}
.next-step{display:flex;gap:14px;padding:18px;border-radius:18px;background:#fff;border:1px solid #e0e0e0;box-shadow:0 5px 16px -13px #0005}.window-icon{flex:none;width:35px;height:35px;border-radius:10px;background:#f0f0f0;display:grid;place-items:center}.window-icon svg{width:22px;height:22px;fill:none;stroke:#303030;stroke-width:1.6;stroke-linecap:round;stroke-linejoin:round}.next-step strong{display:block;font-size:15px;font-weight:650;line-height:1.5}.next-step div>span{display:block;margin-top:5px;color:#626262;font-size:13px;line-height:1.65}
details{margin-top:21px;font-size:13px;color:#555}summary{list-style:none;display:flex;align-items:center;justify-content:space-between;gap:15px;padding:9px 0;cursor:pointer;color:#343434;font-weight:600}summary::-webkit-details-marker{display:none}summary svg{width:18px;height:18px;fill:none;stroke:currentColor;stroke-width:1.7;transition:transform .2s}details[open] summary svg{transform:rotate(180deg)}summary:focus-visible{outline:2px solid #171717;outline-offset:4px;border-radius:3px}.help{border-top:1px solid #e1e1e1;margin-top:5px;padding-top:4px;line-height:1.85}.help p{margin:10px 0}.shortcut{display:inline-flex;align-items:center;gap:4px;margin:0 3px;white-space:nowrap}kbd{font-family:inherit;font-size:11px;border:1px solid #d4d4d4;border-bottom-width:2px;background:#fff;border-radius:5px;padding:0 5px}.close-note{font-size:12px;color:#686868;margin:27px 0 0;line-height:1.7}
.visual{position:relative;min-height:470px;margin:16px;margin-inline-start:0;background:linear-gradient(148deg,#e7e7e7,#f2f2f2 56%,#dedede);border-radius:23px;overflow:hidden;display:flex;flex-direction:column;align-items:center;justify-content:center;padding:26px;border:1px solid #e0e0e0;isolation:isolate}.orbit{position:absolute;z-index:-1;border:1px solid #fff9;border-radius:50%;width:480px;height:480px;inset-block-start:40px;inset-inline-start:-100px;transform:rotate(-28deg) scaleY(.6)}.orbit-two{transform:rotate(34deg) scaleY(.72);inset-block-start:-50px;inset-inline-start:-30px;width:500px;height:500px}
.browser-tile{position:relative;width:150px;height:99px;border-radius:15px;background:linear-gradient(150deg,#ffffffef,#ffffff85);box-shadow:0 13px 24px -14px #0003,inset 0 1px #fff;border:1px solid #fff;transform:rotate(-7deg);padding:16px}.browser-dots{display:flex;gap:4px;padding-bottom:15px;border-bottom:1px solid #dedede}.browser-dots i{width:4px;height:4px;border-radius:50%;background:#9a9a9a}.tile-line{display:block;background:#d5d5d5;width:58%;height:5px;margin-top:13px;border-radius:9px}.tile-line.short{width:37%;margin-top:7px}.tile-check{position:absolute;inset-inline-end:-12px;bottom:8px;border-radius:50%;height:32px;width:32px;background:#fff;box-shadow:0 4px 10px #00000014;display:grid;place-items:center}.tile-check svg{width:19px;fill:none;stroke:#242424;stroke-width:1.8;stroke-linecap:round;stroke-linejoin:round}.transfer{display:flex;flex-direction:column;gap:8px;margin:17px 0 15px}.transfer i{width:4px;height:4px;border-radius:50%;background:#a3a3a3;animation:pulse 2.4s ease-in-out infinite}.transfer i:nth-child(2){animation-delay:.2s}.transfer i:nth-child(3){animation-delay:.4s}
.app-tile{display:grid;place-items:center;width:100px;height:100px;border-radius:25px;background:linear-gradient(145deg,#353535,#080808);box-shadow:inset 0 1px 1px #ffffff50,inset 0 0 0 1px #fff2,0 16px 25px -12px #0008;transform:rotate(5deg)}.app-tile svg{width:65px;fill:#fff}.visual-copy{text-align:center;margin-top:35px;line-height:1.65}.visual-copy strong{font-size:16px;font-weight:650;display:block}.visual-copy span{font-size:13px;color:#5f5f5f;display:block;margin-top:4px}
footer{display:flex;justify-content:space-between;gap:20px;font-size:11px;color:#686868;margin-top:25px;line-height:1.7}footer span[dir]{letter-spacing:2px;font-size:10px}
[lang=ar] h1{letter-spacing:0;line-height:1.35;font-size:clamp(32px,3.5vw,45px)}[lang=ar] .header-label{letter-spacing:0;font-size:13px}[lang=ar] .description{line-height:1.95}[lang=ar] .visual-copy{line-height:1.9}
@keyframes enter{from{opacity:0;transform:translateY(8px)}to{opacity:1;transform:translateY(0)}}@keyframes pulse{0%,100%{opacity:.3}50%{opacity:1}}
@media(max-width:850px){.shell{width:calc(100% - 40px)}.content{padding:36px 28px}.visual{padding:18px;min-height:430px}.header-label{font-size:10px}h1{font-size:37px}.description{font-size:15px}}
@media(max-width:640px){.shell{width:calc(100% - 32px);padding:24px 0;justify-content:flex-start}.header{margin-bottom:22px}.header-label{display:none}.brand{font-size:25px}.brand-mark{height:36px;width:36px;border-radius:11px}.card{grid-template-columns:1fr;border-radius:24px}.content{padding:29px 23px 25px}.visual{display:none}h1{font-size:36px;letter-spacing:-1.5px;margin-top:22px}.description{margin-bottom:24px}.status{font-size:12px}.next-step{padding:15px;gap:11px}.next-step strong{font-size:14px}.next-step div>span{font-size:12px}.close-note{margin-top:22px}footer{gap:12px;font-size:10px;margin-top:22px}[lang=ar] h1{font-size:34px}}
@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation:none!important;transition:none!important}}
@media(forced-colors:active){.card,.next-step,.visual,.brand-mark,.app-tile,.browser-tile{border:1px solid CanvasText}.status-icon,.window-icon{background:Canvas;color:CanvasText}svg{fill:CanvasText}.window-icon svg,.status svg,summary svg,.tile-check svg{fill:none;stroke:CanvasText}}
''';
}
