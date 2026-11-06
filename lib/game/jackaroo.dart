import 'dart:math';

import 'engine.dart';
import 'rules.dart';

/// Jackaroo on a 76-square loop (0–75). Bases: Red 0, Blue 19, Green 38,
/// Yellow 57. Each player has four pieces; a piece's progress is counted from
/// its own base: [home] = still in the yard, 0..75 = on the loop,
/// 76..79 = the four safe (home-stretch) slots.
///
/// Blocking:
/// * a piece can never pass or land on a piece of its own color;
/// * a piece sitting on its own base square is safe: nobody passes or kills it;
/// * two pieces of one color on adjacent squares form a wall nobody passes;
/// * landing on another color's piece sends it home (kill).
///
/// Cards (standard): Ace = exit / 1 / 11, King = exit / 13, Queen = 12,
/// Jack = swap one of your pieces with another color's piece, 10 = 10,
/// 7 = 7 split between two pieces, 5 = 5, 4 = 4 backwards, others = face value.
/// Complex mode adds: King moves 13 and kills every piece it passes (walls do
/// not stop it), 10 may instead force the next player to burn a card, and 5
/// may move any color's piece.
const jackarooTrack = 76;
const jackarooSafeSlots = 4;
const jackarooPieces = 4;
const jackarooHome = -99;
const jackarooBases = [0, 19, 38, 57];
const jackarooColorsEn = ['Red', 'Blue', 'Green', 'Yellow'];
const jackarooColorsAr = ['أحمر', 'أزرق', 'أخضر', 'أصفر'];
const jackarooStandard = 'standard';
const jackarooComplex = 'complex';
const jackarooHandSize = 4;

class JackarooMove {
  const JackarooMove({
    required this.card,
    required this.kind,
    this.owner = '',
    this.piece = -1,
    this.steps = 0,
    this.targetOwner = '',
    this.targetPiece = -1,
    this.owner2 = '',
    this.piece2 = -1,
    this.steps2 = 0,
  });

  /// exit | forward | back | split | swap | burnNext | burnAll | burnForced
  final String card;
  final String kind;
  final String owner;
  final int piece;
  final int steps;
  final String targetOwner;
  final int targetPiece;
  final String owner2;
  final int piece2;
  final int steps2;

  String get key =>
      '$card|$kind|$owner|$piece|$steps|$targetOwner|$targetPiece|$owner2|$piece2|$steps2';

  Map<String, dynamic> toMap() => {
    'card': card,
    'kind': kind,
    'owner': owner,
    'piece': piece,
    'steps': steps,
    'targetOwner': targetOwner,
    'targetPiece': targetPiece,
    'owner2': owner2,
    'piece2': piece2,
    'steps2': steps2,
  };

