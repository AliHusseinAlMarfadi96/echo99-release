import '../game/engine.dart';
import 'table_repository.dart';

/// Snapshot baseline suppresses history. Only new messages from other seats
/// alert the recipient; server echoes of the sender's own message stay silent.
class TableChatAudio {
  Set<String>? _seen;

  List<String> update(List<TableLogEntry> entries, {required String me}) {
    final ids = entries.map((entry) => entry.id).toSet();
    final before = _seen;
    _seen = ids;
    if (before == null) return const [];
    return entries.any(
          (entry) =>
              !before.contains(entry.id) &&
              entry.kind == 'chat' &&
              entry.authorId.isNotEmpty &&
              entry.authorId != me,
        )
        ? const ['alert']
        : const [];
  }
}

/// One cue per membership change, using the supplied named join/leave clips.
List<String> tableSeatAudio(MatchState prev, MatchState next, String me) {
  final before = {for (final seat in prev.players) seat.id};
  final after = {for (final seat in next.players) seat.id};
  final previousNames = {for (final seat in prev.players) seat.id: seat.name};
  final renamed = next.players.any(
    (seat) =>
        previousNames.containsKey(seat.id) &&
        previousNames[seat.id] != seat.name,
  );
  return [
    if (before.difference(after).any((id) => id != me)) 'leave_table',
    if (after.difference(before).any((id) => id != me)) 'join',
    if (renamed) 'alert',
  ];
}
