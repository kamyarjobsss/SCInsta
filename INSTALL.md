# Install Instagram X

Instagram X is a sideload of Instagram with this tweak injected. It does not use a system VPN profile. You install it from a Mac onto your own iPhone.

This document does not link to decrypted IPAs. You must already have a decrypted `com.burbn.instagram` IPA that you have the right to use (for example an IPA you decrypted from an app you own). The build was aimed at Instagram **436.0.0** (the upstream GPL snapshot targets 434.0.0). Other versions may run, but a changed private class can disable a feature. Missing classes are skipped so the app should still launch.

The injected library stays `SCInsta.dylib`. The home-screen name is **Instagram X**.

---

## English

### 1. What you need

- A Mac with macOS, Xcode command-line tools, and a network connection
- An iPhone signed into an Apple ID you control
- A decrypted Instagram IPA (see above)
- One installer: [Sideloadly](https://sideloadly.io/) (simplest), [AltStore](https://altstore.io/), or TrollStore if your iOS version is one TrollStore supports

A free Apple ID sideload lasts about **7 days**. After that the app will not open until you refresh it from the Mac. A paid developer account lasts longer. Sideloadly and AltStore can refresh for you while the Mac is reachable.

### 2. Build the IPA

**On GitHub Actions**

1. Open this repository → Actions → **Build and Package Instagram X**.
2. Run the workflow.
3. Paste a direct URL to your decrypted IPA.
4. Optional: set **bundle id** to something like `com.yourname.instagramx` if you want Instagram X installed beside the App Store app. Leave it empty to keep `com.burbn.instagram` (the sideload then replaces a copy with that id; it does not replace the App Store app itself, because the signature is different, but iOS may refuse two apps that share an id).
5. Download `InstagramX_sideloaded_v2.0.0.ipa`, or `InstagramX_lite_sideloaded_v2.0.0.ipa` if you do not want the VPN. The workflow publishes both on the prerelease tagged `instagram-x-v2.0.0`.

The default URL is `instagram-v436.ipa` on the `base-ipa` release. The build removes a bundled closed `RyukGram.dylib`, `RyukGram.bundle`, and its load command, plus any previous `SCInsta.dylib`, `FLEXing.dylib`, `libflex.dylib`, and `zxPluginsInject.dylib` (including inside app extensions), then injects Instagram X. `CydiaSubstrate.framework`, `libswiftIU.dylib`, and `libmobile_first_frame_pipeline.framework` stay. ipapatch installs one fresh `zxPluginsInject`. Translations ship in `InstagramX.bundle`. A clean decrypted IPA works the same way.

The full IPA carries Xray as `IXRayCore.dylib` next to the tweak, with no load command, so it stays unmapped until the VPN is turned on. The lite IPA leaves that file out and refuses to start a proxy.

**On your Mac**

```sh
# Theos: https://theos.dev/docs/installation
# Copy iPhoneOS16.2.sdk into $THEOS/sdks
# Go 1.26 or newer (for the in-process Xray core)
brew install ldid dpkg make
# cyan: https://github.com/asdfzxcvbn/pyzule-rw
# ipapatch: https://github.com/asdfzxcvbn/ipapatch/releases/latest  (put it on your PATH)

git clone --recurse-submodules https://github.com/kamyarjobsss/SCInsta.git
cd SCInsta
mkdir -p packages
cp /path/to/your-decrypted.ipa packages/com.burbn.instagram.ipa
chmod +x build.sh scripts/build_ixray.sh

# Optional, installs next to the official app:
# export IX_BUNDLE_ID=com.yourname.instagramx

./build.sh sideload
```

The IPAs are `packages/InstagramX-sideloaded.ipa` and `packages/InstagramX-lite-sideloaded.ipa`. Only one can be installed at a time when they share `com.burbn.instagram`.

Jailbreak packages (no IPA) are `./build.sh rootless` or `./build.sh rootful`. Those use the built-in VLESS engine. Xray is in the full sideload IPA.

### 3. Install with Sideloadly

1. Install Sideloadly on the Mac and open it.
2. Connect the iPhone with a cable and tap Trust on the phone.
3. Sign in with your Apple ID in Sideloadly. Use an app-specific password if the account has two-factor authentication.
4. Drag `InstagramX-sideloaded.ipa` into Sideloadly.
5. Leave the defaults (no extra dylibs; the IPA is already patched). Start the install.
6. On the iPhone, if iOS says the developer is not trusted: **Settings → General → VPN & Device Management** → your Apple ID → Trust.
7. If the app will not launch on iOS 16 or later: **Settings → Privacy & Security → Developer Mode** → turn it on, then restart and confirm.
8. Open **Instagram X**.

Refresh before the 7-day timer ends: connect the phone and install again from Sideloadly, or use Sideloadly's automatic refresh.

### 4. AltStore

1. Install AltServer on the Mac and AltStore on the phone (AltServer's instructions).
2. In AltStore, use the plus button and pick `InstagramX-sideloaded.ipa`.
3. Trust the developer and turn on Developer Mode, same as above.
4. Keep AltServer running when you want the 7-day refresh to happen over Wi-Fi.

### 5. TrollStore

TrollStore only works on specific iOS versions and is not part of this build. If your phone is on a version TrollStore supports, you can open the IPA in TrollStore and install it permanently (no 7-day refresh). That path was **not tested** for Instagram X. If the app crashes at launch, use Sideloadly instead.

### 6. Open the settings

After the first launch, Instagram X may show its settings once.

Later:

- Instagram → your profile → menu → **Settings and activity** → **Instagram X settings** (the holographic row under Accounts Center)
- Or hold the profile menu button
- Or hold the home tab if **Enable tweak settings quick-access** is on

If Instagram's settings screen does not contain the words "Accounts Center" (or the French, Spanish, or Persian equivalents), the row is placed at the top of a screen whose title looks like Settings. If that also fails, the long-press shortcuts still open the same page.

### 7. VPN and fake location

VPN is inside **Instagram X settings → VPN**. Paste a `vless://` link (or several lines, or a base64 subscription). Tap a server to select it and run a TCP latency check. Turn **Enable** on. The status line should say Connected.

Read the VPN limits in the [README](README.md) before you rely on it. In particular, WebRTC calls are blocked by default, some media and WebKit traffic can leave the process, and nothing here has been confirmed on a physical iPhone.

Fake location is the next row. Search or long-press the map, then turn **Use this location** on. **Match timezone** and **Match locale** are optional and off by default.

### 8. Troubleshooting

| What you see | What to try |
| --- | --- |
| "Untrusted Developer" | Settings → General → VPN & Device Management → Trust |
| App closes immediately, Developer Mode off | Settings → Privacy & Security → Developer Mode |
| Sideloadly "provisioning" or "device limit" | Remove an old sideloaded app, or wait and retry. Free accounts have a small app limit. |
| Expired after a week | Reinstall or refresh from the Mac |
| Instagram X opens but settings row is missing | Hold the profile menu button. The row is a visual insert and can miss a Bloks layout that does not use a normal table. |
| VPN stays on Disconnected | The link may need a feature the engine rejected, or the server did not accept the login. The status line includes the error. REALITY links need the Xray-linked IPA from CI or a Mac build, not a Linux build. |
| App crashes as soon as it opens with VPN set to on | Force-quit, reinstall a build, and leave VPN off. The embedded Go runtime is untested on device and is the first thing to suspect. |
| Location did not change | Confirm the toggle is on and a pin was saved. Fully close Instagram X and open it again. Some screens cache a location from before the toggle. |
| Two Instagram icons | You set `IX_BUNDLE_ID`. That is expected. Delete the one you do not want. |

---

## فارسی

### اینستاگرام ایکس چیست؟

اینستاگرام ایکس نسخهٔ سایدلود اینستاگرام است که این توییک داخلش تزریق شده. پروفایل VPN سیستمی ساخته نمی‌شود. نصب از مک روی آیفون خودتان انجام می‌شود.

این راهنما لینک IPA رمزگشایی‌شده نمی‌دهد. باید خودتان یک IPA رمزگشایی‌شده از `com.burbn.instagram` داشته باشید که حق استفاده از آن را دارید. ساخت برای اینستاگرام **418.2.0** آماده شده. نسخه‌های دیگر ممکن است اجرا شوند، ولی اگر کلاس خصوصی عوض شده باشد یک قابلیت کار نمی‌کند. کلاس غایب نادیده گرفته می‌شود تا برنامه در حد امکان باز بماند.

نام کتابخانهٔ تزریق‌شده همچنان `SCInsta.dylib` است. نام روی صفحهٔ خانه **Instagram X** است.

### ۱. چه چیزهایی لازم است

- مک با ابزارهای خط فرمان Xcode و اینترنت
- آیفون با Apple ID خودتان
- IPA رمزگشایی‌شدهٔ اینستاگرام
- یکی از این نصب‌کننده‌ها: [Sideloadly](https://sideloadly.io/) (ساده‌ترین)، [AltStore](https://altstore.io/)، یا TrollStore اگر نسخهٔ iOS شما را پشتیبانی کند

با Apple ID رایگان، برنامه حدود **۷ روز** باز می‌شود. بعد از آن تا وقتی از مک تازه نشود باز نمی‌شود. حساب توسعه‌دهندهٔ پولی مدت بیشتری می‌ماند. Sideloadly و AltStore می‌توانند وقتی مک در دسترس است تمدید کنند.

### ۲. ساخت IPA

**با GitHub Actions**

1. در این مخزن بروید به Actions و workflow با نام **Build and Package Instagram X**.
2. آن را اجرا کنید.
3. لینک مستقیم IPA رمزگشایی‌شدهٔ خودتان را بگذارید.
4. اختیاری: اگر می‌خواهید اینستاگرام ایکس کنار برنامهٔ اپ‌استور نصب شود، bundle id را چیزی مثل `com.yourname.instagramx` بگذارید. خالی بماند یعنی همان `com.burbn.instagram`. iOS معمولاً دو برنامه با یک شناسه را هم‌زمان قبول نمی‌کند.
5. فایل `InstagramX_sideloaded_v2.0.0.ipa` را دانلود کنید، یا اگر VPN نمی‌خواهید `InstagramX_lite_sideloaded_v2.0.0.ipa`. هر دو روی prerelease با برچسب `instagram-x-v2.0.0` منتشر می‌شوند.

لینک پیش‌فرض `instagram-v436.ipa` روی release با برچسب `base-ipa` است. بیلد، `RyukGram.dylib` و `RyukGram.bundle` بسته‌شده و load command آن، به‌علاوهٔ `SCInsta.dylib` و `FLEXing.dylib` و `libflex.dylib` و `zxPluginsInject.dylib` قدیمی (از جمله داخل افزونه‌ها) را برمی‌دارد و اینستاگرام ایکس را تزریق می‌کند. `CydiaSubstrate.framework` و `libswiftIU.dylib` و `libmobile_first_frame_pipeline.framework` می‌مانند. ترجمه‌ها در `InstagramX.bundle` هستند.

IPA کامل، Xray را به‌صورت `IXRayCore.dylib` کنار توییک می‌گذارد و load command ندارد، پس تا وقتی VPN روشن نشود به حافظه نمی‌آید. IPA لایت آن فایل را ندارد و پروکسی را راه نمی‌اندازد.

**روی مک خودتان**

```sh
# Theos: https://theos.dev/docs/installation
# پوشهٔ iPhoneOS16.2.sdk را در $THEOS/sdks بگذارید
# Go نسخهٔ 1.26 یا جدیدتر برای هستهٔ Xray
brew install ldid dpkg make
# cyan و ipapatch را نصب کنید و ipapatch را در PATH بگذارید

git clone --recurse-submodules https://github.com/kamyarjobsss/SCInsta.git
cd SCInsta
mkdir -p packages
cp /path/to/your-decrypted.ipa packages/com.burbn.instagram.ipa
chmod +x build.sh scripts/build_ixray.sh

# اختیاری، نصب کنار برنامهٔ رسمی:
# export IX_BUNDLE_ID=com.yourname.instagramx

./build.sh sideload
```

خروجی این است: `packages/InstagramX-sideloaded.ipa` و `packages/InstagramX-lite-sideloaded.ipa`.

برای جیلبریک، بدون IPA: `./build.sh rootless` یا `./build.sh rootful`. این دو از موتور VLESS داخلی استفاده می‌کنند. Xray در IPA کامل سایدلود است.

### ۳. نصب با Sideloadly

1. Sideloadly را روی مک نصب و باز کنید.
2. آیفون را با کابل وصل کنید و روی گوشی Trust را بزنید.
3. با Apple ID وارد شوید. اگر تأیید دو مرحله‌ای روشن است، از app-specific password استفاده کنید.
4. فایل IPA را داخل Sideloadly بیندازید.
5. dylib اضافه نکنید؛ IPA از قبل وصله شده. نصب را شروع کنید.
6. اگر iOS گفت توسعه‌دهنده نامعتبر است: **Settings → General → VPN & Device Management** → Apple ID شما → Trust.
7. اگر روی iOS 16 یا جدیدتر برنامه باز نشد: **Settings → Privacy & Security → Developer Mode** را روشن کنید، ری‌استارت کنید و تأیید کنید.
8. **Instagram X** را باز کنید.

پیش از پایان ۷ روز دوباره از Sideloadly نصب یا تمدید کنید.

### ۴. AltStore

1. AltServer را روی مک و AltStore را روی گوشی نصب کنید.
2. در AltStore دکمهٔ به‌علاوه را بزنید و `InstagramX-sideloaded.ipa` را انتخاب کنید.
3. اعتماد به توسعه‌دهنده و Developer Mode مثل بخش قبل.
4. برای تمدید ۷روزه از راه وای‌فای، AltServer باید روشن باشد.

### ۵. TrollStore

TrollStore فقط روی نسخه‌های خاصی از iOS کار می‌کند و بخشی از این ساخت نیست. اگر گوشی شما پشتیبانی می‌شود، IPA را در TrollStore باز کنید تا بدون تمدید ۷روزه نصب شود. این مسیر برای اینستاگرام ایکس **تست نشده**. اگر برنامه همان اول کرش کرد، Sideloadly را استفاده کنید.

### ۶. باز کردن تنظیمات

بعد از اولین اجرا ممکن است تنظیمات یک بار باز شود.

بعداً:

- اینستاگرام → پروفایل → منو → **Settings and activity** → ردیف **Instagram X settings** (ردیف هولوگرافیک زیر Accounts Center / مرکز حساب)
- یا دکمهٔ منوی پروفایل را نگه دارید
- یا اگر گزینهٔ میانبر روشن است، تب خانه را نگه دارید

اگر صفحهٔ تنظیمات عبارت Accounts Center (یا معادل فرانسوی، اسپانیایی، یا «مرکز حساب») را نداشته باشد، ردیف بالای صفحه‌ای گذاشته می‌شود که عنوانش شبیه تنظیمات باشد. اگر آن هم پیدا نشود، همان نگه داشتن دکمهٔ منو صفحه را باز می‌کند.

### ۷. VPN و مکان جعلی

VPN اینجاست: **Instagram X settings → VPN**. یک لینک `vless://` (یا چند خط، یا اشتراک base64) بچسبانید. روی سرور بزنید تا انتخاب شود و تأخیر TCP سنجیده شود. **Enable** را روشن کنید. وضعیت باید Connected شود.

پیش از اتکا به VPN، محدودیت‌ها را در [README](README.md) بخوانید. تماس WebRTC به‌طور پیش‌فرض بسته است، بخشی از مدیا و WebKit ممکن است از این پروسه خارج شود، و هیچ‌کدام روی آیفون واقعی تأیید نشده است.

مکان جعلی ردیف بعدی است. جستجو کنید یا روی نقشه طولانی فشار دهید، بعد **Use this location** را روشن کنید. هم‌خوان کردن منطقهٔ زمانی و زبان اختیاری و پیش‌فرض خاموش است.

### ۸. رفع اشکال

| چیزی که می‌بینید | کار پیشنهادی |
| --- | --- |
| Untrusted Developer | Settings → General → VPN & Device Management → Trust |
| برنامه فوری بسته می‌شود و Developer Mode خاموش است | Settings → Privacy & Security → Developer Mode |
| خطای provisioning یا سقف برنامه در Sideloadly | یک برنامهٔ سایدلود قدیمی را پاک کنید یا دوباره تلاش کنید. حساب رایگان سقف کمی دارد. |
| بعد از یک هفته منقضی شد | دوباره از مک نصب یا تمدید کنید |
| برنامه باز می‌شود ولی ردیف تنظیمات نیست | دکمهٔ منوی پروفایل را نگه دارید. ردیف یک لایهٔ بصری است و ممکن است روی چیدمان Bloks که جدول معمولی نیست دیده نشود. |
| VPN روی Disconnected می‌ماند | لینک ممکن است قابلیتی بخواهد که موتور رد کرده، یا سرور ورود را قبول نکرده. متن خطا در همان ردیف وضعیت است. لینک REALITY به IPA ساخته‌شده با Xray (CI یا مک) نیاز دارد، نه ساخت لینوکس. |
| با VPN روشن، برنامه همان اول کرش می‌کند | برنامه را ببندید، دوباره نصب کنید و VPN را خاموش بگذارید. زمان‌اجرای Go داخل dylib روی دستگاه تست نشده و اولین مظنون است. |
| مکان عوض نشد | مطمئن شوید کلید روشن است و پین ذخیره شده. اینستاگرام ایکس را کامل ببندید و دوباره باز کنید. بعضی صفحه‌ها مکان قبلی را نگه می‌دارند. |
| دو آیکون اینستاگرام | `IX_BUNDLE_ID` را گذاشته‌اید. این رفتار درست است. آیکونی را که نمی‌خواهید پاک کنید. |
