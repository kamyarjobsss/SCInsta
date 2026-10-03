# Instagram X

GPL-3.0. The feature set comes from the [RyukGram v1.3.2](https://github.com/faroukbmiled/RyukGram/tree/v1.3.2) sources by [faroukbmiled](https://github.com/faroukbmiled), which were published under GPL-3.0 and started from [SCInsta](https://github.com/SoCuul/SCInsta) by [SoCuul](https://github.com/SoCuul). Instagram X adds the holographic settings row, the in-app VLESS proxy, and launch safe mode. [Sparkle](https://github.com/efibalogh/sparkle-ig) (GPL-3.0, Instagram 448) overlaps this feature set; it was considered and not merged, so this tree stays one codebase.

`Version v2.0.0` | `Target Instagram 436.0.0` | `Upstream snapshot Instagram 434.0.0`

Sideload builds are full and lite IPAs. See [INSTALL.md](INSTALL.md). Socket hooks are data-pointer rebinds and run only while the VPN is on. The build does not use `MSHookFunction` or inline text patching. Xray is a separate `IXRayCore.dylib` with no load command.

FFmpegKit is not in the GPL tag and is not taken from the closed v1.4 bundle. `scripts/setup-ffmpegkit.sh` downloads the public ffmpeg-kit 6.0 iOS frameworks (about 60 MB) at package time. Media conversion stays off if that download fails. Corresponding source is the [ffmpeg-kit v6.0](https://github.com/arthenica/ffmpeg-kit) tree.

# Features
> Features marked with **\*** are new or improved in Instagram X

### General
- Hide ads
- Hide Meta AI
- Hide metrics (likes, comments, shares counts)
- Hide the TestFlight beta update popup
- Disable app haptics
- Copy description
- Copy comment text from long-press menu **\***
- Download / copy / expand GIF and image comments **\***
- Custom GIF in comments — long-press the GIF button to paste any Giphy link **\***
- Favorite GIFs — long-press a GIF in the picker to pin it to the top or download it **\***
- Download audio from the reels audio page **\***
- Profile copy button **\***
- Replace domain in shared links for embeds (Discord, Telegram, etc.) **\***
- Strip tracking params from shared links **\***
- Open links in external browser **\***
- Strip tracking from browser links **\***
- Do not save recent searches
- Open link from clipboard — long-press the search tab **\***
- Use detailed (native) color picker
- Enable liquid glass buttons
- Enable liquid glass surfaces **\***
- Force liquid glass off — for accounts that have it enabled by default
- Liquid glass tab bar — Fixed (never shrink) / Hide on scroll
- Force progressive blur (iOS 26) — keep the scroll-edge blur from fading out
- Enable teen app icons
- IG Notes:
  - Hide notes tray
  - Hide friends map
  - Enable note theming
  - Custom note themes
- Focus/Distractions
  - No suggested users
  - No suggested chats
  - Hide trending searches
  - Hide explore posts grid
  - Skip sensitive content covers **\***
- Live
  - Anonymous live viewing **\***
  - Toggle live comments **\***
- Privacy
  - Hide Instagram X UI on screenshots, screen recordings, and mirroring **\***

### Feed
- Hide stories tray
- Hide suggested stories **\***
- Hide story highlights **\***
- View profile picture from story tray long-press menu **\***
- Hide entire feed
- No suggested posts
- No suggested for you (accounts)
- No suggested reels
- No suggested threads posts
- Disable video autoplay
- Media zoom — long press media to expand in full-screen viewer **\***
- Start media muted — expanded videos open with sound off **\***
- Custom date format — feed, notes/comments/stories, and DMs; presets or build your own with placeholders (`{DD}/{MM}/{YYYY} {HH}:{mm}`), optional relative threshold, compact "1h" style, and a Combine with date picker (`Jan 5, 2026 (2h)` or `2h – Jan 5, 2026`) **\***
- Disable background refresh, home button refresh, and home button scroll **\***
- Disable reels tab button refresh **\***
- Hide repost button in feed **\***

### Reels
- Modify tap controls
- Auto-scroll reels mode **\***
- Always show progress scrubber
- Disable auto-unmuting reels **\***
- Confirm reel refresh
- Unlock password-locked reels **\***
- Hide reels header
- Hide repost button in reels **\***
- Hide friends avatars on the reels Friends tab **\***
- Hide social context overlay on reels (reposted/commented bubbles) **\***
- Hide "Made with Edits" / "Open in Edits" promo pills on reels **\***
- Hide reels blend button
- Swipe a reel left to open the author's profile
- Disable scrolling reels
- Prevent doom scrolling (limit maximum viewable reels)
- Enhanced Pause/Play mode (when Pause/Play tap control is set): **\***
  - Mute toggle auto-hidden
  - Audio forced on in reels tab
  - Play indicator hidden during playback
  - Playback toggle synced with overlay during hold/zoom
  - Optional tap-to-mute on photo reels

### Action buttons **\***
- Context-aware action menu on feed, reels, and stories **\***
- Configurable default tap action per context **\***
- Global icon picker — change the icon used across feed, stories, reels and DMs **\***
- Optional date header at the top of the action menu **\***
- Carousel and multi-story reel support with bulk download **\***
- Save photo posts with their music as a video — uses the exact track snippet the post plays (Photos or Gallery) **\***
- Repost via IG's native creation flow **\***
- Full-screen media viewer with zoom and swipe **\***
- Story playback pauses when menus are open **\***

### Profile **\***
- Zoom profile photo — long press to view full-screen **\***
- Save profile picture
- View highlight cover from profile long-press menu **\***
- Profile action button — copy info, view / share / save the profile picture (Photos or Gallery), follower info **\***
- Follow indicator — shows whether the user follows you (off / on / colored) **\***
- Copy note on long press **\***
- Fake profile stats — verified badge and follower/following/post counts **\***
- Show full follower / post count on profile headers **\***
- No suggested users — hides the suggested-accounts strip on profiles **\***
- Profile card details — view count, like count and upload date overlay on each post / reel card, with optional short-number format and on-demand fetch for missing counts **\***
- Filter, sort & search follower/following lists — reorder by mutuals, who follows you, verified or A–Z, filter to just those, search by name or username, plus load-more and jump to top/bottom **\***
- Follow Requests Tracker — logs follow requests you send (accepted / declined / cancelled) and receive (approved / ignored / withdrawn), catching who cancels a request before you answer; notifications, a searchable history split by direction with filters, sort and bulk actions, all on-device **\***

### Profile Analyzer (beta) **\***
- Follower and following scans with progress and cancel **\***
- Mutuals and non-followbacks lists **\***
- New and lost followers/following trackers across scans **\***
- Profile change history — username, name, bio, pfp **\***
- Searchable lists with inline and batch follow/unfollow, plus remove-follower on the non-followbacks list **\***
- Visited profiles tracker — log every profile you open with date / verified / private filters **\***
- Pull-to-refresh on the visited list re-syncs identity and pictures from IG **\***
- Enable or disable individual checks from a Checks screen — disabled ones are greyed out and skipped **\***
- Turning on snapshot recording archives your current scan right away instead of waiting for the next one **\***
- Opening a list flags what's new since you last viewed it — a NEW tag, new entries sorted to the top, and a New-only filter **\***

### Saving
- Enhanced HD downloads up to 1080p **\***
  - Quality picker with preview playback **\***
  - Audio-only and raw photo download options **\***
  - Fallback to 720p without FFmpegKit **\***
  - Live progress through both download and encode **\***
  - Encodes keep running when you leave the app — hardware hands off to a software encoder that keeps your quality settings **\***
- Download manager — parallel downloads with a configurable limit, one combined progress pill, and a live queue with cancel / retry / redownload, long-press share / save, and bulk select; opens from the pill, a home shortcut, or settings **\***
- Auto-retry dropped downloads — parks offline downloads and resumes them when the connection returns **\***
- Save to Instagram X album — every download + share-sheet "Save to Photos" routes into a dedicated album with a customizable name **\***
- Enhanced media resolution — IG's CDN ships higher-quality images **\***
- Advanced encoding panel — codec (HW / libx264), preset, tune, H.264 profile + level, CRF / bitrate, pixel format, max resolution, frame rate, audio codec / bitrate / channels / sample rate, faststart, strip metadata **\***
- Download confirmation dialog **\***
- Output filenames formatted as `@username_context_timestamp` across every save surface (feed / reels / DMs / notes / comments / disappearing media) **\***
- Legacy long-press gesture (deprecated, customizable finger count + hold time) **\***

### Gallery **\***
- On-device gallery — every download can mirror into an in-app library **\***
- Stores images, videos, audio (m4a/aac/mp3/ogg/opus/...) and animated GIFs **\***
- Filter chips by type, source (feed / reels / stories / DMs / profile / notes / comments) and uploader; favorites; folders **\***
- Group by user — sections or virtual folders alongside your real folders; filters apply inside folders **\***
- Folder cells show a thumbnail collage + item count and last-activity date **\***
- In-app preview carousel — image / video / audio scrubber / GIF playback **\***
- Audio + GIF picker — DM Upload Audio and (in future surfaces) Comment GIF can pull straight from the gallery **\***
- "Download to Gallery" submenu on every download surface when the gallery is enabled, with Photos / Gallery / Share options for audio **\***

### Stories and messages
- Keep deleted messages **\***
- Deleted messages log — dedicated UI for every unsent message type, including disappearing (view-once) media, grouped by chat (group chats show who unsent each), optional removed-reaction logging, unread count per chat, search, filter (incl. disappearing-only), per-chat exclude list, bulk Save / Share / Delete, edit history per message **\***
- Read receipts — notifies and optionally logs when someone reads a message you sent (tap the notification to open the log), grouped by chat (group chats show each reader) with profile photos, an unread count per chat, username/date search & sort, a per-person/chat ignore list, group-chat support, and a notifications-only mode **\***
- Keep app active in the background to catch unsends while you're away — optional, off by default (may use more battery)
- Hide trailing action buttons on preserved messages
- Warn before pull-to-refresh clears preserved messages **\***
- Manually mark messages as seen (button or toggle mode) **\***
- Long-press the seen button for quick actions **\***
- Auto mark seen on send **\***
- Auto mark seen on typing **\***
- Mark seen on story like **\***
- Mark seen on story reply **\***
- Advance to next story when marking as seen **\***
- Advance on story like **\***
- Advance on story reply **\***
- Per-chat read-receipt exclusion list with Block all / Block selected mode **\***
- Send audio as file — DM plus menu, or long-press the camera button while replying **\***
- Download voice messages **\***
- Disable typing status
- Disable vanish mode swipe **\***
- Hide voice/video call buttons (independent toggles) **\***
- Hide send to group chat in the share sheet **\***
- Bypass DM character limit **\***
- Bypass "You can't send messages" — removes the blocked-composer banner and restores the text input in restricted threads **\***
- Pin recipients on long-press in the share sheet — pinned chats render at the top **\***
- Custom chat backgrounds — per-chat images injected into IG's native theme picker, library upload with built-in cropper, per-image opacity / blur / dim, auto bubble color across text, replies and voice notes (tint the other person's bubbles, yours, or both — solid or gradient (vertical, horizontal, or diagonal) with readable or custom text color, works with animated themes, editable from the in-chat picker), optional global default, per-account list of chats with backgrounds **\***
- Unlimited replay of direct stories **\***
- Full last active date **\***
- Send files in DMs (experimental) **\***
- Hold the DM tab button to open the on-device gallery **\***
- Notes actions — copy text, download GIF / audio (Photos or Gallery) **\***
- Copy note text on long press **\***
- Disable view-once limitations
- Disable screenshot detection
- Disable story seen receipt **\***
- Keep stories visually seen locally **\***
- Manual mark story as seen (button or toggle mode) **\***
- Long-press the story seen button for quick actions **\***
- Per-user story seen-receipt exclusion list with Block all / Block selected mode **\***
- Filter, sort, search & pin your story viewers list — reorder by mutuals, who follows you, verified, who liked, or A–Z; search by name or username; sticky settings; long-press to pin (pinned viewers stay on top, addable by username even before they view) **\***
- Story audio mute/unmute toggle **\***
- View story mentions, with optional quick-access overlay button and count badge **\***
- Hide stories midcards (Trending / Music) **\***
- Stop story auto-advance **\***
- Reveal poll/slider vote counts and quiz answers on stories and reels before interacting **\***
- Force legacy Quiz and Reveal stickers back into the story composer tray **\***
- Bypass Reveal sticker — view stories blurred behind a Reveal sticker without DMing the author **\***
- Allow video in photo sticker — story photo sticker picker accepts videos too **\***
- Custom sticker colors — pick any solid or gradient color from the color wheel in sticker editors (music, lyrics, slider, question, prompt and more) **\***
- Disappearing DM media overlay — action button, mark-as-viewed eye (optionally advancing to the next stacked message), and audio toggle **\***
- Download disappearing DM media in full quality — videos go through the HD quality picker **\***
- Reroute the native DM Save button — turn Instagram's built-in Save on DM photos & videos into Photos / Gallery / Share / Expand, configurable through the standard action-menu config **\***
- Upload audio as voice message with built-in trim editor **\***
- Send Instants from your photo album — gallery button on the Instants camera with a built-in square cropper, posts through IG's native capture flow; pick from the in-app gallery or Photos library when the gallery is enabled
- Allow screenshots on Instants — bypasses the screenshot/screen-record block, scoped to the Instants viewer only
- Instants action button — Expand / Save (Photos / Gallery) / Share / Save all, fully configurable through the standard action-menu config
- Auto-save Instants — every Instant you view (including while swiping) saves to Photos or the Gallery automatically, each one only once
- Auto advance after reaction — moves to the next Instant after you like or react **\***
- Confirm Instants emoji reaction — optional confirmation before a quick-reaction sends
- Confirm Instants capture + Confirm switching Instant
- Save to Photos / Gallery from the expanded media viewer — share button surfaces a save / share menu, with username / source attribution carried through

### Interface **\***
- Tab bar shortcuts — Home shortcut button + Action button icon picker, grouped at the top of the page
- Notifications — universal in-app pill (Minimal / Colorful / Glow / Island), per-action routing (custom pill / IG-native / off), top or bottom position, master kill switch, swipe-to-dismiss, multi-pill stacking
- Background mirroring — toasts that fire while Instagram is in the background are delivered to the iOS notification centre instead; tapping one opens the same thing as tapping the toast, with per-action overrides and auto-clear when the app opens
- Burst summaries — a flood of the same toast (unsent messages, removed reactions, seen marks) collapses into one summary pill instead of stacking, while a single action still toasts instantly
- Custom tab bar icon order — drag to reorder any tab, toggle tabs off to hide them (feed / explore / create / reels / messages / profile) **\***
- Modify swiping between tabs
- Messages-only mode — inbox, search & profile only, launch straight into inbox **\***
  - Hide search tab sub-toggle — drop search too, leaving just inbox & profile **\***
  - Hide tab bar sub-toggle — floating settings gear replaces it **\***
- Launch tab — pick which tab the app opens to **\***
- Home shortcut button — extra button on the home top bar with a configurable multi-action menu (Gallery / Settings / Security & Privacy / Hidden chats / Locked chats / Profile Analyzer / Deleted messages / Read receipts / Follow Requests / Fake location / Clear cache / Changelog) **\***
- Experimental flags

### Confirm actions
- Confirm like: Posts/Stories
- Confirm story emoji reaction **\***
- Confirm note like + emoji reaction **\***
- Confirm like: Reels
- Confirm follow
- Confirm unfollow **\***
- Confirm repost
- Confirm voice call **\***
- Confirm video call **\***
- Confirm voice messages
- Confirm follow requests
- Confirm vanish mode
- Confirm posting comment
- Confirm send to group chat **\***
- Confirm changing direct message theme
- Confirm sticker interaction (stories / highlights, per-surface: disabled / all / reaction stickers only) **\***

### Fake location **\***
- Override location app-wide for any IG feature reading coordinates
- MapKit picker with search + reverse-geocoded names
- Saved presets
- Quick toggle button on the Friends Map

### Theme **\***
- Theme picker — Off / Light / Dark / OLED, with optional Force theme to override the iOS appearance
- OLED chat theme — pure black DM thread and incoming bubbles
- Keyboard theme — dark or OLED, sticks through search keyboard activations
- The theme applies to Instagram only — Instagram X's own menus keep the stock iOS appearance
- Apply & restart, plus Reset theme to revert every theme option

### Security & Privacy **\***
- Device ID — change the device identity Instagram reports: masks the device ID and family device ID it sends, with a login-screen button and a Device ID menu in Settings → Advanced to roll a new fingerprint, set a custom ID, revert to your real one, or fully clear the device and relaunch fresh **\***
- Passcode + biometric lock — gates tweak settings, gallery, deleted-messages log, Profile Analyzer, DM inbox, individual chats, and Instagram itself
- Per-target idle timeout, re-lock on background, lock every time, independent session
- Hidden chats — long-press a DM to hide it; managed under S&P
- Per-account lists (excluded chats, hidden chats, locked chats, share-sheet pins) — switching IG accounts shows that account's own data
- Locked, hidden, and excluded chat lists show real profile pictures, including group chat photos
- App-switcher snapshot shroud — covers IG content when a locked surface is visible
- Hide message preview for locked chats in the inbox

### Tweak settings **\***
- Search bar with breadcrumbs across nested pages
- What's new indicator — a dot marks newly added settings and clears once viewed **\***
- Pause playback when opening settings **\***
- Quick-access via long-press on feed tab **\***
- Native Instagram icons throughout settings and in-app menus **\***
- Disable all tweak options — one switch turns every feature off so Instagram runs stock; your settings are kept and restored when you turn it back off **\***

### Advanced experimental features **\***
- Toggle hidden Instagram experiments: QuickSnap (Instants), Direct Notes reply types, Friend Map, Homecoming, Prism
- Batched changes with an Apply & restart button
- Auto-reset after 3 consecutive launch crashes

### Backup & Restore **\***
- Export any combination of settings, per-account filters, hidden & locked chats, Profile Analyzer, gallery, chat backgrounds, deleted messages and the read receipts log — settings stay plain JSON, bundles with media export as a compressed `.ryukbak`
- Import as Replace or Merge — Merge folds the backup into your existing data, combining duplicates (galleries included)
- Preview each section before saving or applying
- Reset selected data

### Localization **\***
- Multi-language UI with fallback to English **\***
- Built-in language picker in Settings **\***
- Currently shipping: **English**, **Spanish**, **Russian**, **Korean**, **Arabic**, **Chinese (Traditional)**, **Chinese (Simplified)**, **Portuguese (Brazil)**, **Turkish**

### Optimization
- Clear Instagram cache on demand with optional auto-clear interval, with a toggle to preserve DMs, drafts, and Notes **\***

# Translating Instagram X
Want to see Instagram X in your language? Two ways:

### Option A: In-app (fastest)
1. Open **Settings → Debug → Localization → Export strings** — pick a language (English for a fresh start, or an existing one to fix) and share its `.strings` file to yourself.
2. Translate the **right-hand side** of every `"key" = "value";` line. Never touch the left-hand side.
3. Go to **Debug → Localization → Update → + Add new language** — enter your language code (e.g. `fr`), pick the translated file, restart.
4. Your language now appears in the globe menu. Test it, tweak it, re-import as needed.
5. When ready, open a pull request with the file at `src/Localization/Resources/<code>.lproj/Localizable.strings`.

### Option B: PR directly
1. Copy `src/Localization/Resources/en.lproj/Localizable.strings` into a new folder: `<code>.lproj/Localizable.strings`
2. Translate the right-hand side of every line.
3. Keep format specifiers (`%@`, `%lu`, `%d`, `%1$@`…) exactly as-is. Use positional specifiers if your language needs different word order.
4. Keep section banners and structure — makes the diff easy to review.
5. Open a PR at <https://github.com/faroukbmiled/RyukGram/pulls>. Title it e.g. `l10n: Add French translation`.

Partial translations are welcome — untranslated keys fall back to English at runtime.

If you find a string that still renders in English on a translated build, open an issue with a screenshot.

## Known Issues
- Preserved unsent messages cannot be removed using "Delete for you". Pull to refresh in the DMs tab clears the active account's preserved messages (with optional confirmation if "Warn before clearing on refresh" is enabled).
- "Delete for you" detection uses a ~2 second window after the local action. If a real other-party unsend happens to land in the same window, it may not be preserved. Rare in practice and limited to that specific overlap.
- With Liquid Glass buttons + Hide UI on capture both on, the DM eye leaves an empty glass bubble in captures — IG draws that backdrop, not the tweak, so it's outside our redaction.

# Opening Tweak Settings

|                                             |                                             |
|:-------------------------------------------:|:-------------------------------------------:|
| <img src="https://i.imgur.com/uPMcugZ.png"> | <img src="https://i.imgur.com/RUlsg4k.jpeg"> |

# Building from source
### Prerequisites
- XCode + Command-Line Developer Tools
- [Homebrew](https://brew.sh/#install)
- [CMake](https://formulae.brew.sh/formula/cmake#default) (`brew install cmake`)
- [Theos](https://theos.dev/docs/installation)
- [cyan](https://github.com/asdfzxcvbn/pyzule-rw?tab=readme-ov-file#install-instructions) **\*only required for sideloading**
- [ipapatch](https://github.com/asdfzxcvbn/ipapatch/releases/latest) **\*only required for sideloading**

### Setup
1. Install iOS 16.2 frameworks for theos
   1. [Click to download iOS SDKs](https://github.com/xybp888/iOS-SDKs/archive/refs/heads/master.zip)
   2. Unzip, then copy the `iPhoneOS16.2.sdk` folder into `~/theos/sdks`
2. Clone repo: `git clone --recurse-submodules https://github.com/faroukbmiled/RyukGram`
3. **For sideloading**: Download a decrypted Instagram IPA from a trusted source, making sure to rename it to `com.burbn.instagram.ipa`.
   Then create a folder called `packages` inside of the project folder, and move the Instagram IPA file into it.

### Run build script
```sh
$ chmod +x build.sh
$ ./build.sh <sideload/sidestore/rootless/rootful>
```

# Credits
- [SCInsta](https://github.com/SoCuul/SCInsta) by [@SoCuul](https://github.com/SoCuul) — original tweak this fork is based on
- [@BandarHL](https://github.com/BandarHL) — creator of the original BHInstagram project
- [Instaoled](https://t.me/ciesIPAs) by @VAXMG — OLED theme inspiration
- [@euoradan](https://t.me/euoradan) (Radan) — experimental Instagram feature flag research
- [@Mikasa-san](https://github.com/Mikasa-san) — code contributions
- [@n3d1117](https://github.com/n3d1117) (Edoardo) — Following feed mode (ported from [InstaSane](https://github.com/n3d1117/InstaSane))
- [@erupts0](https://github.com/erupts0) (John) — testing and feature suggestions
- [BillyCurtis/OpenInstagramSafariExtension](https://github.com/BillyCurtis/OpenInstagramSafariExtension) — base for the bundled Safari extension
- [@asdfzxcvbn](https://github.com/asdfzxcvbn) — [ipapatch](https://github.com/asdfzxcvbn/ipapatch) and [zxPluginsInject](https://github.com/asdfzxcvbn/zxPluginsInject)
- Furamako — Spanish translation
- [@ch1tmdgus](https://github.com/ch1tmdgus) (N4C) — Korean translation
- [ZomkaDEV](https://github.com/ZomkaDEV) — Russian translation
- [@bruuhim](https://github.com/bruuhim) — Arabic translation
- [@jaydenjcpy](https://github.com/jaydenjcpy) — Chinese (Traditional and Simplified) translation
- Bruno ([@brunorainha](https://github.com/brunorainha)) — Portuguese (Brazil) translation
- [@yesnt10](https://github.com/yesnt10) — Turkish translation

# Support

Instagram X is free and open source. If you'd like to support development:

- [☕ Donate to Ryuk (Instagram X)](https://buymeacoffee.com/axryuk)
- [☕ Donate to SoCuul (original SCInsta)](https://ko-fi.com/SoCuul) — Instagram X wouldn't exist without SoCuul's original SCInsta, so showing them some love is always welcome
