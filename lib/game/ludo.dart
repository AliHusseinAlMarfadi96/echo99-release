import 'dart:math';

import 'engine.dart';

/// BlindGamers-style Ludo: 52-square track, safe squares, exit on 6, home exact.
const ludoTrack = 52;
const ludoHomeSlots = 6;
const ludoHomeYard = -1;
const ludoFinished = ludoTrack + ludoHomeSlots; // 58
const ludoSafe = {0, 8, 13, 21, 26, 34, 39, 47};

/// Color order free: Red, Blue, Green, Yellow (indices 0..3).
const ludoColorsAr = ['أحمر', 'أزرق', 'أخضر', 'أصفر'];

/// Definite colour names used in piece labels («الأحمر قطعة 1»).
const ludoColorsDefAr = ['الأحمر', 'الأزرق', 'الأخضر', 'الأصفر'];
const ludoColorsEn = ['Red', 'Blue', 'Green', 'Yellow'];
const ludoColorIds = ['red', 'blue', 'green', 'yellow'];

/// Free-mode bases. Normal: red+green from 0, blue+yellow from 26.
const ludoBasesFree = [0, 13, 26, 39];
const ludoCountError = 'اللودو من 2 إلى 4 لاعبين';

const ludoModeNormal = 'normal';
const ludoModeFree = 'free';

class LudoSettings {
  const LudoSettings({
    this.mode = ludoModeNormal,
    this.fast = false,
    this.mandatoryKill = false,
    this.teams = false,
    this.safeSquares = true,
    this.timerSeconds = 0,
  });

  final String mode;
  final bool fast;
  final bool mandatoryKill;
  final bool teams;

  /// Host toggle «الخانات الآمنة» (squares 1, 9, 14, 22, 27, 35, 40, 48).
  final bool safeSquares;
  final int timerSeconds;

  int get pieceCount => fast ? 2 : 4;

  bool get useSafeSquares => safeSquares;

  Map<String, dynamic> toMap() => {
    'ludoMode': mode,
    'fast': fast,
    'mandatoryKill': mandatoryKill,
    'teams': teams,
    'safeSquares': safeSquares,
  };

  LudoSettings withMode(String next) => LudoSettings(
    mode: next,
    fast: fast,
    mandatoryKill: mandatoryKill,
    teams: next == ludoModeFree ? false : teams,
    safeSquares: safeSquares,
    timerSeconds: timerSeconds,
  );

  static LudoSettings of(MatchState state) {
    final b = state.board;
    final mode = '${b['ludoMode'] ?? ludoModeNormal}' == ludoModeFree
        ? ludoModeFree
        : ludoModeNormal;
    return LudoSettings(
      mode: mode,
      fast: b['fast'] == true,
      mandatoryKill: b['mandatoryKill'] == true,
      teams: b['teams'] == true || state.teamsEnabled,
      safeSquares: b['safeSquares'] != false,
      timerSeconds: state.timerSeconds,
    );
  }
}

int ludoBaseFor(int colorIndex, String mode) {
  if (mode == ludoModeFree) {
    return ludoBasesFree[colorIndex % 4];
  }
  // Normal: red(0)+green(2) from 0; blue(1)+yellow(3) from 26.
  return colorIndex.isEven ? 0 : 26;
}

/// Opposite pairs in normal mode: R↔B (0↔1), G↔Y (2↔3).
bool ludoAreOpposites(int a, int b) {
  final pair = {a % 4, b % 4};
  return pair.contains(0) && pair.contains(1) ||
      pair.contains(2) && pair.contains(3);
}

Map<String, List<int>> ludoPieces(MatchState state) {
  final raw = state.board['pieces'];
  final out = <String, List<int>>{};
  if (raw is Map) {
    raw.forEach((k, v) {
      out['$k'] = [for (final p in (v as List)) (p as num).toInt()];
    });
  }
  return out;
}

Map<String, int> ludoColors(MatchState state) {
  final raw = state.board['colors'];
  final out = <String, int>{};
  if (raw is Map) {
    raw.forEach((k, v) => out['$k'] = (v as num).toInt());
  }
  return out;
}

Map<String, bool> ludoHasKilled(MatchState state) {
  final raw = state.board['hasKilled'];
  final out = <String, bool>{};
  if (raw is Map) {
    raw.forEach((k, v) => out['$k'] = v == true);
  }
  return out;
}

