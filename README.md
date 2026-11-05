# Echo99

Public Flutter card tables for Echo99. Firestore project `echo99-9e73b`. There are no room codes.

The home screen has three actions: إنشاء طاولة، الانضمام إلى طاولة، and الإعدادات. A table shows خيارات الطاولة, one points line, the hand, and السجل.

## Accessibility (TableEx method)

VoiceOver / TalkBack users: focus the table, then open the **Actions** rotor (VoiceOver) or custom actions menu (TalkBack). **All games** share the same four actions:

1. إعلان الدور — whose turn (UP)
2. حالة اللوحة — board / pieces / positions (DOWN)
3. آخر ورقة أو حركة — last card or move (LEFT)
4. فتح السجل أو الدردشة — open log / chat (RIGHT)

PC keyboard shortcuts are **not** used. Map BlindGamers gestures to VoiceOver/TalkBack: universal four actions above; Miles also «سحب ورقة» / «حالة سيارتي»; Ludo «أماكن القطع». Card play = onTap; Miles discard = long-press. Mic: only on the mic pad — tap or Semantics action toggles; swipe up = ON, swipe down = OFF (screen-recording friendly while mic is off).

Settings: «استخدام الناطق الداخلي» defaults **OFF** (Semantics / TalkBack / VoiceOver only). «تسمية البطاقات» uses English suit/rank with Eastern Arabic digits (e.g. «٥ of Clubs», «Jack of Spades»).

## Game math

Hitting or crossing 33/66 does **not** reset the pile — the score keeps accumulating (33+10=43). Exact 33/66 → short point sound only. Exact 99 → win end sounds (metal/applause path). Exceed 99 → loss end (glass/laughter) + penalties. Host **always** first turn after every deal. Table settings (max points, timer) appear **only** as a dialog when the host taps بدء; after confirm everyone hears «إعدادات الطاولة — أقصى نقاط: X، مؤقت الدور: Y».

## Ghost tables (Firestore)

Firestore has no `onDisconnect().removeValue`. When the **host** leaves, closes, or detaches (`AppLifecycle`), the client **deletes** the table document and its `log` subcollection. Guests leaving remove themselves only. On resume, if the table is gone, players are kicked to the menu.

## Voice (LiveKit Twitter Spaces model)

Join a table as Listener (mic OFF). Toggle mic via swipe / long-press. Zip sounds play for voice join/leave and mic off.

## Connecting audio

Signed-in (non-guest) users hear the ~30s connecting MP3 (`بداية التشغيل` → `ambient.mp3`) every time they enter connecting-to-server (launch or resume). Success plays `connected.mp3` («صوت تأكيد الاتصال السيرفر»). Guests stay silent.

## Realtime Database (live)

* The RTDB instance now exists at `https://echo99-9e73b-default-rtdb.firebaseio.com` (already wired in `lib/firebase_options.dart`, `lib/services/presence.dart`, `google-services.json`, `GoogleService-Info.plist`).
* Rules live in `database.rules.json` (`firebase.json` + `.firebaserc` → project `echo99-9e73b`): everything locked except signed-in access to `status/{uid}` (list readable, own entry writable), `hosting/{uid}` (own only), `tables/{id}` (read; own `seats/{uid}`; `host` may only be set to your own uid; whole-table delete allowed for the cascade cleanup).
* Publish with `firebase deploy --only database`, or paste `docs/rtdb-rules-paste.txt` into Console → Realtime Database → Rules → Publish. Presence `onDisconnect()` cleanup is live once the rules are published.

## 1.2.0 — BlindGamers Miles & Ludo + server mute

