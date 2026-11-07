import 'dart:math';

import 'engine.dart';

/// ألف ميل — implemented from the TableEx «ألف ميل» rules PDF (primary
/// source). Server-authoritative: every change runs inside the Firestore
/// transaction (online) or locally (offline) through these pure functions.
const milesGoal = 1000;
const milesHandSize = 6;
const milesCountError =
    'ألف ميل: فردياً من ٢ إلى ٦، أو فرقاً بـ ٤ أو ٦ أو ٨ أو ٩ (٧ غير مسموح)';
const milesScoreMin = 1000;
const milesScoreMax = 500000;
const milesScoreDefault = 5000;

/// Scoring (PDF «النقاط والمكافآت»).
const milesSafetyBonus = 100;
const milesCoupFourreBonus = 300; // + the safety's 100 = 400
const milesArriveBonus = 300; // الوصول
const milesDelayedBonus = 300; // التتويج: draw pile empty on arrival
const milesShutoutBonus = 500; // الكنس: every opponent car still on 0
const milesNo200Bonus = 300; // بلا مئتين

/// Auto-draw: a coup-fourré window delays the next automatic draw.
const milesCoupWindowMs = 5000;

/// Card codes = asset basenames under assets/sounds/miles/.
const milesDistances = {
  '25_miles': 25,
  '50_miles': 50,
  '75_miles': 75,
  '100_miles': 100,
  '200_miles': 200,
};

/// Attacks that stop the car (need remedy, then green).
const milesStopFaults = {'out_of_gas', 'flat', 'accident'};

/// Every attack card (PDF «أوراق الهجوم»).
const milesHazards = {
  'red_light',
  'speed_limit',
  'out_of_gas',
  'flat',
  'accident',
  'counterflow',
};

/// Remedy for each attack (PDF «أوراق الدفاع»).
const milesRemedies = {
  'red_light': 'green_light',
  'speed_limit': 'end_of_speed_limit',
  'out_of_gas': 'gas',
  'flat': 'spare_tire',
  'accident': 'repairs',
  'counterflow': 'end_of_counterflow',
};

const milesRemedyCards = {
  'green_light',
  'end_of_speed_limit',
  'gas',
  'spare_tire',
  'repairs',
  'end_of_counterflow',
};

/// Safeties (PDF «أوراق الحصانة») — one of each.
const milesSafeties = {
  'right_of_way',
  'extra_tank',
  'puncture_proof',
  'driving_ace',
};

/// What each safety protects against.
const milesSafetyCovers = {
  'right_of_way': {'red_light', 'speed_limit'},
  'extra_tank': {'out_of_gas'},
  'puncture_proof': {'flat'},
  'driving_ace': {'accident', 'counterflow'},
};

/// Team formations (PDF): player count → possible team sizes.
const milesTeamOptions = {
  4: [2],
  6: [3, 2],
  8: [4, 2],
  9: [3],
};

class MilesSettings {
  const MilesSettings({
    this.scoreLimit = milesScoreDefault,
    this.stackHazards = false,
    this.reshuffleDiscard = true,
    this.teams = false,
    this.teamSize = 2,
    this.autoDraw = false,
    this.hideHand = false,
    this.timerSeconds = 0,
  });

  final int scoreLimit;

  /// «مراكمة الأعطال» / «السماح بمهاجمة السيارة الواقفة» (default off).
  final bool stackHazards;

  /// «إعادة خلط المرميات» (default on).
  final bool reshuffleDiscard;
  final bool teams;

  /// Players per team when the count allows two formations (6 or 8).
  final int teamSize;

  /// «سحب ورقة تلقائيًا».
  final bool autoDraw;

  /// Optional: hand cards announced as «ورقة مخفية N» except the last draw.
  final bool hideHand;
  final int timerSeconds;

  Map<String, dynamic> toMap() => {
    'scoreLimit': scoreLimit.clamp(milesScoreMin, milesScoreMax),
    'stackHazards': stackHazards,
    'reshuffleDiscard': reshuffleDiscard,
    'teams': teams,
    'teamSize': teamSize,
    'autoDraw': autoDraw,
    'hideHand': hideHand,
  };

  MilesSettings copyWith({
    int? scoreLimit,
    bool? stackHazards,
    bool? reshuffleDiscard,
    bool? teams,
    int? teamSize,
    bool? autoDraw,
    bool? hideHand,
    int? timerSeconds,
  }) {
    return MilesSettings(
      scoreLimit: scoreLimit ?? this.scoreLimit,
      stackHazards: stackHazards ?? this.stackHazards,
      reshuffleDiscard: reshuffleDiscard ?? this.reshuffleDiscard,
      teams: teams ?? this.teams,
      teamSize: teamSize ?? this.teamSize,
      autoDraw: autoDraw ?? this.autoDraw,
      hideHand: hideHand ?? this.hideHand,
      timerSeconds: timerSeconds ?? this.timerSeconds,
    );
  }

  static MilesSettings of(MatchState state) {
    final b = state.board;
    final raw = (b['scoreLimit'] as num?)?.toInt() ?? state.maxPoints;
    return MilesSettings(
      scoreLimit: raw.clamp(milesScoreMin, milesScoreMax),
      stackHazards: b['stackHazards'] == true,
      reshuffleDiscard: b['reshuffleDiscard'] != false,
      teams: b['teams'] == true || state.teamsEnabled,
      teamSize: (b['teamSize'] as num?)?.toInt() ?? 2,
      autoDraw: b['autoDraw'] == true,
      hideHand: b['hideHand'] == true,
      timerSeconds: state.timerSeconds,
    );
  }
}