bool ludoIsSafeSquare(int abs, LudoSettings settings) {
  if (!settings.useSafeSquares) return false;
  return ludoSafe.contains(abs % ludoTrack);
}

int? ludoAbsolute(int base, int progress) {
  if (progress < 0 || progress >= ludoTrack) return null;
  return (base + progress) % ludoTrack;
}

EngineResult applyLudoSettings(MatchState state, LudoSettings settings) {
  if (state.status != 'waiting') {
    return EngineResult(state, 'لا يمكن تغيير الإعدادات بعد البدء');
  }
  var mode = settings.mode;
  final count = state.players.length;
  if (mode == ludoModeFree && count == 3) {
    // 3 players → free auto.
    mode = ludoModeFree;
  }
  if (settings.teams && count != 4) {
    return EngineResult(state, 'الفرق في اللودو لأربعة لاعبين فقط');
  }
  return EngineResult(
    state.copyWith(
      timerSeconds: settings.timerSeconds,
      teamsEnabled: settings.teams,
      board: {...state.board, ...settings.toMap(), 'ludoMode': mode},
      nonce: state.nonce + 1,
    ),
  );
}

EngineResult startLudo(MatchState state, Random random, int nowMillis) {
  final count = state.players.length;
  if (count < 2 || count > 4) {
    return EngineResult(state, ludoCountError);
  }
  var settings = LudoSettings.of(state);
  // النمط العادي: 2 or 4 players. النمط الحر: 3 or 4 players.
  // 3 players can only play free; 2 players can only play normal.
  if (count == 3 && settings.mode != ludoModeFree) {
    settings = settings.withMode(ludoModeFree);
  } else if (count == 2 && settings.mode == ludoModeFree) {
    settings = settings.withMode(ludoModeNormal);
  }
  if (settings.teams && count != 4) {
    return EngineResult(state, 'الفرق في اللودو لأربعة لاعبين فقط');
  }
  // Color assignment deferred until first 6.
  final pieces = <String, List<int>>{
    for (final s in state.players)
      s.id: List.filled(settings.pieceCount, ludoHomeYard),
  };
  var host = state.players.indexWhere((s) => s.id == state.hostId);
  if (host < 0) host = 0;
  final nonce = state.nonce + 1;
  return EngineResult(
    state.copyWith(
      players: [for (final s in state.players) s.copyWith(points: 1)],
      status: 'playing',
      pile: 0,
      lastCard: null,
      turnIndex: host,
      direction: 1,
      deck: const [],
      discard: const [],
      hands: const {},
      lastPlay: null,
      teamsEnabled: settings.teams,
      cue: SoundCue(
        type: 'ludo',
        nonce: nonce,
        also: const ['ludo/game_started'],
      ),
      winnerId: null,
      nonce: nonce,
      turnStartedAt: nowMillis,
      board: {
        ...settings.toMap(),
        'colors': <String, int>{},
        'pieces': pieces,
        'hasKilled': {for (final s in state.players) s.id: false},
        'consecutiveSixes': 0,
        'pendingRoll': 0,
        'phase': 'colorRoll', // colorRoll | colorPick | roll | move
        'text':
            'بدأت اللودو — ${settings.mode == ludoModeFree ? 'النمط الحر' : 'النمط العادي'} — أول ٦ يختار اللون',
      },
    ),
  );
}

/// Per-step pulse clip: Red/Green → dice_move, Blue/Yellow → move.
String ludoStepClip(int colorIndex) =>
    colorIndex % 2 == 0 ? 'ludo/dice_move' : 'ludo/move';

/// Movement audio: one pulse per step, then exactly one landing clip
/// (eat on capture, else safe on a safe square). [finished] adds the
/// home clip once.
List<String> ludoMoveSounds(
  int steps, {
  required int colorIndex,
  bool capture = false,
  bool safe = false,
  bool finished = false,
}) {
  final ticks = <String>[
    for (var i = 0; i < steps; i++) ludoStepClip(colorIndex),
  ];
  if (capture) {
    ticks.add('ludo/eat');
  } else if (finished) {
    ticks.add('ludo/finished');
  } else if (safe) {
    ticks.add('ludo/safe');
  }
  return ticks;
}

class LudoMoveOption {
  const LudoMoveOption({required this.piece, required this.to});
  final int piece;
  final int to;
}