* **ألف ميل:** 121-card deck; draw-then-play/discard; exact 1000; max two 200s; speed limit 25/50 only; counterflow subtracts miles; coup fourré window until next draw/play; safeties never reshuffled; round bonuses (arrive / delayed / shutout / no-200s); match score limit 1000–500000 (default 5000); teams 4/6/8/9 (7 invalid); miles vs points separate.
* **Miles a11y:** tap = play, long-press = discard; customSemanticsActions «سحب ورقة»، «حالة سيارتي»، «النقاط والأوراق» plus the universal four.
* **Ludo:** normal/free; first 6 picks color then auto-assign; safe squares (normal); opposite-only capture in normal / all in free; same-color stack immune in free; exact home; triple-6 ends turn; extra on 6; fast (2 pieces); mandatory kill (wrap, no stop on 0/26, home stretch locked until a capture); free bases R0 B13 G26 Y39.
* **Ludo a11y:** customSemanticsAction «أماكن القطع» announces every piece with «المنطقة الآمنة» on safe squares; dice/move onTap; playTicks 200 ms dice / 250 ms steps.
* **Server authority:** deals/dice/legal moves via Firestore transactions; host mute → `players[].micMuted` (legacy `board.mutedMics`); host block chat → `players[].chatBlocked` (send path rejects); LiveKit local unmute blocked + remote track `disable()` for muted identity.
* Version **1.2.0+12**; package `com.echo99.echo99`; author Ali Hussein Al-Marfadi <www.ali444555@gmail.com>.

## 1.1.0 — multi-game overhaul

* **Five games** in the create picker: Echo99, Jackaroo, Snakes and Ladders, Ludo, ألف ميل (Thousand Miles).
* **Accessibility:** one set of four custom Semantics actions for every game; card/piece play is tap-only; result banner Semantics fixed for Android; mic is never dimmed when clickable; mic lives only on the mic pad.
* **Jackaroo Complex:** mode label is «الكومبلكس» (not معقد). Card 10 sets `isForcedToBurn` — every hand card reads «حرق [English name]», tap burns only (`jk_burn_cards`), then the turn passes.
* **Sequential audio:** `SoundBoard.playTicks` — Jackaroo steps alternate `jk_step1`/`jk_step2` (250 ms); capture replaces the final tick; Snakes/Ludo dice use 200 ms gaps.
* **Ludo + Thousand Miles:** playable engines + assets under `assets/sounds/ludo/` and `assets/sounds/miles/`; host settings on بدء (free/safe/teams/fast/mandatoryKill; score limit / stack hazards / reshuffle).
* **Host controls** on player name: mute mic, block chat, kick, replace with bot (bot join plays `join`).
* **Background / PiP:** keep FGS; iOS `UIBackgroundModes` audio+fetch+processing+voip; Android `supportsPictureInPicture`; LiveKit stays connected on pause/inactive.
* **Social:** Accept/Decline friend requests, join invite → tableId, DM sound for recipient only.
* Echo99: 33/66 never reset the pile (life/sound only); exact 99 wins, over 99 busts.
* Version **1.1.0+11**; obfuscated release APK.

## 1.0.9 — Realtime Database go-live

* **Realtime Database is live** at `https://echo99-9e73b-default-rtdb.firebaseio.com` (project `echo99-9e73b`). The same URL is in `lib/firebase_options.dart`, `lib/services/presence.dart`, `google-services.json`, and `GoogleService-Info.plist`.
* **Presence with `onDisconnect()`:** the app registers `onDisconnect().remove()` on `status/{uid}`, `tables/{id}/seats/{uid}`, `tables/{id}/host`, and `hosting/{uid}`. It registers again on every reconnect (`.info/connected`). When a phone loses its connection, the server removes these entries by itself.
* **Rules file in the repo:** `database.rules.json` (deploy with `firebase deploy --only database`) and `docs/rtdb-rules-paste.txt` (paste into Console → Realtime Database → Rules → Publish).
* **Ghost cleanup:** after the rules are published in the Console, ghost tables are cleaned: a dropped player shows «Reconnecting...» for 60 s and then a bot takes the seat; if the host drops, guests wait 60 s and then the table is deleted.
* No game logic changes in this version.

