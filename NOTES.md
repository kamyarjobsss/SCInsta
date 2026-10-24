[release] RyukGram v1.3.2

### ✨ Highlights
- **Follow Requests Tracker** — logs the follow requests you send and receive, fully on-device, and catches who cancels a request to follow you before you ever answer.
- **Read receipts** — get notified (and optionally keep a searchable log) when someone reads a message you sent, grouped per chat with unread counts.
- **Device ID** — mask the device identity Instagram reports, roll a fresh fingerprint, set a custom one, or fully clear the device and relaunch.
- **Story viewers list** — filter, sort, search and pin who viewed your story, by mutuals / followers / verified / who liked / A–Z.
- **Deleted-messages log overhaul** — now groups by chat and captures removed reactions and disappearing (view-once) media, not just text.
- **Auto-coloured chat bubbles** — custom chat backgrounds can tint message bubbles solid or gradient, with auto-contrast text.
- **Customizable tab bar** — drag to reorder any tab and toggle tabs off, replacing the old fixed presets.

### 🆕 New features

#### Profile & Profile Analyzer
- Follow Requests Tracker — logs follow requests you send (accepted / declined / cancelled) and receive (approved / ignored / withdrawn), catching who cancels a request to follow you before you answer; notifications that open the list, a searchable history split by direction with filters, sort and bulk actions, plus a home-shortcut entry — all on-device
- Search followers and following lists by name or username, from the filter & sort sheet
- Hide suggested users on profiles — removes the suggested-accounts strip shown under a profile
- Profile Analyzer scans keep running after you leave the view — a progress pill lets you track or cancel from anywhere
- Profile Analyzer can remove people who follow you but you don't follow back, straight from the list — per-row or in batch
- Profile Analyzer — turn individual checks on or off from a new Checks screen; disabled ones are greyed out and no longer calculated or shown
- Profile Analyzer — turning on snapshot recording now saves your current scan right away instead of waiting for the next one
- Profile Analyzer — opening a list now flags entries new since you last looked: a NEW tag, they sort to the top, and a "New only" filter

#### Messages & DMs
- Read receipts — get notified, and optionally keep a log, when someone reads a message you sent; grouped by chat with profile photos, an unread count per chat that clears when you open it, username/date search and sort, a per-person/chat ignore list, group-chat support, and a notifications-only mode (off by default); tapping the notification opens the log; backs up via Backup & Restore (opt-in, under Feature data)
- Custom chat backgrounds can auto-color message bubbles (text, replies and voice notes) — the other person's, yours, or both, solid or gradient (vertical, horizontal, or diagonal), with custom or auto-contrast text; works with animated themes and shows through the composer; editable from the in-chat picker with live updates
- Deleted-messages log now groups by chat — group-chat unsends appear under the group, each tagged with who unsent it
- Deleted-messages log can optionally record removed reactions — the emoji, who removed it, and which message it was on
- Deleted-messages log now captures disappearing (view-once) media — saved when you open it, when it's unsent, or when you reopen the chat, and states clearly when it couldn't be recovered
- Filter the deleted-messages log to disappearing media only
- Exclude chats from the deleted-messages log — long-press one to stop logging it, with an ignored list to manage and undo
- Optional background keep-alive for the deleted-messages log — catches unsends while you're away, off by default (may use more battery)
- Hide the DM and story seen buttons while keeping receipt blocking on, with an optional confirmation before any mark-as-seen action
- Disappearing media can advance to the next stacked message when you mark it as viewed
- Reroute Instagram's built-in Save button on DM photos & videos to Photos, the gallery, share, or expand in-app — with the HD quality picker for videos; configurable like the other action menus (reorder, enable/disable, default tap), off by default
- Favorite GIFs — long-press a GIF in the picker (comments and DMs) to pin it to the top with a star badge or download it; GIF comments can be favorited from their long-press menu
- Bypass "You can't send messages" — removes the blocked-composer banner and restores the text input in restricted threads (Messages → Advanced)

#### Stories & Notes
- Filter, sort, search and pin your story viewers list — reorder by mutuals, who follows you, verified, who liked, or A–Z; search by name or username; settings stick; long-press to pin viewers on top (pin by username even before they view your story)
- Custom sticker colors — the color-wheel long-press now works on every sticker editor (slider, fundraiser, prompt and more), not just music
- Hide story highlights — removes the resurfaced highlights row from the feed stories tray