/// The PDF deck: 121 cards.
List<String> milesFreshDeck() {
  return <String>[
    for (var i = 0; i < 10; i++) '25_miles',
    for (var i = 0; i < 10; i++) '50_miles',
    for (var i = 0; i < 10; i++) '75_miles',
    for (var i = 0; i < 12; i++) '100_miles',
    for (var i = 0; i < 4; i++) '200_miles',
    for (var i = 0; i < 5; i++) 'red_light',
    for (var i = 0; i < 4; i++) 'speed_limit',
    for (var i = 0; i < 3; i++) 'out_of_gas',
    for (var i = 0; i < 3; i++) 'flat',
    for (var i = 0; i < 3; i++) 'accident',
    for (var i = 0; i < 6; i++) 'counterflow',
    for (var i = 0; i < 14; i++) 'green_light',
    for (var i = 0; i < 6; i++) 'end_of_speed_limit',
    for (var i = 0; i < 6; i++) 'gas',
    for (var i = 0; i < 6; i++) 'spare_tire',
    for (var i = 0; i < 6; i++) 'repairs',
    for (var i = 0; i < 9; i++) 'end_of_counterflow',
    'right_of_way',
    'extra_tank',
    'puncture_proof',
    'driving_ace',
  ];
}

/// Arabic / English names (PDF wording).
const _labelsAr = {
  '25_miles': '٢٥ ميلاً',
  '50_miles': '٥٠ ميلاً',
  '75_miles': '٧٥ ميلاً',
  '100_miles': '١٠٠ ميل',
  '200_miles': '٢٠٠ ميل',
  'red_light': 'الإشارة الحمراء',
  'speed_limit': 'تحديد السرعة',
  'out_of_gas': 'نفاد الوقود',
  'flat': 'ثقب الإطار',
  'accident': 'الحادث',
  'counterflow': 'الاتجاه المعاكس',
  'green_light': 'الإشارة الخضراء',
  'end_of_speed_limit': 'نهاية تحديد السرعة',
  'gas': 'الوقود',
  'spare_tire': 'الإطار الاحتياطي',
  'repairs': 'التصليح',
  'end_of_counterflow': 'نهاية الاتجاه المعاكس',
  'right_of_way': 'أفضلية المرور',
  'extra_tank': 'الخزان الإضافي',
  'puncture_proof': 'الإطار المضاد للثقب',
  'driving_ace': 'سائق محترف',
};

const _labelsEn = {
  '25_miles': '25 miles',
  '50_miles': '50 miles',
  '75_miles': '75 miles',
  '100_miles': '100 miles',
  '200_miles': '200 miles',
  'red_light': 'Stop',
  'speed_limit': 'Speed Limit',
  'out_of_gas': 'Out of Gas',
  'flat': 'Flat Tire',
  'accident': 'Accident',
  'counterflow': 'Wrong Way',
  'green_light': 'Go',
  'end_of_speed_limit': 'End of Limit',
  'gas': 'Gasoline',
  'spare_tire': 'Spare Tire',
  'repairs': 'Repairs',
  'end_of_counterflow': 'End of Wrong Way',
  'right_of_way': 'Right of Way',
  'extra_tank': 'Extra Tank',
  'puncture_proof': 'Puncture-Proof',
  'driving_ace': 'Driving Ace',
};

/// Language for Miles labels; set from the device locale at startup.
var milesEnglish = false;

String milesCardLabel(String code) =>
    (milesEnglish ? _labelsEn : _labelsAr)[code] ?? code;

String _t(String ar, String en) => milesEnglish ? en : ar;

bool milesPlayerCountOk(int count, {bool teams = false}) {
  if (teams) return milesTeamOptions.containsKey(count);
  return count >= 2 && count <= 6;
}

// ---------------------------------------------------------------------------
// Cars (one per player, or one per team).

/// Car id driven by [uid]: the first member of the player's team, else uid.
String milesCarOf(MatchState state, String uid) {
  final teams = state.teams;
  if (teams != null && MilesSettings.of(state).teams) {
    for (final team in teams) {
      if (team.contains(uid)) return team.first;
    }
  }
  return uid;
}

List<String> milesCarIds(MatchState state) {
  final teams = state.teams;
  if (teams != null && MilesSettings.of(state).teams) {
    return [for (final t in teams) t.first];
  }
  return [for (final s in state.players) s.id];
}

List<String> milesCarMembers(MatchState state, String carId) {
  final teams = state.teams;
  if (teams != null && MilesSettings.of(state).teams) {
    for (final t in teams) {
      if (t.first == carId) return t;
    }
  }
  return [carId];
}

String milesCarName(MatchState state, String carId) {
  final names = [
    for (final id in milesCarMembers(state, carId))
      state.players.where((s) => s.id == id).firstOrNull?.name ?? id,
  ];
  if (names.length == 1) return names.single;
  return _t('فريق ${names.join(' و')}', 'Team ${names.join(' & ')}');
}

Map<String, dynamic> _emptyCar(int score) => {
  'miles': 0,
  'go': false,
  'faults': <String>[],
  'speedLimit': false,
  'counterflow': false,
  'safeties': <String>[],
  'score': score,
  'used200': 0,
  'arrived': false,
};

Map<String, dynamic> milesCar(MatchState state, String carId) {
  final raw = state.board['cars'];
  if (raw is Map && raw[carId] is Map) {
    final m = Map<String, dynamic>.from(raw[carId] as Map);
    m['faults'] = [for (final f in (m['faults'] as List? ?? const [])) '$f'];
    m['safeties'] = [
      for (final f in (m['safeties'] as List? ?? const [])) '$f',
    ];
    return m;
  }
  return _emptyCar(0);
}

MatchState _setCar(MatchState state, String carId, Map<String, dynamic> car) {
  final all = <String, dynamic>{};
  final raw = state.board['cars'];
  if (raw is Map) raw.forEach((k, v) => all['$k'] = v);
  all[carId] = car;
  return state.copyWith(board: {...state.board, 'cars': all});
}

List<String> _faults(Map<String, dynamic> car) => [
  for (final f in (car['faults'] as List? ?? const [])) '$f',
];
List<String> _safeties(Map<String, dynamic> car) => [
  for (final f in (car['safeties'] as List? ?? const [])) '$f',
];
bool _row(Map<String, dynamic> car) => _safeties(car).contains('right_of_way');
int _int(Object? v) => (v as num?)?.toInt() ?? 0;

