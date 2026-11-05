import '../game/engine.dart';

const localTableId = 'localmatch';

/// An offline table that never touches Firestore. It starts waiting with
/// exactly one seat, the host. Bots join only through «إضافة بوت».
MatchState localWaitingTable({
  required String playerId,
  required String playerName,
  required TableSettings settings,
}) {
  return newWaitingTable(
    id: localTableId,
    name: 'مباراة بدون إنترنت',
    hostId: playerId,
    hostName: playerName,
    settings: settings,
  );
}

/// Bot ids contain no dots and never repeat at one table.
String nextLocalBotId(MatchState state) {
  var n = state.players.length;
  while (state.players.any((seat) => seat.id == 'bot$n')) {
    n += 1;
  }
  return 'bot$n';
}

String nextBotName(MatchState state) {
  final count = state.players.where((seat) => seat.isBot).length + 1;
  return 'بوت $count';
}
