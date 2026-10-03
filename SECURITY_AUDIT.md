# Instagram X 2.1.0 — security audit

## English

This note covers the tweak sources that ship in the sideload IPA and the binaries the build keeps from the decrypted Instagram 436 base. It is a source review plus a search for hardcoded hosts. It is not a runtime trace of Instagram itself.

### What the tweak contacts

| When | Host | Why |
| --- | --- | --- |
| VPN is turned on, and the server in the link is a name | `1.1.1.1`, `1.0.0.1`, and `8.8.8.8` over HTTPS | Resolve that name with DNS-over-HTTPS so the phone's resolver is not used |
| VPN reports Connected, and when Test is tapped | `connectivitycheck.gstatic.com` or `www.gstatic.com`, through the local proxy | One `generate_204` request. Connected is shown only if this returns HTTP 204 |
| While the VPN is on | The server in the user's own `vless://` link | The tunnel the user configured |
| Profile Analyzer, downloads, and normal Instagram use | `i.instagram.com` and the rest of Instagram's own API | The app talking to Instagram, including features that read the logged-in account |

Nothing in this build phones home for analytics, remote config, or an update check. The GitHub release fetch, the Ko-fi link, the avatar image loads, and the Imgur sample cell are not called.

### Bundled binaries

The sideload build removes the closed `RyukGram.dylib` and `RyukGram.bundle`. It keeps pieces the Instagram binary already expects:

- `CydiaSubstrate.framework` — method swizzling for the tweak. It is not a network client.
- `libswiftIU.dylib` and `libmobile_first_frame_pipeline.framework` — Instagram libraries left in place so the app still launches.
- `zxPluginsInject` — present in the owner's 436 base. This build does not add it and does not give it a new network job. Treat an untouched copy of that base as outside this review.
- `IXRayCore.dylib` — Xray, opened with `dlopen` only after the VPN switch is turned on. It has no load command, so it is not mapped at launch.
- `FLEX` — a debug explorer. It stays off unless a debug switch is enabled. It is not a telemetry client.

No login or password field is hooked. The tweak does not read the keychain to send credentials, cookies, or session tokens to a third party.

### Account-risk features

These stay in the app because they are the product. Instagram can flag an account for them:

- Hiding story and message seen-receipts (حالت روح)
- Fake location
- Downloads and a separate Photos album
- Profile Analyzer, which walks account data through Instagram's API
- Confirm dialogs do not remove that risk; they only ask before an action

### Crash rules

Socket hooks are data-pointer rebinds. There is no `MSHookFunction` and no inline patch. The rebinds are installed only while the VPN is on, and `IXRayCore.dylib` is skipped so the tunnel is not routed into itself.

## فارسی

این یادداشت کد افزونه‌ای را که داخل IPA سایدلود می‌آید بررسی می‌کند، به‌همراه باینری‌هایی که از اینستاگرام ۴۳۶ رمزگشایی‌شده نگه داشته شده‌اند. این یک مرور منبع و جستجوی آدرس‌های ثابت است، نه ردگیری لحظه‌ای خود اینستاگرام.

### این افزونه به کجا وصل می‌شود

| چه وقت | میزبان | چرا |
| --- | --- | --- |
| روشن شدن فیلترشکن، اگر نام سرور در لینک دامنه باشد | `1.1.1.1` و `1.0.0.1` و `8.8.8.8` با HTTPS | پیدا کردن IP همان نام با DNS-over-HTTPS، بدون DNS گوشی |
| وقتی وضعیت «متصل» می‌شود، و با زدن آزمایش | `connectivitycheck.gstatic.com` یا `www.gstatic.com` از داخل پروکسی محلی | یک درخواست `generate_204`. «متصل» فقط اگر پاسخ ۲۰۴ باشد نشان داده می‌شود |
| وقتی فیلترشکن روشن است | سروری که در لینک `vless://` خود کاربر است | تونلی که کاربر وارد کرده |
| تحلیل پروفایل، دانلود، و استفادهٔ عادی | `i.instagram.com` و بقیهٔ API خود اینستاگرام | خود برنامه با اینستاگرام حرف می‌زند، از جمله قابلیت‌هایی که دادهٔ حساب واردشده را می‌خوانند |

در این ساخت هیچ آمارگیری، تنظیم از راه دور، یا بررسی به‌روزرسانی وجود ندارد. درخواست فهرست انتشار گیت‌هاب، لینک حمایت مالی، بارگذاری تصویر آواتار، و سلول نمونهٔ Imgur اجرا نمی‌شوند.

### باینری‌های همراه

ساخت سایدلود، `RyukGram.dylib` و `RyukGram.bundle` بسته را برمی‌دارد. این‌ها را نگه می‌دارد چون خود اینستاگرام به آن‌ها تکیه دارد:

- `CydiaSubstrate.framework` برای عوض کردن متدها. کلاینت شبکه نیست.
- `libswiftIU.dylib` و `libmobile_first_frame_pipeline.framework` کتابخانه‌های خود اینستاگرام‌اند و برای باز شدن برنامه مانده‌اند.
- `zxPluginsInject` در پایهٔ ۴۳۶ مالک بوده است. این ساخت آن را اضافه نمی‌کند و کار شبکه‌ای تازه‌ای به آن نمی‌دهد.
- `IXRayCore.dylib` همان Xray است و فقط بعد از روشن کردن فیلترشکن با `dlopen` باز می‌شود. فرمان بارگذاری در باینری اصلی ندارد.
- `FLEX` ابزار اشکال‌زدایی است و تا وقتی کلید اشکال‌زدایی روشن نشود خاموش می‌ماند.

هیچ فیلد ورود یا رمز عبور قلاب نشده است. افزونه برای فرستادن نام کاربری، کوکی، یا توکن نشست به شخص سوم به کیف‌کلید دست نمی‌زند.

### قابلیت‌هایی که ممکن است حساب را به خطر بیندازند

این‌ها در برنامه مانده‌اند چون خود محصول‌اند. اینستاگرام می‌تواند به‌خاطرشان به حساب گیر بدهد:

- نرسیدن رسید بازدید استوری و دایرکت (حالت روح)
- مکان جعلی
- دانلود و آلبوم جدا در عکس‌ها
- تحلیل پروفایل، که از API اینستاگرام دادهٔ حساب را می‌خواند
- پنجره‌های تأیید خطر را کم نمی‌کنند؛ فقط قبل از کار می‌پرسند

### قاعدهٔ کرش

قلاب سوکت فقط بازنویسی اشاره‌گر در بخش داده است. `MSHookFunction` و وصلهٔ داخل دستور نیست. این قلاب‌ها فقط وقتی فیلترشکن روشن است نصب می‌شوند و `IXRayCore.dylib` از آن‌ها کنار گذاشته می‌شود تا تونل داخل خودش حلقه نزند.