/// The car may play distance cards.
bool milesCanDrive(Map<String, dynamic> car) =>
    _faults(car).isEmpty && (car['go'] == true || _row(car));

/// A standing car (for «مراكمة الأعطال»).
bool milesIsStopped(Map<String, dynamic> car) => !milesCanDrive(car);

bool _protected(Map<String, dynamic> car, String hazard) {
  for (final s in _safeties(car)) {
    if ((milesSafetyCovers[s] ?? const {}).contains(hazard)) return true;
  }
  return false;
}

String? milesMatchingSafety(String hazard) {
  for (final e in milesSafetyCovers.entries) {
    if (e.value.contains(hazard)) return e.key;
  }
  return null;
}

/// Why [hazard] cannot land on [carId] (null = legal target).
String? milesTargetError(
  MatchState state,
  String attackerId,
  String carId,
  String hazard,
) {
  if (carId == milesCarOf(state, attackerId)) {
    return _t('لا تهاجم سيارتك', 'You cannot attack your own car');
  }
  final car = milesCar(state, carId);
  if (_protected(car, hazard)) {
    return _t('السيارة محمية بالحصانة', 'That car holds the safety');
  }
  final settings = MilesSettings.of(state);
  if (!settings.stackHazards && milesIsStopped(car)) {
    return _t('السيارة واقفة ولا تُهاجَم', 'A stopped car cannot be attacked');
  }
  switch (hazard) {
    case 'speed_limit':
      if (car['speedLimit'] == true) {
        return _t('عليها تحديد سرعة مسبقاً', 'Already speed-limited');
      }
    case 'counterflow':
      if (car['counterflow'] == true) {
        return _t('عليها اتجاه معاكس مسبقاً', 'Already going the wrong way');
      }
    case 'red_light':
      if (_faults(car).contains('red_light')) {
        return _t('عليها إشارة حمراء مسبقاً', 'Already stopped by a red light');
      }
    default:
      if (_faults(car).contains(hazard)) {
        return _t('لا يتكرر الهجوم نفسه', 'The same attack cannot repeat');
      }
  }
  return null;
}

/// Legal target cars for [hazard] played by [attackerId].
List<String> milesLegalTargets(
  MatchState state,
  String attackerId,
  String hazard,
) {
  return [
    for (final car in milesCarIds(state))
      if (milesTargetError(state, attackerId, car, hazard) == null) car,
  ];
}

/// Why [card] cannot be played (null = playable). Hazards are checked
/// against every possible target.
String? milesPlayError(MatchState state, String playerId, String card) {
  final carId = milesCarOf(state, playerId);
  final car = milesCar(state, carId);
  if (milesDistances.containsKey(card)) {
    if (!milesCanDrive(car)) {
      return _faults(car).isNotEmpty
          ? _t('سيارتك معطّلة — أصلحها أولاً', 'Your car is broken down')
          : _t('تحتاج الإشارة الخضراء أولاً', 'You need a Go card first');
    }
    final add = milesDistances[card]!;
    if (car['speedLimit'] == true && add > 50) {
      return _t('تحديد السرعة: ٢٥ و٥٠ فقط', 'Speed limit: 25 or 50 only');
    }
    if (card == '200_miles' && _int(car['used200']) >= 2) {
      return _t('ورقتا ٢٠٠ فقط في الجولة', 'Only two 200s per round');
    }
    if (car['counterflow'] != true && _int(car['miles']) + add > milesGoal) {
      return _t('تتجاوز الألف — يجب الوصول بالضبط', 'Must reach exactly 1000');
    }
    return null;
  }
  if (milesSafeties.contains(card)) {
    return _safeties(car).contains(card)
        ? _t('لعبت هذه الحصانة مسبقاً', 'Safety already played')
        : null;
  }
  if (milesHazards.contains(card)) {
    return milesLegalTargets(state, playerId, card).isEmpty
        ? _t('لا يوجد هدف مشروع لهذا الهجوم', 'No legal target for this attack')
        : null;
  }
  final faults = _faults(car);
  switch (card) {
    case 'green_light':
      if (faults.any((f) => f != 'red_light')) {
        return _t('أصلح العطل قبل أن تشغّل', 'Repair before you can go');
      }
      if (_row(car)) {
        return _t(
          'أفضلية المرور تغنيك عن الإشارة الخضراء',
          'Right of Way replaces Go',
        );
      }
      if (car['go'] == true && faults.isEmpty) {
        return _t('سيارتك تسير بالفعل', 'You are already moving');
      }
      return null;
    case 'end_of_speed_limit':
      return car['speedLimit'] == true
          ? null
          : _t('لا يوجد تحديد سرعة', 'No speed limit to end');
    case 'end_of_counterflow':
      return car['counterflow'] == true
          ? null
          : _t('لا يوجد اتجاه معاكس', 'Not going the wrong way');
    case 'gas':
    case 'spare_tire':
    case 'repairs':
      final hazard = milesRemedies.entries
          .firstWhere((e) => e.value == card)
          .key;
      return faults.contains(hazard)
          ? null
          : _t(
              'سيارتك لا تحتاج ${milesCardLabel(card)}',
              'Your car does not need ${milesCardLabel(card)}',
            );
  }
  return _t('ورقة غير معروفة', 'Unknown card');
}

// ---------------------------------------------------------------------------
// Setup.

List<List<String>>? _buildMilesTeams(List<Seat> players, MilesSettings s) {
  if (!s.teams) return null;
  final options = milesTeamOptions[players.length];
  if (options == null) return null;
  final size = options.contains(s.teamSize) ? s.teamSize : options.first;
  final teamCount = players.length ~/ size;
  // Seat order, dealt round-robin so team-mates alternate around the table.
  final out = [for (var i = 0; i < teamCount; i++) <String>[]];
  for (var i = 0; i < players.length; i++) {
    out[i % teamCount].add(players[i].id);
  }
  return out;
}