bool _stackImmuneAt({
  required MatchState state,
  required String moverId,
  required int abs,
  required LudoSettings settings,
  required Map<String, List<int>> pieces,
  required Map<String, int> colors,
}) {
  if (settings.mode != ludoModeFree) return false;
  // Same-color stack (2+ of one player) is immune in free mode.
  for (final e in pieces.entries) {
    final color = colors[e.key];
    if (color == null) continue;
    final base = ludoBaseFor(color, settings.mode);
    var count = 0;
    for (final op in e.value) {
      if (op < 0 || op >= ludoTrack) continue;
      if (ludoAbsolute(base, op) == abs) count++;
    }
    if (count >= 2) return true;
  }
  return false;
}

bool _canCapture({
  required LudoSettings settings,
  required int attackerColor,
  required int victimColor,
}) {
  if (settings.mode == ludoModeFree) return true;
  return ludoAreOpposites(attackerColor, victimColor);
}

List<LudoMoveOption> ludoLegalMoves(
  MatchState state,
  String playerId,
  int roll,
) {
  final settings = LudoSettings.of(state);
  final pieces = ludoPieces(state);
  final colors = ludoColors(state);
  final killed = ludoHasKilled(state);
  final mine = pieces[playerId];
  final color = colors[playerId];
  if (mine == null || color == null || roll < 1 || roll > 6) return const [];
  final base = ludoBaseFor(color, settings.mode);
  final options = <LudoMoveOption>[];
  final hasKill = killed[playerId] == true;

  for (var i = 0; i < mine.length; i++) {
    final p = mine[i];
    if (p >= ludoFinished) continue;
    if (p == ludoHomeYard) {
      if (roll == 6) options.add(LudoMoveOption(piece: i, to: 0));
      continue;
    }

    // Mandatory kill: cannot enter home stretch until captured once.
    // Wrap past home door; cannot land on 0 or 26 as a stop (continue looping).
    if (settings.mandatoryKill && !hasKill) {
      if (p < ludoTrack) {
        final dest = p + roll;
        if (dest >= ludoTrack) {
          // Wrap on the track instead of entering home.
          final wrapped = dest % ludoTrack;
          final abs = ludoAbsolute(base, wrapped)!;
          if (abs == 0 || abs == 26) {
            // Cannot land on 0 or 26 as stop — skip this piece option
            // (BlindGamers: wrap past those stops).
            final alt = (wrapped + 1) % ludoTrack;
            if (!_blocked(
              state,
              playerId,
              i,
              alt,
              absOverride: ludoAbsolute(base, alt),
            )) {
              options.add(LudoMoveOption(piece: i, to: alt));
            }
            continue;
          }
          if (!_blocked(state, playerId, i, wrapped)) {
            options.add(LudoMoveOption(piece: i, to: wrapped));
          }
          continue;
        }
        final abs = ludoAbsolute(base, dest)!;
        if (abs == 0 || abs == 26) continue;
        if (!_blocked(state, playerId, i, dest)) {
          options.add(LudoMoveOption(piece: i, to: dest));
        }
      }
      continue;
    }

    final dest = p + roll;
    if (dest > ludoFinished) continue;
    if (p >= ludoTrack || dest > ludoTrack) {
      options.add(LudoMoveOption(piece: i, to: dest));
      continue;
    }
    if (!_blocked(state, playerId, i, dest)) {
      options.add(LudoMoveOption(piece: i, to: dest));
    }
  }
  return options;
}

bool _blocked(
  MatchState state,
  String playerId,
  int pieceIndex,
  int dest, {
  int? absOverride,
}) {
  final settings = LudoSettings.of(state);
  final pieces = ludoPieces(state);
  final colors = ludoColors(state);
  final mine = pieces[playerId]!;
  final color = colors[playerId]!;
  final base = ludoBaseFor(color, settings.mode);
  if (dest < ludoTrack) {
    for (var j = 0; j < mine.length; j++) {
      if (j != pieceIndex && mine[j] == dest) return true;
    }
  }
  if (dest >= ludoTrack) return false;
  final abs = absOverride ?? ludoAbsolute(base, dest)!;
  // Ally block in teams.
  for (final e in pieces.entries) {
    if (e.key == playerId) continue;
    final otherColor = colors[e.key];
    if (otherColor == null) continue;
    final ally = settings.teams && (otherColor % 2 == color % 2);
    if (!ally) continue;
    final otherBase = ludoBaseFor(otherColor, settings.mode);
    for (final op in e.value) {
      if (op < 0 || op >= ludoTrack) continue;
      if (ludoAbsolute(otherBase, op) == abs) return true;
    }
  }
  if (_stackImmuneAt(
    state: state,
    moverId: playerId,
    abs: abs,
    settings: settings,
    pieces: pieces,
    colors: colors,
  )) {
    return true;
  }
  return false;
}

