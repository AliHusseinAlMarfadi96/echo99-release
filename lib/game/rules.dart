class PlayingCard {
  const PlayingCard(this.suit, this.rank);

  final String suit;
  final int rank;

  String get code => '$suit$rank';

  bool get isRed => suit == 'H' || suit == 'D';

  String get glyph {
    const names = {1: 'A', 11: 'J', 12: 'Q', 13: 'K'};
    return names[rank] ?? '$rank';
  }

  String get suitSymbol {
    switch (suit) {
      case 'H':
        return '♥';
      case 'D':
        return '♦';
      case 'C':
        return '♣';
      default:
        return '♠';
    }
  }

  String get arabicSuit {
    switch (suit) {
      case 'H':
        return 'قلوب';
      case 'D':
        return 'ديناري';
      case 'C':
        return 'سياطي';
      default:
        return 'بستون';
    }
  }

  String get arabicRank {
    const names = {1: 'آس', 11: 'ولد', 12: 'بنت', 13: 'شايب'};
    return names[rank] ?? '$rank';
  }

  String get arabicName => '$arabicRank $arabicSuit';

  static const _easternDigits = {
    '0': '٠',
    '1': '١',
    '2': '٢',
    '3': '٣',
    '4': '٤',
    '5': '٥',
    '6': '٦',
    '7': '٧',
    '8': '٨',
    '9': '٩',
  };

  /// Western digits → Eastern Arabic digits (٥, ١٠, …).
  static String easternDigits(String raw) {
    final buffer = StringBuffer();
    for (final ch in raw.split('')) {
      buffer.write(_easternDigits[ch] ?? ch);
    }
    return buffer.toString();
  }

  String get englishSuit {
    switch (suit) {
      case 'H':
        return 'Hearts';
      case 'D':
        return 'Diamonds';
      case 'C':
        return 'Clubs';
      default:
        return 'Spades';
    }
  }

  String get englishRank {
    const faces = {1: 'Ace', 11: 'Jack', 12: 'Queen', 13: 'King'};
    return faces[rank] ?? '$rank';
  }

  /// English suit/rank with Eastern Arabic digits for numeric ranks.
  /// e.g. «٥ of Clubs», «Jack of Spades».
  String get englishName => '$englishRank of $englishSuit';
  
  /// Cards are always named in English («Queen of Hearts»), whatever the
  /// legacy «تسمية البطاقات» toggle says.
    String displayName({bool nameCards = false}) => nameCards ? englishName : arabicName;

  static PlayingCard? parse(String? code) {
    if (code == null || code.length < 2) {
      return null;
    }
    final suit = code[0];
    final rank = int.tryParse(code.substring(1));
    if (rank == null || rank < 1 || rank > 13 || !'SHDC'.contains(suit)) {
      return null;
    }
    return PlayingCard(suit, rank);
  }

  static List<PlayingCard> freshDeck() {
    const suits = ['S', 'H', 'D', 'C'];
    return [
      for (final suit in suits)
        for (var rank = 1; rank <= 13; rank++) PlayingCard(suit, rank),
    ];
  }
}

class Resolution {
  const Resolution({
    required this.nextTotal,
    required this.actorLoss,
    required this.othersLoss,
    required this.roundEnded,
    required this.outcome,
    required this.reversed,
    required this.skipsNext,
  });

  final int nextTotal;
  final int actorLoss;
  final int othersLoss;
  final bool roundEnded;
  final String outcome;
  final bool reversed;
  final bool skipsNext;
}

int appliedTotal(int current, int rank, {int? choice}) {
  switch (rank) {
    case 1:
      return current + (choice == 11 ? 11 : 1);
    case 2:
      if (current % 2 == 0 && current > 49) {
        return current ~/ 2;
      }
      return current * 2;
    case 9:
      return current;
    case 10:
      return current + (choice == -10 ? -10 : 10);
    case 11:
    case 12:
    case 13:
      return current + 10;
    default:
      return current + rank;
  }
}