EngineResult applyMilesSettings(MatchState state, MilesSettings settings) {
  if (state.status != 'waiting') {
    return EngineResult(state, 'لا يمكن تغيير الإعدادات بعد البدء');
  }
  final limit = settings.scoreLimit.clamp(milesScoreMin, milesScoreMax);
  return EngineResult(
    state.copyWith(
      timerSeconds: settings.timerSeconds,
      maxPoints: limit,
      teamsEnabled: settings.teams,
      board: {
        ...state.board,
        ...settings.copyWith(scoreLimit: limit).toMap(),
      },
      nonce: state.nonce + 1,
    ),
  );
}

EngineResult startMiles(MatchState state, Random random, int nowMillis) {
  final count = state.players.length;
  final settings = MilesSettings.of(state);
  if (!milesPlayerCountOk(count, teams: settings.teams)) {
    return EngineResult(state, milesCountError);
  }
  final teams = _buildMilesTeams(state.players, settings);
  return _dealMilesRound(
    state.copyWith(teams: teams, teamsEnabled: settings.teams),
    random: random,
    nowMillis: nowMillis,
    keepScores: false,
  );
}

EngineResult _dealMilesRound(
  MatchState state, {
  required Random random,
  required int nowMillis,
  required bool keepScores,
  List<String> leadSounds = const [],
}) {
  final settings = MilesSettings.of(state);
  final deck = milesFreshDeck()..shuffle(random);
  final hands = <String, List<String>>{
    for (final s in state.players) s.id: <String>[],
  };
  for (var r = 0; r < milesHandSize; r++) {
    for (final s in state.players) {
      if (deck.isNotEmpty) hands[s.id]!.add(deck.removeAt(0));
    }
  }
  final cars = <String, dynamic>{
    for (final id in milesCarIds(state))
      id: _emptyCar(keepScores ? _int(milesCar(state, id)['score']) : 0),
  };
  var host = state.players.indexWhere((s) => s.id == state.hostId);
  if (host < 0) host = 0;
  // PDF: the starting advantage passes to the next player every round.
  final round = _int(state.board['round']) + 1;
  final starter = keepScores
      ? (_int(state.board['starter']) + 1) % state.players.length
      : host;
  final nonce = state.nonce + 1;
  var next = state.copyWith(
    players: [for (final s in state.players) s.copyWith(points: 1)],
    status: 'playing',
    pile: 0,
    lastCard: null,
    turnIndex: starter,
    direction: 1,
    deck: deck,
    discard: const [],
    hands: hands,
    lastPlay: null,
    maxPoints: settings.scoreLimit,
    cue: SoundCue(
      type: 'miles',
      nonce: nonce,
      also: [...leadSounds, 'miles/game_started'],
    ),
    winnerId: null,
    nonce: nonce,
    turnStartedAt: nowMillis,
    board: {
      ...settings.toMap(),
      'cars': cars,
      'phase': 'draw',
      'coup': null,
      'lastDrawn': <String, dynamic>{},
      'round': round,
      'starter': starter,
      'text': keepScores
          ? _t(
              'الجولة $round — اسحب ورقة ثم العب أو ارمِ',
              'Round $round — draw, then play or discard',
            )
          : _t(
              'بدأت ألف ميل — اسحب ورقة ثم العب أو ارمِ',
              'Thousand Miles started — draw, then play or discard',
            ),
    },
  );
  if (settings.autoDraw) {
    next = _autoDrawFor(next, random, const []);
  }
  return EngineResult(next);
}

// ---------------------------------------------------------------------------
// Drawing.

/// Draws one card for the current player inside the same state, or skips
/// the draw when the pile is empty for good. Returns null when no card can
/// be drawn (round over by exhaustion is handled by the caller).
({MatchState state, String? card})? _drawInto(MatchState state, Random random) {
  final seat = state.current;
  if (seat == null) return null;
  var deck = [...state.deck];
  var discard = [...state.discard];
  final settings = MilesSettings.of(state);
  if (deck.isEmpty && settings.reshuffleDiscard) {
    // Safeties never return to the pile.
    deck = [
      for (final c in discard)
        if (!milesSafeties.contains(c)) c,
    ]..shuffle(random);
    discard = [];
  }
  if (deck.isEmpty) {
    return (
      state: state.copyWith(
        deck: deck,
        discard: discard,
        board: {...state.board, 'phase': 'play'},
      ),
      card: null,
    );
  }
  final card = deck.removeAt(0);
  final hands = {
    for (final e in state.hands.entries) e.key: [...e.value],
  };
  hands[seat.id] = [...(hands[seat.id] ?? const <String>[]), card];
  final lastDrawn = <String, dynamic>{};
  final raw = state.board['lastDrawn'];
  if (raw is Map) raw.forEach((k, v) => lastDrawn['$k'] = v);
  lastDrawn[seat.id] = card;
  return (
    state: state.copyWith(
      deck: deck,
      discard: discard,
      hands: hands,
      board: {...state.board, 'phase': 'play', 'lastDrawn': lastDrawn},
    ),
    card: card,
  );
}

MatchState _autoDrawFor(MatchState state, Random random, List<String> lead) {
  final drawn = _drawInto(state, random);
  if (drawn == null) return state;
  final cue = state.cue;
  return drawn.state.copyWith(
    cue: SoundCue(
      type: 'miles',
      nonce: cue?.nonce ?? state.nonce,
      also: [...?cue?.also, ...lead, if (drawn.card != null) 'miles/draw'],
    ),
  );
}