## 1.0.8 — snakes board + RTDB URL

* Snakes and Ladders board set to the user coordinates (ladders 4→14, 9→31, 20→38, 28→84, 40→59, 51→67, 63→81, 71→91; snakes 17→7, 54→34, 62→19, 64→60, 87→24, 93→73, 95→75, 98→79).
* `databaseURL` / `firebase_url` / `DATABASE_URL` wired for Android, iOS, and web so RTDB presence resolves once the instance exists.

## 1.0.7 — games, presence, background

* **Create instantly:** «إنشاء طاولة» → pick **Echo99 | Jackaroo | Snakes and Ladders**; the table is named «طاولة <host>» with no settings screen. Settings appear only as a dialog when the host taps **بدء** (Echo99: max points + timer; Jackaroo: standard/complex + timer; Snakes: timer) and every client hears «إعدادات الطاولة — …».
* **Quick menu** on the home screen: الإعدادات · المتصلون · الأصدقاء. Tap any player name → profile with «إرسال طلب صداقة» and «رسالة خاصة» (Firestore `users/{uid}/friendRequests|friends|privateMessages`).
* **السجل** tabs: الأحداث · الدردشة العامة · الرسائل الخاصة, each with a TextField send.
* **Cards** are always English («Queen of Hearts»), one Semantics node for the image + text, tap only.
* **Mic gestures** live only on the mic pad (tap / long-press toggle, swipe up on, down off).
* **Leaving mid-game** hands the seat to a bot; at game end cards clear and the host gets «إعادة اللعب».
* **Jackaroo:** loop 0–75, bases Red 0 · Blue 19 · Green 38 · Yellow 57, 4 pieces each + 4 safe slots, same color never passes, a piece on its own base is safe, two adjacent pieces of one color are a wall. Ace exit/1/11, King exit/13, Queen 12, Jack swap, 10, 7 split, 5, 4 backwards. Complex mode: King sweeps (kills everything it passes), 10 can force the next player to burn a card, 5 can move any color. Semantics actions: إعلان الدور · مواقع القطع.
* **Snakes and Ladders:** 1–100 from 0, exact 100 wins, die rolled inside the Firestore transaction; ding ×N for a roll of N, ladder up / snake down clips. Semantics: إعلان الدور · موقعي · مواقع جميع اللاعبين.
* **Presence (RTDB):** `status/{uid}`, `tables/{id}/seats/{uid}`, `tables/{id}/host`, `hosting/{uid}` with `onDisconnect().remove()`. A dropped human shows «Reconnecting...» for 60 s with seat and score kept; after that the host replaces them with a bot (or removes them from a waiting table). If the host's socket dies, guests wait 60 s and then cascade-delete the Firestore table. `AppLifecycleState.detached` cleans up immediately. **The Realtime Database instance `echo99-9e73b-default-rtdb` must exist** with rules allowing signed-in reads/writes on those paths; until RTDB answers, presence-driven cleanup stays off.
* **Background:** iOS `UIBackgroundModes` audio + fetch; Android `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MICROPHONE` with a native `TableVoiceService` running while seated at an online table, so LiveKit keeps working when locked or minimized.

## Build

```bash
flutter test
flutter analyze
flutter build apk --release --obfuscate --split-debug-info=build/symbols \
  --dart-define-from-file=tool/livekit.defines.json
```

Package id: `com.echo99.echo99`. LiveKit uses `wss://echo99-0o54hspu.livekit.cloud` and key id `APIKw29rPMTjQSy`. Token minting reads `LIVEKIT_API_SECRET` from `--dart-define` or `--dart-define-from-file`. Copy `tool/livekit.defines.example.json` to the gitignored `tool/livekit.defines.json` for local builds.

GitHub Actions builds a release APK on Ubuntu (debug keystore) and an ad-hoc iOS IPA on `macos-latest`.