EngineResult pickLudoColor(
  MatchState state, {
  required String playerId,
  required int colorIndex,
  required int nowMillis,
}) {
  if (state.status != 'playing' || state.game != gameLudo) {
    return EngineResult(state, 'المباراة ليست جارية');
  }
  if ('${state.board['phase']}' != 'colorPick') {
    return EngineResult(state, 'لا اختيار لون الآن');
  }
  if (state.board['colorPicker'] != playerId) {
    return EngineResult(state, 'ليس دورك لاختيار اللون');
  }
  if (colorIndex < 0 || colorIndex > 3) {
    return EngineResult(state, 'لون غير صالح');
  }
  final colors = <String, int>{playerId: colorIndex};
  final settingsPick = LudoSettings.of(state);
  // Normal mode: the opponent of a 2-player game takes the opposite colour
  // (Red↔Blue, Green↔Yellow) so the two can attack each other.
  final opposite = colorIndex.isEven ? colorIndex + 1 : colorIndex - 1;
  final remaining = settingsPick.mode != ludoModeFree
      ? ([opposite, 0, 1, 2, 3]..removeWhere((c) => c == colorIndex))
      : ([0, 1, 2, 3]..remove(colorIndex));
  final seenRem = <int>{};
  remaining.retainWhere(seenRem.add);
  // Free turn order preference R B G Y; assign remaining seats in table order.
  final others = [
    for (final s in state.players)
      if (s.id != playerId) s.id,
  ];
  for (var i = 0; i < others.length; i++) {
    colors[others[i]] = remaining[i % remaining.length];
  }
  // Rebuild turn order by color for free mode: R B G Y.
  final settings = LudoSettings.of(state);
  var players = [...state.players];
  if (settings.mode == ludoModeFree) {
    players.sort((a, b) => (colors[a.id] ?? 9).compareTo(colors[b.id] ?? 9));
  }
  final turnIndex = players.indexWhere((s) => s.id == playerId);
  final nonce = state.nonce + 1;
  final name = ludoColorsAr[colorIndex];
  return EngineResult(
    state.copyWith(
      players: players,
      turnIndex: turnIndex < 0 ? 0 : turnIndex,
      cue: SoundCue(type: 'ludo', nonce: nonce, also: const []),
      nonce: nonce,
      turnStartedAt: nowMillis,
      board: {
        ...state.board,
        'colors': colors,
        'phase': 'roll',
        'pendingRoll': 0,
        'consecutiveSixes': 0,
        'text': 'اختار اللون $name — ارمِ النرد',
      },
    ),
  );
}