EngineResult drawMiles(
  MatchState state, {
  required String playerId,
  required Random random,
  required int nowMillis,
}) {
  if (state.status != 'playing' || state.game != gameThousandMiles) {
    return EngineResult(state, 'المباراة ليست جارية');
  }
  final seat = state.current;
  if (seat == null || seat.id != playerId) {
    return EngineResult(state, _t('ليس دورك', 'Not your turn'));
  }
  if ('${state.board['phase']}' != 'draw') {
    return EngineResult(
      state,
      _t('سحبت بالفعل — العب أو ارمِ ورقة', 'Already drew — play or discard'),
    );
  }
  // Drawing closes any open coup-fourré window (PDF «الخدعة»).
  final cleared = state.copyWith(board: {...state.board, 'coup': null});
  final drawn = _drawInto(cleared, random);
  if (drawn == null) return EngineResult(state, 'تعذر السحب');
  final nonce = state.nonce + 1;
  final card = drawn.card;
  final hideHand = MilesSettings.of(state).hideHand;
  final mineText = card == null
      ? _t(
          'كومة السحب فارغة — العب ما في يدك',
          'Draw pile empty — play your hand',
        )
      : hideHand
      ? _t('سحبت ${milesCardLabel(card)}', 'You drew ${milesCardLabel(card)}')
      : _t('${seat.name} سحب ورقة', '${seat.name} drew a card');
  return EngineResult(
    drawn.state.copyWith(
      cue: SoundCue(
        type: 'miles',
        nonce: nonce,
        also: [if (card != null) 'miles/draw'],
      ),
      nonce: nonce,
      turnStartedAt: nowMillis,
      board: {
        ...drawn.state.board,
        'text': card == null
            ? mineText
            : _t('${seat.name} سحب ورقة', '${seat.name} drew a card'),
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Coup fourré.

/// Players allowed to answer the open coup window with [card].
List<String> milesCoupHolders(MatchState state) {
  final coup = state.board['coup'];
  if (coup is! Map) return const [];
  final carId = '${coup['carId'] ?? ''}';
  final safety = milesMatchingSafety('${coup['hazard'] ?? ''}');
  if (safety == null) return const [];
  return [
    for (final uid in milesCarMembers(state, carId))
      if ((state.hands[uid] ?? const []).contains(safety)) uid,
  ];
}

/// The open coup window for [uid], if any: (hazard, safety, attacker name).
({String hazard, String safety, int openedAt})? milesCoupFor(
  MatchState state,
  String uid,
) {
  final coup = state.board['coup'];
  if (coup is! Map) return null;
  if (!milesCoupHolders(state).contains(uid)) return null;
  final hazard = '${coup['hazard']}';
  return (
    hazard: hazard,
    safety: milesMatchingSafety(hazard)!,
    openedAt: _int(coup['openedAt']),
  );
}

EngineResult coupFourreMiles(
  MatchState state, {
  required String playerId,
  required String card,
  required Random random,
  required int nowMillis,
}) {
  if (state.status != 'playing' || state.game != gameThousandMiles) {
    return EngineResult(state, 'المباراة ليست جارية');
  }
  final open = milesCoupFor(state, playerId);
  if (open == null) {
    return EngineResult(
      state,
      _t('فاتت فرصة الخدعة', 'The coup fourré window closed'),
    );
  }
  if (card != open.safety) {
    return EngineResult(
      state,
      _t('هذه ليست الحصانة المقابلة', 'Not the matching safety'),
    );
  }
  final coup = state.board['coup'] as Map;
  final carId = '${coup['carId']}';
  final hands = {
    for (final e in state.hands.entries) e.key: [...e.value],
  };
  hands[playerId] = [...(hands[playerId] ?? const <String>[])]..remove(card);
  // Cancel the attack: restore the car exactly as it was before it landed.
  final before = coup['before'];
  final car = before is Map
      ? Map<String, dynamic>.from(before)
      : milesCar(state, carId);
  car['score'] = _int(milesCar(state, carId)['score']);
  _applySafety(car, card);
  car['score'] = _int(car['score']) + milesSafetyBonus + milesCoupFourreBonus;
  var next = _setCar(state, carId, car);
  final idx = next.players.indexWhere((s) => s.id == playerId);
  final seat = next.players[idx];
  final nonce = state.nonce + 1;
  next = next.copyWith(
    turnIndex: idx,
    hands: hands,
    lastCard: card,
    cue: SoundCue(
      type: 'miles',
      nonce: nonce,
      also: ['miles/cards', 'miles/$card'],
    ),
    nonce: nonce,
    turnStartedAt: nowMillis,
    board: {
      ...next.board,
      'phase': 'draw',
      'coup': null,
      'text': _t(
        '${seat.name}: خدعة! ${milesCardLabel(card)} ألغت ${milesCardLabel(open.hazard)} '
            '(+${milesSafetyBonus + milesCoupFourreBonus}) — دور إضافي',
        '${seat.name}: Coup fourré! ${milesCardLabel(card)} cancels '
            '${milesCardLabel(open.hazard)} (+400) — extra turn',
      ),
    },
  );
  if (MilesSettings.of(next).autoDraw) {
    next = _autoDrawFor(next, random, const []);
  }
  return EngineResult(next);
}

/// The holder declines the coup window (button «تجاهل»), or the auto-draw
/// timer ran out: the window closes; in auto-draw mode the current player
/// then draws.
EngineResult closeMilesCoup(
  MatchState state, {
  required String playerId,
  required Random random,
  required int nowMillis,
}) {
  final coup = state.board['coup'];
  if (coup is! Map) return EngineResult(state, 'لا توجد خدعة مفتوحة');
  final holder = milesCoupHolders(state).contains(playerId);
  final current = state.current?.id == playerId;
  final expired = nowMillis - _int(coup['openedAt']) >= milesCoupWindowMs;
  if (!holder && !(current && expired)) {
    return EngineResult(state, 'لا يمكنك إغلاق الخدعة الآن');
  }
  final nonce = state.nonce + 1;
  var next = state.copyWith(
    nonce: nonce,
    board: {...state.board, 'coup': null},
    cue: SoundCue(type: 'miles', nonce: nonce, also: const []),
  );
  if (MilesSettings.of(next).autoDraw && '${next.board['phase']}' == 'draw') {
    next = _autoDrawFor(next, random, const []);
  }
  return EngineResult(next);
}

// ---------------------------------------------------------------------------
// Playing.

void _applySafety(Map<String, dynamic> car, String card) {
  final safeties = _safeties(car)..add(card);
  car['safeties'] = safeties;
  final covers = milesSafetyCovers[card] ?? const <String>{};
  car['faults'] = [
    for (final f in _faults(car))
      if (!covers.contains(f)) f,
  ];
  if (covers.contains('speed_limit')) car['speedLimit'] = false;
  if (covers.contains('counterflow')) car['counterflow'] = false;
}

EngineResult playMiles(
  MatchState state, {
  required String playerId,
  required String card,
  String? targetId,
  required bool discardOnly,
  required Random random,
  required int nowMillis,
}) {
  if (state.status != 'playing' || state.game != gameThousandMiles) {
    return EngineResult(state, 'المباراة ليست جارية');
  }
  // Out-of-turn (or in-turn) coup fourré by a holder of the matching safety.
  final open = milesCoupFor(state, playerId);
  if (open != null && !discardOnly && card == open.safety) {
    return coupFourreMiles(
      state,
      playerId: playerId,
      card: card,
      random: random,
      nowMillis: nowMillis,
    );
  }
  final seat = state.current;
  if (seat == null || seat.id != playerId) {
    return EngineResult(state, _t('ليس دورك', 'Not your turn'));
  }
  if ('${state.board['phase']}' != 'play') {
    return EngineResult(state, _t('اسحب ورقة أولاً', 'Draw a card first'));
  }
  final hands = {
    for (final e in state.hands.entries) e.key: [...e.value],
  };
  final mine = hands[playerId] ?? <String>[];
  if (!mine.contains(card)) {
    return EngineResult(state, _t('الورقة ليست في يدك', 'Card not in hand'));
  }
  if (!discardOnly) {
    final error = milesPlayError(state, playerId, card);
    if (error != null) return EngineResult(state, error);
  }
  mine.remove(card);
  hands[playerId] = mine;
  // The player acting closes any coup window that was not taken.
  var next = state.copyWith(board: {...state.board, 'coup': null});
  final discard = [...state.discard];
  final sounds = <String>['miles/cards'];
  var text = '';
  var extraTurn = false;
  Map<String, dynamic>? openCoup;
  final carId = milesCarOf(state, playerId);

  if (discardOnly) {
    // Safeties never go back to the pile, even when thrown away.
    if (!milesSafeties.contains(card)) discard.add(card);
    text = _t(
      '${seat.name} رمى ${milesCardLabel(card)}',
      '${seat.name} discarded ${milesCardLabel(card)}',
    );
  } else if (milesDistances.containsKey(card)) {
    final car = milesCar(next, carId);
    final add = milesDistances[card]!;
    if (card == '200_miles') car['used200'] = _int(car['used200']) + 1;
    final miles = _int(car['miles']);
    sounds.add('miles/$card');
    discard.add(card);
    if (car['counterflow'] == true) {
      // Wrong way: subtract miles and the same points; never below 0.
      final lost = min(add, miles);
      car['miles'] = miles - lost;
      car['score'] = _int(car['score']) - lost;
      text = _t(
        '${seat.name} في الاتجاه المعاكس: −$lost ميل — ${car['miles']} ميل',
        '${seat.name} wrong way: −$lost miles — ${car['miles']} miles',
      );
      next = _setCar(next, carId, car);
    } else {
      car['miles'] = miles + add;
      car['score'] = _int(car['score']) + add;
      next = _setCar(next, carId, car);
      text = _t(
        '${seat.name} قطع $add ميلاً — ${car['miles']} ميل',
        '${seat.name} drove $add miles — ${car['miles']} miles',
      );
      if (car['miles'] == milesGoal) {
        return _arrive(
          next.copyWith(hands: hands, discard: discard, lastCard: card),
          carId: carId,
          seat: seat,
          sounds: sounds,
          text: text,
          random: random,
          nowMillis: nowMillis,
        );
      }
    }
  } else if (milesSafeties.contains(card)) {
    final car = milesCar(next, carId);
    _applySafety(car, card);
    car['score'] = _int(car['score']) + milesSafetyBonus;
    next = _setCar(next, carId, car);
    sounds.add('miles/$card');
    extraTurn = true;
    text = _t(
      '${seat.name} لعب ${milesCardLabel(card)} (+$milesSafetyBonus) — دور إضافي',
      '${seat.name} played ${milesCardLabel(card)} (+100) — extra turn',
    );
  } else if (milesRemedyCards.contains(card)) {
    final car = milesCar(next, carId);
    final faults = _faults(car);
    switch (card) {
      case 'green_light':
        faults.remove('red_light');
        car['go'] = true;
      case 'end_of_speed_limit':
        car['speedLimit'] = false;
      case 'end_of_counterflow':
        car['counterflow'] = false;
      default:
        // Gas / spare tire / repairs: the car stays stopped until green
        // (unless it holds Right of Way).
        final hazard = milesRemedies.entries
            .firstWhere((e) => e.value == card)
            .key;
        faults.remove(hazard);
        car['go'] = false;
    }
    car['faults'] = faults;
    next = _setCar(next, carId, car);
    discard.add(card);
    sounds.add('miles/$card');
    text = _t(
      '${seat.name} لعب ${milesCardLabel(card)}',
      '${seat.name} played ${milesCardLabel(card)}',
    );
  } else if (milesHazards.contains(card)) {
    final legal = milesLegalTargets(state, playerId, card);
    final target = targetId == null
        ? (legal.length == 1 ? legal.single : null)
        : milesCarOf(state, targetId);
    if (target == null) {
      return EngineResult(state, _t('اختر الهدف', 'Choose a target'));
    }
    final err = milesTargetError(state, playerId, target, card);
    if (err != null) return EngineResult(state, err);
    final car = milesCar(next, target);
    final before = Map<String, dynamic>.from(car);
    switch (card) {
      case 'speed_limit':
        car['speedLimit'] = true;
      case 'counterflow':
        car['counterflow'] = true;
      default:
        car['faults'] = [..._faults(car), card];
        car['go'] = false;
    }
    next = _setCar(next, target, car);
    discard.add(card);
    sounds.add('miles/$card');
    text = _t(
      '${seat.name} لعب ${milesCardLabel(card)} على ${milesCarName(state, target)}',
      '${seat.name} played ${milesCardLabel(card)} on ${milesCarName(state, target)}',
    );
    openCoup = {
      'carId': target,
      'hazard': card,
      'attackerId': playerId,
      'openedAt': nowMillis,
      'before': before,
    };
  }

  final nonce = state.nonce + 1;
  final turn = extraTurn
      ? state.turnIndex
      : (state.turnIndex + 1) % state.players.length;
  var result = next.copyWith(
    turnIndex: turn,
    hands: hands,
    discard: discard,
    lastCard: card,
    cue: SoundCue(type: 'miles', nonce: nonce, also: sounds),
    nonce: nonce,
    turnStartedAt: nowMillis,
    board: {...next.board, 'phase': 'draw', 'coup': openCoup, 'text': text},
  );
  // Only real coup chances keep the window open.
  if (openCoup != null && milesCoupHolders(result).isEmpty) {
    result = result.copyWith(board: {...result.board, 'coup': null});
  }
  return _afterTurn(result, random: random, nowMillis: nowMillis);
}

/// Skips players with nothing to do, ends the round by exhaustion, and
/// performs the automatic draw when enabled.
EngineResult _afterTurn(
  MatchState state, {
  required Random random,
  required int nowMillis,
}) {
  final settings = MilesSettings.of(state);
  final pileEmpty =
      state.deck.isEmpty &&
      (!settings.reshuffleDiscard ||
          state.discard.where((c) => !milesSafeties.contains(c)).isEmpty);
  if (pileEmpty) {
    final anyCards = state.hands.values.any((h) => h.isNotEmpty);
    if (!anyCards) {
      return _endRound(
        state,
        random: random,
        nowMillis: nowMillis,
        sounds: const ['miles/round_end'],
      );
    }
    // Pass the turn to the next player who still holds cards.
    var idx = state.turnIndex;
    for (var i = 0; i < state.players.length; i++) {
      final id = state.players[idx].id;
      if ((state.hands[id] ?? const []).isNotEmpty) break;
      idx = (idx + 1) % state.players.length;
    }
    return EngineResult(
      state.copyWith(turnIndex: idx, board: {...state.board, 'phase': 'play'}),
    );
  }
  if (settings.autoDraw && state.board['coup'] == null) {
    return EngineResult(_autoDrawFor(state, random, const []));
  }
  return EngineResult(state);
}

EngineResult _arrive(
  MatchState state, {
  required String carId,
  required Seat seat,
  required List<String> sounds,
  required String text,
  required Random random,
  required int nowMillis,
}) {
  final car = milesCar(state, carId);
  car['arrived'] = true;
  var bonus = milesArriveBonus;
  final parts = <String>[_t('الوصول +300', 'Trip complete +300')];
  if (state.deck.isEmpty) {
    bonus += milesDelayedBonus;
    parts.add(_t('التتويج +300', 'Delayed action +300'));
  }
  final others = [
    for (final id in milesCarIds(state))
      if (id != carId) id,
  ];
  if (others.every((id) => _int(milesCar(state, id)['miles']) == 0)) {
    bonus += milesShutoutBonus;
    parts.add(_t('الكنس +500', 'Shutout +500'));
  }
  if (_int(car['used200']) == 0) {
    bonus += milesNo200Bonus;
    parts.add(_t('بلا مئتين +300', 'Safe trip +300'));
  }
  car['score'] = _int(car['score']) + bonus;
  final next = _setCar(state, carId, car);
  return _endRound(
    next.copyWith(
      board: {
        ...next.board,
        'text': _t(
          '$text. وصل ${milesCarName(state, carId)} إلى الألف! ${parts.join('، ')}',
          '$text. ${milesCarName(state, carId)} reached 1000! ${parts.join(', ')}',
        ),
      },
    ),
    random: random,
    nowMillis: nowMillis,
    // Exactly 1000: the heavy Echo99 «exact 99» clip — only here.
    sounds: [...sounds, 'exact99', 'miles/round_end'],
  );
}

EngineResult _endRound(
  MatchState state, {
  required Random random,
  required int nowMillis,
  required List<String> sounds,
}) {
  final settings = MilesSettings.of(state);
  final scores = {
    for (final id in milesCarIds(state)) id: _int(milesCar(state, id)['score']),
  };
  final top = scores.values.fold<int>(-1 << 30, max);
  final text = '${state.board['text'] ?? ''}';
  if (top >= settings.scoreLimit) {
    String? winner;
    var best = -1 << 30;
    for (final e in scores.entries) {
      if (e.value > best) {
        best = e.value;
        winner = e.key;
      }
    }
    final nonce = state.nonce + 1;
    return EngineResult(
      state.copyWith(
        status: 'finished',
        winnerId: winner,
        cue: SoundCue(type: 'miles', nonce: nonce, also: sounds),
        nonce: nonce,
        turnStartedAt: nowMillis,
        board: {
          ...state.board,
          'phase': 'draw',
          'coup': null,
          'text': _t(
            '$text. انتهت المباراة — فاز ${milesCarName(state, winner!)} ($best نقطة)',
            '$text. Match over — ${milesCarName(state, winner)} wins ($best points)',
          ),
        },
      ),
    );
  }
  final dealt = _dealMilesRound(
    state,
    random: random,
    nowMillis: nowMillis,
    keepScores: true,
    leadSounds: sounds,
  );
  return EngineResult(
    dealt.state.copyWith(
      board: {
        ...dealt.state.board,
        'text': _t(
          '$text. انتهت الجولة. ${dealt.state.board['text']}',
          '$text. Round over. ${dealt.state.board['text']}',
        ),
      },
    ),
  );
}

// ---------------------------------------------------------------------------
// Bots.

class MilesBotMove {
  const MilesBotMove(this.card, {this.target, this.discard = false});
  final String card;
  final String? target;
  final bool discard;
}

MilesBotMove? chooseMilesBotMove(MatchState state, {String? forPlayer}) {
  final uid = forPlayer ?? state.current?.id;
  if (uid == null) return null;
  final open = milesCoupFor(state, uid);
  if (open != null) return MilesBotMove(open.safety);
  final hand = state.hands[uid] ?? const <String>[];
  if (hand.isEmpty) return null;
  bool ok(String c) => milesPlayError(state, uid, c) == null;
  final car = milesCar(state, milesCarOf(state, uid));
  // 1) fix own problems, 2) drive far, 3) attack the leader, 4) safeties
  // are kept for a coup fourré unless nothing else is useful.
  for (final c in hand) {
    if (milesRemedyCards.contains(c) && ok(c)) return MilesBotMove(c);
  }
  if (car['counterflow'] != true) {
    final drives = [
      for (final c in hand)
        if (milesDistances.containsKey(c) && ok(c)) c,
    ]..sort((a, b) => milesDistances[b]!.compareTo(milesDistances[a]!));
    if (drives.isNotEmpty) return MilesBotMove(drives.first);
  }
  for (final c in hand) {
    if (milesHazards.contains(c) && ok(c)) {
      final targets = milesLegalTargets(state, uid, c)
        ..sort(
          (a, b) =>
              _int(milesCar(state, b)['miles'])
                  .compareTo(_int(milesCar(state, a)['miles'])),
        );
      return MilesBotMove(c, target: targets.first);
    }
  }
  for (final c in hand) {
    if (milesSafeties.contains(c) && ok(c) && milesIsStopped(car)) {
      return MilesBotMove(c);
    }
  }
  // Discard: reversed distance cards first, then the least useful card.
  final discardOrder = [
    for (final c in hand)
      if (milesDistances.containsKey(c)) c,
    for (final c in hand)
      if (!milesDistances.containsKey(c) && !milesSafeties.contains(c)) c,
    ...hand,
  ];
  return MilesBotMove(discardOrder.first, discard: true);
}

/// Back-compat: the card only.
String? chooseMilesBotCard(MatchState state) => chooseMilesBotMove(state)?.card;

// ---------------------------------------------------------------------------
// Accessible text.

String _carStatus(MatchState state, String carId) {
  final car = milesCar(state, carId);
  final faults = _faults(car);
  final parts = <String>[
    _t('${car['miles']} ميل', '${car['miles']} miles'),
    if (faults.isNotEmpty)
      _t(
        'متوقفة: ${faults.map(milesCardLabel).join('، ')}',
        'Stopped: ${faults.map(milesCardLabel).join(', ')}',
      )
    else if (milesCanDrive(car))
      _t('تسير', 'Moving')
    else
      _t('واقفة — تحتاج الإشارة الخضراء', 'Stopped — needs Go'),
    if (car['speedLimit'] == true) _t('تحديد السرعة', 'Speed limit'),
    if (car['counterflow'] == true) _t('الاتجاه المعاكس', 'Wrong way'),
    if (_safeties(car).isNotEmpty)
      _t(
        'الحصانات: ${_safeties(car).map(milesCardLabel).join('، ')}',
        'Safeties: ${_safeties(car).map(milesCardLabel).join(', ')}',
      ),
    _t('ورقتا ٢٠٠ مستعملة: ${car['used200']}', '200s used: ${car['used200']}'),
    _t('النقاط ${car['score']}', '${car['score']} points'),
  ];
  return parts.join(milesEnglish ? ', ' : '، ');
}

/// «حالة سيارتي» — miles, hazards, limits (Left gesture).
String milesCarStateText(MatchState state, String uid) {
  if (!state.players.any((s) => s.id == uid)) {
    return _t('لست على الطاولة', 'You are not seated');
  }
  final carId = milesCarOf(state, uid);
  return '${_t('سيارتك', 'Your car')}: ${_carStatus(state, carId)}';
}

/// One car's status for the target picker / board list.
String milesCarLine(MatchState state, String carId) =>
    '${milesCarName(state, carId)}: ${_carStatus(state, carId)}';

/// «حالة كل السيارات وما تبقى في الكومة» (Right gesture).
String milesBoardText(MatchState state) {
  if (state.board['cars'] == null) {
    return _t('لم تبدأ ألف ميل بعد', 'Thousand Miles has not started');
  }
  return [
    for (final id in milesCarIds(state)) milesCarLine(state, id),
    _t(
      'الأوراق المتبقية في الكومة: ${state.deck.length}',
      'Cards left in the pile: ${state.deck.length}',
    ),
  ].join('. ');
}

String milesScoresText(MatchState state) {
  return [
    for (final id in milesCarIds(state))
      _t(
        '${milesCarName(state, id)}: ${milesCar(state, id)['score']} نقطة',
        '${milesCarName(state, id)}: ${milesCar(state, id)['score']} points',
      ),
    _t(
      'حد المباراة ${MilesSettings.of(state).scoreLimit}',
      'Match limit ${MilesSettings.of(state).scoreLimit}',
    ),
  ].join('. ');
}

String milesLastActionText(MatchState state) {
  final text = '${state.board['text'] ?? ''}';
  return text.isEmpty ? _t('لا توجد حركة بعد', 'No move yet') : text;
}

/// Hand labels. With «إخفاء الأوراق» every card except the last drawn one is
/// «ورقة مخفية N» (still playable / discardable).
List<String> milesHandLabels(MatchState state, String uid) {
  final hand = state.hands[uid] ?? const <String>[];
  if (!MilesSettings.of(state).hideHand) {
    return [for (final c in hand) milesCardLabel(c)];
  }
  final raw = state.board['lastDrawn'];
  final last = raw is Map ? '${raw[uid] ?? ''}' : '';
  final reveal = last.isEmpty ? -1 : hand.lastIndexOf(last);
  var hidden = 0;
  return [
    for (var i = 0; i < hand.length; i++)
      if (i == reveal)
        '${milesCardLabel(hand[i])} (${_t('آخر ورقة سحبتها', 'last drawn')})'
      else
        _t('ورقة مخفية ${++hidden}', 'Hidden card $hidden'),
  ];
}
