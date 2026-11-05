Master Echo99 1.2.0 requirements (Arabic user prefs; no source in chat).

MUST:
1. customSemanticsActions ALL games: UP=turn, DOWN=board, LEFT=last card/action, RIGHT=open log/chat. Miles: سحب ورقة + حالة سيارتي. Ludo: أماكن القطع. No PC shortcuts.
2. Jackaroo: «الكومبلكس»; isForcedToBurn — «حرق [Card]»; tap burns; burn sound; clear; pass turn.
3. Step audio: 250ms steps; dice 200ms; capture replaces final tick.
4. Background: FGS + UIBackgroundModes; Android supportsPictureInPicture; LiveKit stays connected.
5. Social: Accept/Decline/Join invite; DM reply; DM sound recipient only.
6. Host menu: mute mic (Seat.micMuted), block chat (Seat.chatBlocked), kick, replace bot.
7. Games: 99, Jackaroo, Snakes, Ludo, Thousand Miles.
8. Ludo + Thousand Miles BlindGamers full rules; assets in assets/sounds/{ludo,miles}.
9. Echo99 33/66 never reset to 0.
10. Obfuscated release --obfuscate --split-debug-info=build/symbols
11. Version 1.2.0+12; author Ali Hussein Al-Marfadi <www.ali444555@gmail.com>; package com.echo99.echo99
12. LiveKit defines file; debug keystore signing as before.
13. ALL game authority via Firestore transactions; dice rolled server-side in txn.