Resolution resolvePlay({
  required int before,
  required int after,
  required int rank,
  required int activePlayers,
}) {
  final reversed = rank == 4 && activePlayers > 2;
  final skips = rank == 11;
  // TableEx / qcsalon-style 99: hitting exactly 33 or 66 awards a point
  // penalty to everyone else, but the pile keeps accumulating. Only exact
  // 99 (or a bust above 99) resets the running total for a new deal.
  if ((after == 33 || after == 66 || after == 99) && after > before) {
    final exact99 = after == 99;
    return Resolution(
      nextTotal: exact99 ? 0 : after,
      actorLoss: 0,
      othersLoss: exact99 ? 2 : 1,
      roundEnded: exact99,
      outcome: exact99
          ? 'exact99'
          : after == 66
          ? 'exact66'
          : 'exact33',
      reversed: reversed,
      skipsNext: skips,
    );
  }
  if (after > before) {
    var loss = 0;
    if (before <33 && after > 33) {
      loss += 1;
    }
    if (before < 66 && after > 66) {
      loss += 1;
    }
    if (after > 99) {
      loss += 2;
      return Resolution(
        nextTotal: 0,
        actorLoss: loss,
        othersLoss: 0,
        roundEnded: true,
        outcome: 'bust',
        reversed: reversed,
        skipsNext: skips,
      );
    }
    if (loss > 0) {
      return Resolution(
        nextTotal: after,
        actorLoss: loss,
        othersLoss: 0,
        roundEnded: false,
        outcome: 'band',
        reversed: reversed,
        skipsNext: skips,
      );
    }
  }
  return Resolution(
    nextTotal: after,
    actorLoss: 0,
    othersLoss: 0,
    roundEnded: false,
    outcome: 'neutral',
    reversed: reversed,
    skipsNext: skips,
  );
}

String spokenValue({
  required int rank,
  required int before,
  required int after,
  int? choice,
}) {
  switch (rank) {
    case 1:
      return choice == 11 ? '11' : '1';
    case 2:
      return after < before ? 'نصف' : 'ضعف';
    case 9:
      return '0';
    case 10:
      return choice == -10 ? '-10' : '10';
    case 11:
    case 12:
    case 13:
      return '10';
    default:
      return '$rank';
  }
}

String playSpeech(String name, String value, int score) {
  return '$name لعب $value، المجموع أصبح $score';
}

/// Pure leave policy for Firestore tables (no onDisconnect on Firestore).
enum TableLeaveAction { removeSelf, deleteTable }

TableLeaveAction tableLeaveAction({
  required String hostId,
  required String playerId,
}) {
  if (hostId.isEmpty || playerId.isEmpty) {
    return TableLeaveAction.removeSelf;
  }
  return playerId == hostId
      ? TableLeaveAction.deleteTable
      : TableLeaveAction.removeSelf;
}

const playerCountError = 'تتطلب هذه اللعبة من 2 إلى 10 لاعبين';
const teamsCountError = 'الفرق متاحة فقط مع 4 أو 6 أو 8 أو 10 لاعبين';
const timerError = 'مدة مؤقت الدور 10 ثوانٍ على الأقل';
const startPointsError = 'نقاط البداية يجب أن تكون رقماً من 1 إلى 99';
const minStartPoints = 1;
const maxStartPoints = 99;
const minTimerSeconds = 10;
const defaultStartPoints = 10;

List<int?> choicesForRank(int rank) {
  if (rank == 1) {
    return const [1, 11];
  }
  if (rank == 10) {
    return const [10, -10];
  }
  return const [null];
}

int botRankScore({
  required int before,
  required int after,
  required Resolution resolution,
  required int rank,
  required int activePlayers,
}) {
  var score = switch (resolution.outcome) {
    'exact99' => 10000,
    'exact66' => 8000,
    'exact33' => 7000,
    'bust' => -5000 - resolution.actorLoss * 100,
    'band' => -1000 - resolution.actorLoss * 100,
    _ =>
      after < before
          ? 80 + after
          : after == before
          ? 40
          : after < (before < 33 ? 33 : (before < 66 ? 66 : 99))
          ? 200 + after
          : 20,
  };
  const keepers = {1, 2, 4, 10, 11};
  final keeper = keepers.contains(rank) && !(rank == 4 && activePlayers <= 2);
  if (keeper && !resolution.outcome.startsWith('exact')) {
    score -= 35;
  }
  return score;
}