#### Reels & Instants
- Instants can auto-advance to the next one after you like or react
- Auto-save instants — pick Photos or the RyukGram gallery and every instant you view (including while swiping) saves automatically, each one only once

#### Downloads & media saving
- Save photo posts with their music — new feed action menu entries combine the photo with the exact track snippet the post plays and save it as a video to Photos or the Gallery
- Save straight to Photos from the profile action button and the expanded media viewer, alongside the existing Gallery and share options

#### Notifications
- Mirror toasts to iOS notifications — toasts that fire while Instagram is in the background are delivered to the notification centre instead so they aren't missed; tapping one opens the same thing as tapping the toast, with per-action overrides and auto-clear when the app opens
- Bursts of toasts no longer pile up — opening the app to many unsent messages, removed reactions or seen marks shows one summary pill (e.g. "15 messages unsent") instead of a stack, while a single action still toasts instantly

#### Interface, navigation & theming
- Tab bar icon order is now fully customizable — drag to reorder any tab and toggle tabs off (including profile), replacing the old fixed presets; the hide-tab switches moved into the new Icon order screen
- Reordering rows in settings (action menus, home shortcut) is more reliable — native drag handles, no more failed drops
- Messages-only mode keeps the search tab, with a toggle to hide it, and trims its explore grid and trending searches
- Force progressive blur (iOS 26) — keeps the scroll-edge blur visible instead of letting it fade out
- Custom date formats — build your own with placeholders like `{DD}/{MM}/{YYYY} {HH}:{mm}`, live preview and tap-to-insert tokens; save as many as you like and switch between them, plus a new `dd/MM/yyyy` 24-hour preset
- Force liquid glass off — disables liquid glass for accounts that have it enabled by default

#### Privacy & Advanced
- Device ID — change the device identity Instagram reports: masks the device ID and family device ID it sends, with a button on the login screen and a Device ID menu in Settings → Advanced to roll a new fingerprint, set a custom ID, revert to your real one, or fully clear the device (logins, cookies, stored IDs) and relaunch fresh
- Disable all tweak options (Advanced → Instagram) — turns every feature off so Instagram behaves stock; your settings are kept and restored when you turn it back off
- File logging (Settings → Debug) — records RyukGram's own activity across the app and its extensions to one shareable log file for troubleshooting, off by default

#### Backup & data
- Importing a backup can now merge into your existing data instead of replacing it — pick Replace or Merge on the import page; duplicates are combined, including merging galleries together