EngineResult rollLudo(
  MatchState state, {
  required String playerId,
  required int roll,
  required int nowMillis,
}) {
  if (state.status != 'playing' || state.game != gameLudo) {
    return EngineResult(state, 'المباراة ليست جارية');
  }
  final seat = state.current;
  if (seat == null || seat.id != playerId) {
    return EngineResult(state, 'ليس دورك');
  }
  final phase = '${state.board['phase']}';
  if (phase != 'roll' && phase != 'colorRoll') {
    return EngineResult(state, 'يجب تحريك قطعة أولاً');
  }
  if (roll < 1 || roll > 6) {
    return EngineResult(state, 'رمية غير صالحة');
  }
  final nonce = state.nonce + 1;
  const diceSounds = ['ludo/dice_roll'];

  // First-6 color selection.
  if (phase == 'colorRoll') {
    if (roll != 6) {
      final next = (state.turnIndex + 1) % state.players.length;
      return EngineResult(
        state.copyWith(
          turnIndex: next,
          cue: SoundCue(type: 'ludo', nonce: nonce, also: diceSounds),
          nonce: nonce,
          turnStartedAt: nowMillis,
          board: {
            ...state.board,
            'lastRoll': roll,
            'phase': 'colorRoll',
            'text': '${seat.name} رمى $roll — ننتظر ٦ لاختيار اللون',
          },
        ),
      );
    }
    return EngineResult(
      state.copyWith(
        cue: SoundCue(type: 'ludo', nonce: nonce, also: diceSounds),
        nonce: nonce,
        turnStartedAt: nowMillis,
        board: {
          ...state.board,
          'lastRoll': roll,
          'colorPicker': playerId,
          'phase': 'colorPick',
          'text': '${seat.name} رمى ٦ — اختر لونك',
        },
      ),
    );
  }

  var sixes = (state.board['consecutiveSixes'] as num?)?.toInt() ?? 0;
  if (roll == 6) {
    sixes += 1;
  } else {
    sixes = 0;
  }
  if (sixes >= 3) {
    final next = (state.turnIndex + 1) % state.players.length;
    return EngineResult(
      state.copyWith(
        turnIndex: next,
        cue: SoundCue(
          type: 'ludo',
          nonce: nonce,
          also: [...diceSounds, 'ludo/three_six'],
        ),
        nonce: nonce,
        turnStartedAt: nowMillis,
        board: {
          ...state.board,
          'consecutiveSixes': 0,
          'pendingRoll': 0,
          'lastRoll': roll,
          'phase': 'roll',
          'text': '${seat.name} رمى ثلاث ستات — انتهى الدور',
        },
      ),
    );
  }
  final moves = ludoLegalMoves(state, playerId, roll);
  if (moves.isEmpty) {
    final extra = roll == 6;
    final next = extra
        ? state.turnIndex
        : (state.turnIndex + 1) % state.players.length;
    return EngineResult(
      state.copyWith(
        turnIndex: next,
        cue: SoundCue(type: 'ludo', nonce: nonce, also: diceSounds),
        nonce: nonce,
        turnStartedAt: nowMillis,
        board: {
          ...state.board,
          'consecutiveSixes': extra ? sixes : 0,
          'pendingRoll': 0,
          'lastRoll': roll,
          'phase': 'roll',
          'text':
              '${seat.name} رمى $roll ولا توجد حركة متاحة${extra ? ' — ارمِ مرة أخرى' : ''}',
        },
      ),
    );
  }
  return EngineResult(
    state.copyWith(
      cue: SoundCue(type: 'ludo', nonce: nonce, also: diceSounds),
      nonce: nonce,
      turnStartedAt: nowMillis,
      board: {
        ...state.board,
        'consecutiveSixes': sixes,
        'pendingRoll': roll,
        'lastRoll': roll,
        'phase': 'move',
        'text':
            '${seat.name} رمى $roll — ${ludoMovesText(state, playerId, moves)}',
      },
    ),
  );
}