  static JackarooMove fromMap(Map<dynamic, dynamic> map) {
    int n(String k) => (map[k] as num?)?.toInt() ?? -1;
    return JackarooMove(
      card: '${map['card'] ?? ''}',
      kind: '${map['kind'] ?? ''}',
      owner: '${map['owner'] ?? ''}',
      piece: n('piece'),
      steps: (map['steps'] as num?)?.toInt() ?? 0,
      targetOwner: '${map['targetOwner'] ?? ''}',
      targetPiece: n('targetPiece'),
      owner2: '${map['owner2'] ?? ''}',
      piece2: n('piece2'),
      steps2: (map['steps2'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Mutable working copy of the Jackaroo board.
class JackarooBoard {
  JackarooBoard({
    required this.mode,
    required this.colors,
    required this.pieces,
  });

  final String mode;
  final Map<String, int> colors;
  final Map<String, List<int>> pieces;

  bool get complex => mode == jackarooComplex;

  static JackarooBoard of(MatchState state) {
    final raw = state.board;
    final colors = <String, int>{};
    final rawColors = raw['colors'];
    if (rawColors is Map) {
      rawColors.forEach((k, v) => colors['$k'] = (v as num).toInt());
    }
    final pieces = <String, List<int>>{};
    final rawPieces = raw['pieces'];
    if (rawPieces is Map) {
      rawPieces.forEach((k, v) {
        pieces['$k'] = [for (final p in (v as List)) (p as num).toInt()];
      });
    }
    final mode = '${raw['mode'] ?? jackarooStandard}';
    return JackarooBoard(
      mode: mode == jackarooComplex ? jackarooComplex : jackarooStandard,
      colors: colors,
      pieces: pieces,
    );
  }

  JackarooBoard clone() => JackarooBoard(
    mode: mode,
    colors: {...colors},
    pieces: {
      for (final e in pieces.entries) e.key: [...e.value],
    },
  );

  Map<String, dynamic> toMap() => {
    'mode': mode,
    'colors': colors,
    'pieces': pieces,
  };

  int baseOf(String owner) => jackarooBases[colors[owner] ?? 0];

  /// Absolute loop square for progress on the loop, or null (yard / safe).
  int? absolute(String owner, int progress) {
    if (progress == jackarooHome || progress >= jackarooTrack) {
      return null;
    }
    return ((baseOf(owner) + progress) % jackarooTrack + jackarooTrack) %
        jackarooTrack;
  }

  /// Every piece on the loop: square → (owner, index).
  Map<int, (String, int)> occupancy() {
    final map = <int, (String, int)>{};
    for (final entry in pieces.entries) {
      for (var i = 0; i < entry.value.length; i++) {
        final abs = absolute(entry.key, entry.value[i]);
        if (abs != null) {
          map[abs] = (entry.key, i);
        }
      }
    }
    return map;
  }

  int? colorAt(Map<int, (String, int)> occ, int square) {
    final hit = occ[square % jackarooTrack];
    return hit == null ? null : colors[hit.$1];
  }

  /// Piece sitting on its own base square (safe from kills and passing).
  bool baseSafe(Map<int, (String, int)> occ, int square) {
    final hit = occ[square];
    if (hit == null) {
      return false;
    }
    return pieces[hit.$1]![hit.$2] == 0;
  }

  /// A stone with ANY stone directly behind it is the protected front of a
  /// wall — any colors, even mixed (rules PDF rule 4): nobody passes it and
  /// nobody lands on it. The rearmost stone of a run stays exposed.
  bool wallFront(Map<int, (String, int)> occ, int square) {
    return occ[square] != null &&
        occ[(square - 1 + jackarooTrack) % jackarooTrack] != null;
  }

  bool finished(String owner) =>
      (pieces[owner] ?? const []).every((p) => p >= jackarooTrack);
}

class JackarooStep {
  const JackarooStep(
    this.board,
    this.sounds,
    this.text, [
    this.kills = const [],
  ]);
  final JackarooBoard board;
  final List<String> sounds;
  final String text;

  /// Pieces this step returns to their yard: (owner, piece index).
  final List<(String, int)> kills;
}

/// Team 1 (Red/Green) pulses with dice_move, Team 2 (Blue/Yellow) with
/// move; backward steps alternate step_back 1 / step_back 2.
List<String> jackarooStepSounds(int steps, {required int colorIndex}) {
  final n = steps.abs().clamp(1, 20);
  final forward = colorIndex % 2 == 0 ? 'jk_step1' : 'jk_step2';
  return [
    for (var i = 0; i < n; i++)
      if (steps > 0)
        forward
      else
        (i.isEven ? 'jk_step_back1' : 'jk_step_back2'),
  ];
}

/// Clip when a card / action starts (TableEx «dice_roll»).
const jackarooActionSound = 'jk_card_play';

/// Consecutive 6s played by the current player in this turn.
int jackarooSixChain(MatchState state) =>
    (state.board['sixChain'] as num?)?.toInt() ?? 0;

/// The partner across the table in a 4-player team game, else null.
String? jackarooPartner(MatchState state, String owner) {
  // The 4-player individual variant (كل لاعب لنفسه) has no partner; the
  // host picks teams vs individual at start (rules PDF). Boards without the
  // flag predate the choice and keep the team behavior.
  if (state.players.length != 4 || state.board['teams'] == false) {
    return null;
  }
  final idx = state.players.indexWhere((s) => s.id == owner);
  if (idx < 0) {
    return null;
  }
  return state.players[(idx + 2) % 4].id;
}

/// Test for stones of [owner]'s own side: their own and their partner's.
bool Function(String) jackarooFriendlyTest(MatchState state, String owner) {
  final partner = jackarooPartner(state, owner);
  return (victim) => victim == owner || victim == partner;
}

/// Whose stones [owner] moves: the partner's once all four of their own are
/// safe in a team game — a finished player keeps playing on the partner's
/// stones (rules PDF).
String jackarooPlayAs(MatchState state, String owner) {
  final partner = jackarooPartner(state, owner);
  if (partner != null && JackarooBoard.of(state).finished(owner)) {
    return partner;
  }
  return owner;
}

String jackarooCardRank(String code) {
  final card = PlayingCard.parse(code);
  return card == null ? '' : card.englishRank;
}

/// Moves one piece [steps] forward (or backward when negative). Returns null
/// when the path is blocked or the move overshoots the safe slots.
JackarooStep? jackarooAdvance(
  JackarooBoard board,
  String owner,
  int index,
  int steps, {
  bool kingSweep = false,
  bool Function(String victim)? isFriendly,
}) {
  final list = board.pieces[owner];
  if (list == null || index < 0 || index >= list.length || steps == 0) {
    return null;
  }
  final start = list[index];
  if (start == jackarooHome) {
    return null;
  }
  if (steps < 0 && start >= jackarooTrack) {
    return null;
  }
  final target = start + steps;
  if (target >= jackarooTrack + jackarooSafeSlots) {
    return null;
  }
  if (steps < 0 && target < -(jackarooTrack - 4)) {
    return null;
  }
  final occ = board.occupancy();
  final myColor = board.colors[owner];
  final kills = <(String, int)>[];
  final dir = steps > 0 ? 1 : -1;
  for (var q = start + dir; dir > 0 ? q <= target : q >= target; q += dir) {
    final last = q == target;
    if (q >= jackarooTrack) {
      // Safe slots: own pieces there can be neither passed nor landed on.
      if (list.contains(q)) {
        return null;
      }
      continue;
    }
    final abs = board.absolute(owner, q)!;
    final hit = occ[abs];
    if (hit == null) {
      continue;
    }
    if (board.baseSafe(occ, abs)) {
      // A stone on its own base can be neither passed, landed on, nor
      // displaced by any card — not by its owner and not by a sweeping king
      // (rules PDF rule 3 and the complex base immunity).
      return null;
    }
    if (kingSweep) {
      // Complex king sweep returns EVERY stone on its path, including the
      // player's own and the partner's, and breaks walls (rules PDF).
      kills.add(hit);
      continue;
    }
    if (board.wallFront(occ, abs)) {
      return null; // protected wall front: no passing, no landing
    }
    if (last) {
      // Landing kills whatever sits there — opponent, partner, or the
      // player's own stone (rules PDF: capture does not distinguish colors).
      kills.add(hit);
      continue;
    }
    if (hit.$1 == owner || board.colors[hit.$1] == myColor) {
      return null; // own color may be landed on, never passed
    }
    // Other colors may be passed freely: passing never kills.
  }
  final next = board.clone();
  for (final kill in kills) {
    next.pieces[kill.$1]![kill.$2] = jackarooHome;
  }
  next.pieces[owner]![index] = target;
  final sounds = jackarooStepSounds(
    steps,
    colorIndex: board.colors[owner] ?? 0,
  );
  // One landing clip after the last step (never replaces a step pulse).
  if (kills.isNotEmpty) {
    // Returning your own or your partner's stone has its own clip, distinct
    // from capturing an opponent (rules PDF).
    final friendly = isFriendly ?? ((victim) => victim == owner);
    sounds.add(kills.any((k) => friendly(k.$1)) ? 'jk_kill_own' : 'jk_kill');
  } else if (target >= jackarooTrack && start < jackarooTrack) {
    sounds.add('jk_safe_enter');
  }
  return JackarooStep(next, sounds, '', kills);
}

JackarooStep? jackarooExit(JackarooBoard board, String owner, int index) {
  final list = board.pieces[owner];
  if (list == null || index < 0 || index >= list.length) {
    return null;
  }
  if (list[index] != jackarooHome) {
    return null;
  }
  final occ = board.occupancy();
  final base = board.baseOf(owner);
  final hit = occ[base];
  if (hit != null && board.colors[hit.$1] == board.colors[owner]) {
    return null;
  }
  final next = board.clone();
  // out_home only when a piece leaves its base.
  final sounds = ['jk_marble_enter'];
  if (hit != null) {
    next.pieces[hit.$1]![hit.$2] = jackarooHome;
    sounds.add('jk_kill');
  }
  next.pieces[owner]![index] = 0;
  return JackarooStep(next, sounds, '');
}

JackarooStep? jackarooSwap(
  JackarooBoard board,
  String owner,
  int index,
  String other,
  int otherIndex,
) {
  if (owner == other || board.colors[owner] == board.colors[other]) {
    return null;
  }
  final mine = board.pieces[owner]?[index];
  final theirs = board.pieces[other]?[otherIndex];
  if (mine == null || theirs == null) {
    return null;
  }
  final a = board.absolute(owner, mine);
  final b = board.absolute(other, theirs);
  if (a == null || b == null) {
    return null;
  }
  if (theirs == 0) {
    return null; // base-safe piece cannot be swapped
  }
  final next = board.clone();
  int rel(String who, int abs) =>
      ((abs - next.baseOf(who)) % jackarooTrack + jackarooTrack) %
      jackarooTrack;
  next.pieces[owner]![index] = rel(owner, b);
  next.pieces[other]![otherIndex] = rel(other, a);
  return JackarooStep(next, const ['jk_jack_swap'], '');
}

/// Movement values per card rank in the given mode.
List<int> _forwardSteps(int rank) => switch (rank) {
  1 => const [1, 11],
  13 => const [13],
  12 => const [12],
  11 => const [],
  4 => const [],
  7 => const [7],
  _ => [rank],
};

const jackarooColorsDefAr = ['الأحمر', 'الأزرق', 'الأخضر', 'الأصفر'];

/// «الأحمر قطعة 1»
String jackarooPieceLabel(MatchState state, String owner, int index) {
  final board = JackarooBoard.of(state);
  final color = jackarooColorsDefAr[board.colors[owner] ?? 0];
  return '$color قطعة ${index + 1}';
}

/// «الأحمر قطعة 1، الخانة 14» — one piece with its exact position.
String jackarooPieceFullLabel(MatchState state, String owner, int index) {
  final board = JackarooBoard.of(state);
  final list = board.pieces[owner] ?? const <int>[];
  if (index < 0 || index >= list.length) return '';
  return '${jackarooPieceLabel(state, owner, index)}، '
      '${_where(board, owner, list[index])}';
}

String _where(JackarooBoard board, String owner, int progress) {
  if (progress == jackarooHome) {
    return 'في القاعدة';
  }
  if (progress >= jackarooTrack) {
    return 'في المنطقة الآمنة ${progress - jackarooTrack + 1}';
  }
  final abs = board.absolute(owner, progress)!;
  final base = progress == 0 ? '، على البداية (محمية)' : '';
  return 'الخانة ${abs + 1}$base';
}

bool jackarooIsForcedToBurn(MatchState state, [String? playerId]) {
  final uid = '${state.board['forcedBurnUid'] ?? ''}';
  if (uid.isEmpty || state.board['isForcedToBurn'] != true) {
    return false;
  }
  if (playerId == null) {
    return true;
  }
  return uid == playerId;
}

/// Every legal move for [owner] holding [card].
List<JackarooMove> jackarooMovesForCard(
  MatchState state,
  String owner,
  String card,
) {
  final parsed = PlayingCard.parse(card);
  if (parsed == null) {
    return const [];
  }
  final board = JackarooBoard.of(state);
  final playAs = jackarooPlayAs(state, owner);
  final friendly = jackarooFriendlyTest(state, owner);
  final mine = board.pieces[playAs] ?? const <int>[];
  final rank = parsed.rank;
  final moves = <JackarooMove>[];
  // Exits: A and K only, per the supplied rules PDF (a 6 is a plain walk).
  // Every base piece is listed so the player picks which one leaves.
  if (rank == 1 || rank == 13) {
    for (var i = 0; i < mine.length; i++) {
      if (mine[i] == jackarooHome && jackarooExit(board, playAs, i) != null) {
        moves.add(
          JackarooMove(card: card, kind: 'exit', owner: playAs, piece: i),
        );
        break; // A / K: yard pieces are equivalent
      }
    }
  }
  if (rank == 11) {
    for (var i = 0; i < mine.length; i++) {
      for (final other in board.pieces.keys) {
        if (other == playAs) {
          continue;
        }
        final list = board.pieces[other]!;
        for (var j = 0; j < list.length; j++) {
          if (jackarooSwap(board, playAs, i, other, j) != null) {
            moves.add(
              JackarooMove(
                card: card,
                kind: 'swap',
                owner: playAs,
                piece: i,
                targetOwner: other,
                targetPiece: j,
              ),
            );
          }
        }
      }
    }
    return moves;
  }
  if (rank == 4) {
    for (var i = 0; i < mine.length; i++) {
      if (jackarooAdvance(board, playAs, i, -4, isFriendly: friendly) !=
          null) {
        moves.add(
          JackarooMove(
            card: card,
            kind: 'back',
            owner: playAs,
            piece: i,
            steps: 4,
          ),
        );
      }
    }
    return moves;
  }
  if (rank == 7) {
    for (var i = 0; i < mine.length; i++) {
      if (jackarooAdvance(board, playAs, i, 7, isFriendly: friendly) !=
          null) {
        moves.add(
          JackarooMove(
            card: card,
            kind: 'forward',
            owner: playAs,
            piece: i,
            steps: 7,
          ),
        );
      }
      for (var a = 1; a <= 6; a++) {
        final first = jackarooAdvance(board, playAs, i, a, isFriendly: friendly);
        if (first == null) {
          continue;
        }
        for (var j = 0; j < mine.length; j++) {
          if (j == i) {
            continue;
          }
          if (jackarooAdvance(first.board, playAs, j, 7 - a,
                  isFriendly: friendly) !=
              null) {
            moves.add(
              JackarooMove(
                card: card,
                kind: 'split',
                owner: playAs,
                piece: i,
                steps: a,
                owner2: playAs,
                piece2: j,
                steps2: 7 - a,
              ),
            );
          }
        }
      }
    }
    return moves;
  }
  final owners = rank == 5 && board.complex
      ? board.pieces.keys.toList()
      : [playAs];
  for (final who in owners) {
    final list = board.pieces[who]!;
    for (var i = 0; i < list.length; i++) {
      for (final steps
          in (rank == 13 && !board.complex
              ? const <int>[]
              : _forwardSteps(rank))) {
        final sweep = rank == 13 && board.complex;
        // Complex 5: an enemy piece may be pushed along the track but never
        // into its own safe home (rules PDF) — such moves are not offered.
        // Your own side's pieces (yours and your partner's) may be homed.
        if (!friendly(who) &&
            list[i] != jackarooHome &&
            list[i] + steps >= jackarooTrack) {
          continue;
        }
        if (jackarooAdvance(board, who, i, steps,
                kingSweep: sweep, isFriendly: friendly) !=
            null) {
          moves.add(
            JackarooMove(
              card: card,
              kind: 'forward',
              owner: who,
              piece: i,
              steps: steps,
            ),
          );
        }
      }
    }
  }
  // Complex 10: forcing the next player to burn is only offered when some
  // other player still holds cards; otherwise it is a plain 10 (rules PDF).
  if (rank == 10 &&
      board.complex &&
      state.players.any(
        (s) => s.id != owner && (state.hands[s.id]?.isNotEmpty ?? false),
      )) {
    moves.add(JackarooMove(card: card, kind: 'burnNext', owner: owner));
  }
  return moves;
}

/// All legal moves for [owner]'s whole hand. When nothing is playable the
/// only move is «burnAll» (discard the hand).
List<JackarooMove> jackarooLegalMoves(MatchState state, String owner) {
  final hand = state.hands[owner] ?? const <String>[];
  if (jackarooIsForcedToBurn(state, owner)) {
    return [
      for (final card in hand)
        JackarooMove(card: card, kind: 'burnForced', owner: owner),
    ];
  }
  final moves = <JackarooMove>[
    for (final card in hand) ...jackarooMovesForCard(state, owner, card),
  ];
  if (moves.isEmpty && hand.isNotEmpty) {
    // Rules PDF: the whole hand burns only when every piece is still in base
    // (no card can free you for the rest of this deal). With pieces on the
    // track another player may open the path, so one chosen card burns and
    // the turn passes.
    final playAs = jackarooPlayAs(state, owner);
    final allInBase =
        (JackarooBoard.of(state).pieces[playAs] ?? const <int>[]).every(
          (piece) => piece == jackarooHome,
        );
    if (allInBase) {
      return [JackarooMove(card: hand.first, kind: 'burnAll', owner: owner)];
    }
    return [
      for (final card in hand)
        JackarooMove(card: card, kind: 'burn', owner: owner),
    ];
  }
  return moves;
}

/// Preview of what a movement move returns to yards, for the option label.
List<(String, int)> jackarooMoveKills(MatchState state, JackarooMove move) {
  final board = JackarooBoard.of(state);
  switch (move.kind) {
    case 'back':
      return jackarooAdvance(board, move.owner, move.piece, -4)?.kills ??
          const [];
    case 'split':
      final first = jackarooAdvance(board, move.owner, move.piece, move.steps);
      if (first == null) {
        return const [];
      }
      final second = jackarooAdvance(
        first.board,
        move.owner2,
        move.piece2,
        move.steps2,
      );
      return [...first.kills, ...(second?.kills ?? const <(String, int)>[])];
    case 'forward':
      final rank = PlayingCard.parse(move.card)?.rank ?? 0;
      return jackarooAdvance(
            board,
            move.owner,
            move.piece,
            move.steps,
            kingSweep: rank == 13 && board.complex,
          )?.kills ??
          const [];
  }
  return const [];
}

/// Tells the chooser exactly who goes back to the yard, with an explicit
/// warning when it is their own or their partner's stone (rules PDF).
String jackarooKillSuffix(MatchState state, List<(String, int)> kills) {
  if (kills.isEmpty) {
    return '';
  }
  final me = state.current?.id;
  final partner = me == null ? null : jackarooPartner(state, me);
  final parts = <String>[];
  for (final k in kills) {
    final label = jackarooPieceLabel(state, k.$1, k.$2);
    if (k.$1 == me) {
      parts.add('تنبيه: سيرجع حجرك $label إلى بيته');
    } else if (k.$1 == partner) {
      parts.add('تنبيه: سيرجع حجر شريكك $label إلى بيته');
    } else {
      parts.add('سيرجع $label إلى بيته');
    }
  }
  return '، ${parts.join('، ')}';
}

String jackarooMoveLabel(MatchState state, JackarooMove move) {
  final card = PlayingCard.parse(move.card);
  final cardName = card?.englishName ?? move.card;
  final board = JackarooBoard.of(state);
  String piece(String who, int i) => jackarooPieceLabel(state, who, i);
  switch (move.kind) {
    case 'exit':
      return '$cardName: إخراج ${piece(move.owner, move.piece)} إلى البداية';
    case 'swap':
      return '$cardName: تبديل ${piece(move.owner, move.piece)} '
          '(${_where(board, move.owner, board.pieces[move.owner]![move.piece])}) '
          'مع ${piece(move.targetOwner, move.targetPiece)} '
          '(${_where(board, move.targetOwner, board.pieces[move.targetOwner]![move.targetPiece])})';
    case 'back':
      return '$cardName: إرجاع ${piece(move.owner, move.piece)} 4 خطوات'
          '${jackarooKillSuffix(state, jackarooMoveKills(state, move))}';
    case 'split':
      return '$cardName: ${piece(move.owner, move.piece)} ${move.steps} '
          'و${piece(move.owner2, move.piece2)} ${move.steps2}'
          '${jackarooKillSuffix(state, jackarooMoveKills(state, move))}';
    case 'burnNext':
      return '$cardName: حرق ورقة من اللاعب التالي';
    case 'burnAll':
      return 'لا توجد حركة — حرق جميع الأوراق';
    case 'burnForced':
    case 'burn':
      return 'حرق $cardName';
    case 'sixForfeit':
      return '$cardName: ثالث ستة متتالية — يخسر الدور';
    default:
      return '$cardName: تحريك ${piece(move.owner, move.piece)} '
          '${move.steps} خطوات'
          '${jackarooKillSuffix(state, jackarooMoveKills(state, move))}';
  }
}

/// Starts (or restarts) a Jackaroo match: 2–4 players, 4 cards each.
EngineResult startJackaroo(MatchState state, Random random, int nowMillis) {
  final count = state.players.length;
  // Rules PDF: two or four players only — a table never starts with three.
  if (count != 2 && count != 4) {
    return EngineResult(state, jackarooCountError);
  }
  final colors = <String, int>{};
  final pieces = <String, List<int>>{};
  for (var i = 0; i < count; i++) {
    // Two players sit opposite each other: Red on 0, Green on 38 (rules PDF).
    colors[state.players[i].id] = count == 2 ? i * 2 : i;
    pieces[state.players[i].id] = List.filled(jackarooPieces, jackarooHome);
  }
  final mode = '${state.board['mode'] ?? jackarooStandard}';
  final board = JackarooBoard(
    mode: mode == jackarooComplex ? jackarooComplex : jackarooStandard,
    colors: colors,
    pieces: pieces,
  );
  final deck = shuffledDeck(random);
  final hands = _dealJackaroo(state.players, deck);
  var host = state.players.indexWhere((s) => s.id == state.hostId);
  if (host < 0) {
    host = 0;
  }
  final nonce = state.nonce + 1;
  return EngineResult(
    state.copyWith(
      players: [for (final s in state.players) s.copyWith(points: 1)],
      status: 'playing',
      pile: 0,
      lastCard: null,
      turnIndex: host,
      direction: 1,
      deck: deck,
      discard: const [],
      hands: hands,
      lastPlay: null,
      cue: SoundCue(
        type: 'jackaroo',
        nonce: nonce,
        also: const ['jk_game_started', 'jk_deal_cards'],
      ),
      winnerId: null,
      nonce: nonce,
      turnStartedAt: nowMillis,
      board: {
        ...board.toMap(),
        'dealer': host,
        'dealRound': 1,
        'text': 'بدأت Jackaroo',
      },
    ),
  );
}

const jackarooCountError = 'Jackaroo تُلعب بلاعبين اثنين أو أربعة فقط';

Map<String, List<String>> _dealJackaroo(
  List<Seat> players,
  List<String> deck, [
  int cards = jackarooHandSize,
]) {
  final hands = <String, List<String>>{
    for (final seat in players) seat.id: <String>[],
  };
  for (var round = 0; round < cards; round++) {
    for (final seat in players) {
      if (deck.isNotEmpty) {
        hands[seat.id]!.add(deck.removeAt(0));
      }
    }
  }
  return hands;
}

/// Applies [move] for [playerId]. The move must be one of
/// [jackarooLegalMoves]; anything else is rejected.
EngineResult playJackaroo(
  MatchState state, {
  required String playerId,
  required JackarooMove move,
  required Random random,
  required int nowMillis,
}) {
  if (state.status != 'playing' || state.game != gameJackaroo) {
    return EngineResult(state, 'المباراة ليست جارية');
  }
  final seat = state.current;
  if (seat == null || seat.id != playerId) {
    return EngineResult(state, 'ليس دورك');
  }
  final legal = jackarooLegalMoves(state, playerId);
  if (!legal.any((m) => m.key == move.key)) {
    return EngineResult(state, 'حركة غير مسموحة');
  }
  var board = JackarooBoard.of(state);
  final startingBoard = board;
  final friendly = jackarooFriendlyTest(state, playerId);
  final hands = {
    for (final e in state.hands.entries) e.key: [...e.value],
  };
  final discard = [...state.discard];
  final sounds = <String>[jackarooActionSound];
  var text = '';
  final mine = hands[playerId] ?? <String>[];
  switch (move.kind) {
    case 'burnAll':
      discard.addAll(mine);
      mine.clear();
      sounds
        ..clear()
        ..add('jk_burn_all');
      text = '${seat.name} حرق جميع أوراقه';
    case 'burnNext':
      final nextIndex = (state.turnIndex + 1) % state.players.length;
      sounds.add('jk_force_burn');
      text = '${seat.name} أجبر ${state.players[nextIndex].name} على حرق ورقة';
    case 'burnForced':
    case 'burn':
      sounds
        ..clear()
        ..add('jk_burn_cards');
      text =
          '${seat.name} حرق ${PlayingCard.parse(move.card)?.englishName ?? move.card}';
    case 'sixForfeit':
      sounds.add('jk_blocked');
      text = '${seat.name} لعب ثالث ستة متتالية — خسر الدور';
    case 'exit':
      final exitStep = jackarooExit(board, move.owner, move.piece)!;
      board = exitStep.board;
      sounds.addAll(exitStep.sounds);
      text =
          '${seat.name} أخرج ${jackarooPieceLabel(state, move.owner, move.piece)}';
    case 'swap':
      board = jackarooSwap(
        board,
        move.owner,
        move.piece,
        move.targetOwner,
        move.targetPiece,
      )!.board;
      sounds.add('jk_jack_swap');
      text = '${seat.name} بدّل قطعة بالولد';
    case 'back':
      final step = jackarooAdvance(
        board,
        move.owner,
        move.piece,
        -4,
        isFriendly: friendly,
      )!;
      board = step.board;
      sounds.addAll(step.sounds);
      text = '${seat.name} أرجع قطعة 4 خطوات';
    case 'split':
      final a = jackarooAdvance(
        board,
        move.owner,
        move.piece,
        move.steps,
        isFriendly: friendly,
      )!;
      final b = jackarooAdvance(
        a.board,
        move.owner2,
        move.piece2,
        move.steps2,
        isFriendly: friendly,
      )!;
      board = b.board;
      sounds
        ..addAll(a.sounds)
        ..addAll(b.sounds);
      text = '${seat.name} قسّم السبعة ${move.steps}+${move.steps2}';
    default:
      final rank = PlayingCard.parse(move.card)?.rank ?? 0;
      final step = jackarooAdvance(
        board,
        move.owner,
        move.piece,
        move.steps,
        kingSweep: rank == 13 && board.complex,
        isFriendly: friendly,
      )!;
      board = step.board;
      sounds.addAll(step.sounds);
      if (move.owner != playerId) {
        sounds.add('jk_partner_control');
      }
      text = '${seat.name} حرّك قطعة ${move.steps} خطوات';
  }
  if (move.kind != 'burnAll') {
    mine.remove(move.card);
    discard.add(move.card);
  }
  hands[playerId] = mine;
  final nonce = state.nonce + 1;
  // Every step pulse is kept (no de-duplication: one clip per step).
  final unique = [...sounds];
  // A 6 is a plain walk (supplied rules): no replay, no chain, no forfeit.
  final boardMap = <String, dynamic>{
    ...board.toMap(),
    'sixChain': 0,
    'dealer': (state.board['dealer'] as num?)?.toInt() ?? 0,
    'dealRound': (state.board['dealRound'] as num?)?.toInt() ?? 1,
    'text': text,
  };
  if (move.kind == 'burnNext') {
    final nextIndex = (state.turnIndex + 1) % state.players.length;
    boardMap['isForcedToBurn'] = true;
    boardMap['forcedBurnUid'] = state.players[nextIndex].id;
  } else {
    boardMap['isForcedToBurn'] = false;
    boardMap['forcedBurnUid'] = '';
  }
  // Win check. In a 4-player team game a side wins only when all EIGHT
  // stones are safe; a player who finishes keeps playing on the partner's
  // stones (rules PDF). Individual and 2-player games end at the first
  // finisher.
  var finishNote = '';
  for (final s in state.players) {
    if (!board.finished(s.id)) {
      continue;
    }
    final partner = jackarooPartner(state, s.id);
    if (partner != null && !board.finished(partner)) {
      if (!startingBoard.finished(s.id)) {
        finishNote = '. ${s.name} أنهى حجاره وصار يلعب بحجارة شريكه';
      }
      continue;
    }
    final winText = partner == null
        ? 'فاز ${s.name}'
        : 'فاز فريق ${s.name} و'
              '${state.players.firstWhere((p) => p.id == partner).name}';
    return EngineResult(
      state.copyWith(
        status: 'finished',
        hands: const {},
        discard: discard,
        lastCard: move.card,
        cue: SoundCue(
          type: 'jackaroo',
          nonce: nonce,
          also: [...unique, 'jk_round_end'],
        ),
        winnerId: s.id,
        nonce: nonce,
        turnStartedAt: nowMillis,
        board: {...boardMap, 'text': '$text. $winText'},
      ),
    );
  }
  if (finishNote.isNotEmpty) {
    boardMap['text'] = '${boardMap['text']}$finishNote';
  }
  var deck = [...state.deck];
  // Next player who still holds cards; redeal when every hand is empty.
  var next = state.turnIndex;
  var found = false;
  for (var i = 1; i <= state.players.length; i++) {
    final idx = (state.turnIndex + i) % state.players.length;
    if ((hands[state.players[idx].id] ?? const []).isNotEmpty) {
      next = idx;
      found = true;
      break;
    }
  }
  if (!found) {
    final count = state.players.length;
    var dealer = (state.board['dealer'] as num?)?.toInt() ?? 0;
    var dealRound = (state.board['dealRound'] as num?)?.toInt() ?? 1;
    dealRound += 1;
    // Rules PDF: 4 players are dealt 4, then 4, then 5 (13 each = the full
    // 52). With 2 or 3 players every deal is 4 cards.
    var dealSize = count == 4 && dealRound == 3 ? 5 : jackarooHandSize;
    if (deck.length < count * dealSize) {
      deck = shuffledDeck(random);
      discard.clear();
      unique.add('jk_reshuffle');
      // When the deck runs out the deal passes to the next seat (rules PDF).
      dealer = (dealer + 1) % count;
      dealRound = 1;
      dealSize = jackarooHandSize;
    }
    final dealt = _dealJackaroo(state.players, deck, dealSize);
    hands
      ..clear()
      ..addAll(dealt);
    unique.add('jk_deal_cards');
    // The seat after the dealer plays first after every deal.
    next = (dealer + 1) % count;
    boardMap['dealer'] = dealer;
    boardMap['dealRound'] = dealRound;
  }
  return EngineResult(
    state.copyWith(
      turnIndex: next,
      deck: deck,
      discard: discard,
      hands: hands,
      lastCard: move.card,
      cue: SoundCue(type: 'jackaroo', nonce: nonce, also: unique),
      nonce: nonce,
      turnStartedAt: nowMillis,
      board: boardMap,
    ),
  );
}

/// Bot / timeout choice: kill > safe entry > exit > furthest progress.
JackarooMove? chooseJackarooBot(MatchState state) {
  final seat = state.current;
  if (seat == null) {
    return null;
  }
  final moves = jackarooLegalMoves(state, seat.id);
  if (moves.isEmpty) {
    return null;
  }
  JackarooMove? best;
  var bestScore = -1 << 30;
  for (final move in moves) {
    final score = _score(state, seat.id, move);
    if (score > bestScore) {
      best = move;
      bestScore = score;
    }
  }
  return best;
}

int _score(MatchState state, String me, JackarooMove move) {
  final result = playJackaroo(
    state,
    playerId: me,
    move: move,
    random: Random(1),
    nowMillis: 0,
  );
  if (result.error != null) {
    return -1 << 20;
  }
  final before = JackarooBoard.of(state);
  final after = JackarooBoard.of(result.state);
  var score = 0;
  int sum(JackarooBoard b, String who) => (b.pieces[who] ?? const <int>[]).fold(
    0,
    (a, p) => a + (p == jackarooHome ? -20 : p),
  );
  score += (sum(after, me) - sum(before, me)) * 2;
  for (final other in before.pieces.keys) {
    if (other != me) {
      score -= sum(after, other) - sum(before, other);
    }
  }
  if (result.state.status == 'finished') {
    score += 100000;
  }
  if (move.kind == 'burnAll') {
    score -= 1000;
  }
  return score;
}

/// «مواقع القطع» — every player's four pieces, for Semantics.
String jackarooPositionsText(MatchState state) {
  final board = JackarooBoard.of(state);
  final parts = <String>[];
  for (final seat in state.players) {
    final list = board.pieces[seat.id];
    if (list == null) {
      continue;
    }
    final color = board.colors[seat.id] ?? 0;
    final where = [
      for (var i = 0; i < list.length; i++)
        '${i + 1} ${_where(board, seat.id, list[i])}',
    ].join('، ');
    parts.add(
      '${seat.name} (${jackarooColorsAr[color]}، البداية ${jackarooBases[color]}): $where',
    );
  }
  if (parts.isEmpty) {
    return 'لم تبدأ Jackaroo بعد';
  }
  return parts.join('. ');
}