### 🛠 Fixes
- Profile action button now shows on every profile layout (some accounts were missing it on other people's profiles), no longer crashes when tapped, and long-press opens its menu again
- Disappearing media now downloads in full quality — videos use the HD quality picker (with audio) instead of the low-bitrate version
- Story overlay buttons no longer crash, freeze, disappear, or jump to the corner when swiping between stories — across action-button / mentions / seen combos (including mentions-only on iPad landscape)
- Notification pills no longer re-open their view when tapped while you're already inside it
- Home shortcut updates without a restart and now shows on accounts that don't have the create button
- Instants download button stays put when Instagram hides its toolbar anchors
- Instants gallery button matches the native camera controls and glides with the capture animation
- Instants saved to gallery group under the username instead of the timestamp
- Sending Instants from your photo album handles HDR / wide-gamut photos on every device
- Video in photo sticker picker works again on Instagram 431+
- Do not save recent searches works again on Instagram 431 — search bars and the DM recipient picker stop saving
- Confirm note like also catches double-tapping a note in the inbox tray or on a profile
- Keep deleted messages survives huge unsend bursts and cache evictions, and no longer blocks Instagram's own unsend in chat
- Unsent-message toast names who unsent again instead of the generic message, even for messages received before the last app restart
- Voice notes and audio shares in the deleted-messages log save as Audio with the right file extension instead of generic Share/Link
- Deleted-messages log unread count badge now sits beside the time instead of misaligned under it
- Doom-scrolling Reels limit starts from the reel you tapped instead of the top of the feed
- OLED mode now blacks out more dark surfaces in comments, DMs, profiles and the deleted-messages log, while keeping buttons, search fields and Notes readable
- Reels force-audio finds the right audio cell when Instagram nests it differently
- Reels no longer black-screen on play in pause/play mode; silent reels are detected without flashing the "no sound" toast
- Settings search now reaches options inside nested pages like Security & Privacy and the passcode screen
- Skip sensitive content covers now reveal in any app language and work on feed posts, not just reels
- Launch tab and messages-only reliably open the chosen tab instead of sometimes landing on feed or reels
- Gallery save mode now applies to HD videos and bulk carousel saves, not just single photos
- HD downloads no longer freeze when you leave the app mid-encode — encoding continues in the background with your quality settings, switching to a software encoder when needed
- Notification action names in Settings, the read receipts footer, quality-picker sizes and several other strings now translate properly instead of always showing in English
- Hold-for-settings shortcut on the profile button works again on Instagram 432
- Profile action button works again on Instagram 432 and no longer disappears when you open its menu
- Profile action button no longer overlaps Instagram's own nav buttons (notify bell, follow, more) on profiles that show them
- Auto mark seen on send no longer fires a read receipt when you forward or share a post into a chat, including to multiple people
- Auto mark seen on send now also covers reel quick-reactions, voice notes and media, and still marks if you leave the chat before media finishes uploading
- Confirm calls and hide call buttons now work on the new single call button that opens an audio/video menu (some accounts)
- Confirm calls no longer asks twice on accounts with the old call-button layout
- Confirm note reactions works again on Instagram 431
- Hide "Made with Edits" and "Use template" work again on Instagram 431
- Reels swipe-to-profile opens the right reel on newer Instagram versions and no longer hijacks carousel swipes
- Note theming and custom note buttons work as independent toggles again
- Instagram-native style notifications appear above tweak popups instead of behind them
- Hide UI on Capture now also redacts the home shortcut, follow indicator, follow-list filter button, notes editor buttons, revealed sticker results, story mentions counter, Instants gallery / chat background / password-locked-reels buttons, profile-card view/like/date overlays, and the Unsent tag on kept deleted messages — previously these stayed visible in screenshots
- Long-press download works again on carousel posts on Instagram 432 — saves the right photo or video from feed and Reels carousels
- Hide Meta AI works again on Instagram 432 — search, the DM inbox AI button, the summarize pill, and AI fonts
- Hide suggested users (search and profiles) and hide suggested chats work again on Instagram 432
- Copy note text on long-press, OLED chat backgrounds, DM screenshot blocking, carousel photo zoom, and the detailed color picker work again on Instagram 432
- Hiding the stories tray now also removes the mid-feed and expiring-soon stories carousels
- Detailed color picker, hiding the explore search bar, and slider sticker reveal work again on Instagram 433
- Quiz sticker reveal no longer highlights the first option when Instagram sends no answer data
- Confirm switching Instants and auto-advance after a reaction work again on Instagram 433
- Profile card likes and dates load again on the reels and reposts tabs on Instagram 433
- Hide stories tray, story-tray filter, keep-deleted Unsent marker, feed filtering, chat backgrounds and hide call buttons all work again on Instagram 434
- Custom GIF in comments works again on Instagram 432+
- Download quality sheet no longer randomly skips to standard quality on some reels and reposts
- Gallery filters now work inside grouped folders — only folders with matches show, counts and previews reflect the filter, and it carries into the folder you open
- The tweak's story menu options (exclude story seen, mute audio, view mentions) now also appear in Instagram's redesigned story menu — the new bottom sheet some accounts get — matching its native grouped style, with the same items as the classic 3-dot menu
- Profile Analyzer “You unfollowed” list now shows your real follow state — people you re-followed get an Unfollow button instead of always showing Follow
- Settings search bar no longer shows a grey box over the native glass on accounts that have liquid glass enabled by default

### 🔄 Changes
- RyukGram's own menus now keep the stock iOS appearance — the theme only applies to Instagram
- Profile settings toggles that lacked a description now have one
- Deleted-messages log chat list restyled to match the read receipts log, with the search bar kept at the top on iOS 26
- Follow indicator redesigned — cleaner pill look and faster cached follow statuses
- Removed the Disable instants creation toggle — Instagram has its own option to hide Instants
- Removed the Auto-scroll reels toggle — Instagram now has this natively
- Locked, hidden, and excluded chat lists now show real profile pictures, including group chat photos
- Fixed Hide trending searches not working on newer Instagram versions
- Fixed hide call buttons, hide stories tray, custom chat backgrounds and the keep-deleted unsent marker not working on newer Instagram versions