EngineResult moveLudo(
  MatchState state, {
  required String playerId,
  required int piece,
  required int nowMillis,
}) {
  if (state.status != 'playing' || state.game != gameLudo) {
    return EngineResult(state, 'المباراة ليست جارية');
  }
  final seat = state.current;
  if (seat == null || seat.id != playerId) {
    return EngineResult(state, 'ليس دورك');
  }
  if ('${state.board['phase']}' != 'move') {
    return EngineResult(state, 'ارمِ النرد أولاً');
  }
  final roll = (state.board['pendingRoll'] as num?)?.toInt() ?? 0;
  final options = ludoLegalMoves(state, playerId, roll);
  final pick = options.where((o) => o.piece == piece).firstOrNull;
  if (pick == null) {
    return EngineResult(state, 'حركة غير مسموحة');
  }
  final settings = LudoSettings.of(state);
  final pieces = ludoPieces(state);
  final colors = ludoColors(state);
  final killed = Map<String, bool>.from(ludoHasKilled(state));
  final mine = [...(pieces[playerId] ?? const <int>[])];
  final from = mine[piece];
  final to = pick.to;
  final color = colors[playerId] ?? 0;
  final base = ludoBaseFor(color, settings.mode);
  final sounds = <String>[];
  var text = '${seat.name} حرّك قطعة';
  var captured = false;
  final victims = <String>[];

  void tryCapture(int abs) {
    if (ludoIsSafeSquare(abs, settings)) return;
    if (_stackImmuneAt(
      state: state,
      moverId: playerId,
      abs: abs,
      settings: settings,
      pieces: pieces,
      colors: colors,
    )) {
      return;
    }
    for (final e in pieces.entries) {
      if (e.key == playerId) continue;
      final oc = colors[e.key];
      if (oc == null) continue;
      final ally = settings.teams && (oc % 2 == color % 2);
      if (ally) continue;
      if (!_canCapture(
        settings: settings,
        attackerColor: color,
        victimColor: oc,
      )) {
        continue;
      }
      final ob = ludoBaseFor(oc, settings.mode);
      final list = [...e.value];
      var hit = false;
      for (var j = 0; j < list.length; j++) {
        final op = list[j];
        if (op < 0 || op >= ludoTrack) continue;
        if (ludoAbsolute(ob, op) == abs) {
          list[j] = ludoHomeYard;
          hit = true;
          captured = true;
          victims.add(ludoPieceName(oc, j));
        }
      }
      if (hit) {
        pieces[e.key] = list;
      }
    }
    if (captured) {
      killed[playerId] = true;
    }
  }

  final name = ludoPieceName(color, piece);
  if (from == ludoHomeYard && to == 0) {
    tryCapture(base);
    mine[piece] = 0;
    // Leaving base: out_home, then (only if it captured) one eat at the end.
    sounds.add('ludo/out_home');
    if (captured) sounds.add('ludo/eat');
    text = '${seat.name} أخرج $name إلى ${ludoSquareLabel(base, settings)}';
  } else {
    final steps = to > from ? to - from : (to + ludoTrack - from);
    final landAbs = to < ludoTrack ? ludoAbsolute(base, to) : null;
    if (landAbs != null) tryCapture(landAbs);
    final safe = landAbs != null && ludoIsSafeSquare(landAbs, settings);
    final finished = to >= ludoFinished;
    sounds.addAll(
      ludoMoveSounds(
        steps,
        colorIndex: color,
        capture: captured,
        safe: safe,
        finished: finished,
      ),
    );
    if (finished) {
      text = '${seat.name} أوصل $name إلى المنزل';
    } else if (to >= ludoTrack) {
      text =
          '${seat.name} حرّك $name $steps خطوات إلى ممر المنزل ${to - ludoTrack + 1}';
    } else {
      text =
          '${seat.name} حرّك $name $steps خطوات إلى ${ludoSquareLabel(landAbs!, settings)}';
    }
    if (captured) {
      text = '$text وأكل ${victims.join('، ')}';
    }
    mine[piece] = to;
  }
  pieces[playerId] = mine;

  final needed = settings.pieceCount;
  final finishedCount = mine.where((p) => p >= ludoFinished).length;
  final won = finishedCount >= needed;
  final nonce = state.nonce + 1;
  final board = {
    ...state.board,
    'pieces': pieces,
    'colors': colors,
    'hasKilled': killed,
    'pendingRoll': 0,
    'lastRoll': roll,
    'phase': 'roll',
    'text': won ? '$text. فاز ${seat.name}' : text,
  };
  if (won) {
    return EngineResult(
      state.copyWith(
        status: 'finished',
        winnerId: playerId,
        cue: SoundCue(
          type: 'ludo',
          nonce: nonce,
          also: [
            ...sounds,
            if (!sounds.contains('ludo/finished')) 'ludo/finished',
          ],
        ),
        nonce: nonce,
        turnStartedAt: nowMillis,
        board: board,
      ),
    );
  }
  // Extra roll on a 6 only. A capture does NOT grant an extra roll
  // (listed as a known gap in 1.2.0; no Ludo PDF says otherwise).
  final extraTurn = roll == 6;
  final next = extraTurn
      ? state.turnIndex
      : (state.turnIndex + 1) % state.players.length;
  if (!extraTurn) {
    board['consecutiveSixes'] = 0;
  } else {
    board['text'] = '${board['text']} — ارمِ مرة أخرى';
  }
  return EngineResult(
    state.copyWith(
      turnIndex: next,
      cue: SoundCue(type: 'ludo', nonce: nonce, also: sounds),
      nonce: nonce,
      turnStartedAt: nowMillis,
      board: board,
    ),
  );
}

int? chooseLudoPiece(MatchState state) {
  final roll = (state.board['pendingRoll'] as num?)?.toInt() ?? 0;
  final seat = state.current;
  if (seat == null || roll == 0) return null;
  final options = ludoLegalMoves(state, seat.id, roll);
  if (options.isEmpty) return null;
  final settings = LudoSettings.of(state);
  if (settings.mandatoryKill) {
    final pieces = ludoPieces(state);
    final colors = ludoColors(state);
    final color = colors[seat.id];
    if (color != null) {
      final base = ludoBaseFor(color, settings.mode);
      for (final o in options) {
        if (o.to >= ludoTrack || o.to < 0) continue;
        final abs = ludoAbsolute(base, o.to);
        if (abs == null) continue;
        for (final e in pieces.entries) {
          if (e.key == seat.id) continue;
          final oc = colors[e.key];
          if (oc == null) continue;
          final ob = ludoBaseFor(oc, settings.mode);
          for (final op in e.value) {
            if (op >= 0 && op < ludoTrack && ludoAbsolute(ob, op) == abs) {
              return o.piece;
            }
          }
        }
      }
    }
  }
  options.sort((a, b) => b.to.compareTo(a.to));
  return options.first.piece;
}

int? chooseLudoBotColor(MatchState state) {
  final taken = ludoColors(state).values.toSet();
  for (var i = 0; i < 4; i++) {
    if (!taken.contains(i)) return i;
  }
  return 0;
}

/// «الأحمر قطعة 1»
String ludoPieceName(int colorIndex, int piece) =>
    '${ludoColorsDefAr[colorIndex % 4]} قطعة ${piece + 1}';

/// 1-based square label: «الخانة 14، آمنة».
String ludoSquareLabel(int abs, LudoSettings settings) {
  final safe = ludoIsSafeSquare(abs, settings) ? '، آمنة' : '';
  return 'الخانة ${abs + 1}$safe';
}

/// Where one piece is: «الخانة 14، آمنة» / «في القاعدة» / «ممر المنزل 2».
String ludoPieceWhere(MatchState state, String owner, int index) {
  final settings = LudoSettings.of(state);
  final pieces = ludoPieces(state);
  final colors = ludoColors(state);
  final list = pieces[owner] ?? const <int>[];
  if (index < 0 || index >= list.length) return '';
  final p = list[index];
  if (p == ludoHomeYard) return 'في القاعدة';
  if (p >= ludoFinished) return 'وصلت المنزل';
  if (p >= ludoTrack) return 'ممر المنزل ${p - ludoTrack + 1}';
  final base = ludoBaseFor(colors[owner] ?? 0, settings.mode);
  return ludoSquareLabel(ludoAbsolute(base, p)!, settings);
}

/// Full accessible label for one piece: «الأحمر قطعة 1، الخانة 14، آمنة».
String ludoPieceLabel(MatchState state, String owner, int index) {
  final color = ludoColors(state)[owner] ?? 0;
  return '${ludoPieceName(color, index)}، ${ludoPieceWhere(state, owner, index)}';
}

/// «الحركات المتاحة: الأحمر قطعة 1 إلى الخانة 20، ...»
String ludoMovesText(
  MatchState state,
  String playerId,
  List<LudoMoveOption> moves,
) {
  if (moves.isEmpty) return 'لا توجد حركة متاحة';
  final settings = LudoSettings.of(state);
  final color = ludoColors(state)[playerId] ?? 0;
  final base = ludoBaseFor(color, settings.mode);
  final parts = [
    for (final m in moves)
      () {
        final dest = m.to >= ludoFinished
            ? 'المنزل'
            : m.to >= ludoTrack
            ? 'ممر المنزل ${m.to - ludoTrack + 1}'
            : ludoSquareLabel(ludoAbsolute(base, m.to)!, settings);
        return '${ludoPieceName(color, m.piece)} إلى $dest';
      }(),
  ];
  return 'الحركات المتاحة: ${parts.join('، ')}';
}

String ludoPositionsText(MatchState state) {
  final pieces = ludoPieces(state);
  final colors = ludoColors(state);
  if (pieces.isEmpty) return 'لم تبدأ اللودو بعد';
  if (colors.isEmpty) {
    return 'بانتظار اختيار الألوان — أول ٦ يختار';
  }
  return [
    for (final seat in state.players)
      () {
        final list = pieces[seat.id] ?? const <int>[];
        final where = [
          for (var i = 0; i < list.length; i++)
            ludoPieceLabel(state, seat.id, i),
        ].join('، ');
        return '${seat.name}: $where';
      }(),
  ].join('. ');
}

String ludoLastActionText(MatchState state) {
  final text = '${state.board['text'] ?? ''}';
  if (text.isNotEmpty) return text;
  final roll = state.board['lastRoll'];
  return roll == null ? 'لا توجد حركة بعد' : 'آخر رمية: $roll';
}
