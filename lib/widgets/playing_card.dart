import 'package:flutter/material.dart';

import '../game/rules.dart';
import 'game_gestures.dart';

class PlayingCardFace extends StatelessWidget {
  const PlayingCardFace({
    super.key,
    required this.card,
    this.selected = false,
    this.nameCards = true,
    this.labelOverride,
    this.onTap,
    this.onPlay,
  });

  final PlayingCard card;
  final bool selected;
  final bool nameCards;
  final String? labelOverride;
  final VoidCallback? onTap;
  final VoidCallback? onPlay;

  @override
  Widget build(BuildContext context) {
    final color = card.isRed
        ? const Color(0xFFB42318)
        : const Color(0xFF1C1917);
    final label = labelOverride ?? (nameCards ? card.englishName : card.arabicName);
    final play = onPlay ?? onTap;
    // ONE semantics node for the card image + its visible English name.
    // Activation is tap only (VoiceOver / TalkBack double-tap) — no swipe.
    return Semantics(
      container: true,
      button: true,
      enabled: play != null,
      label: label,
      textDirection: TextDirection.ltr,
      onTap: play,
      // Table gestures as actions on every card (rotor / actions menu).
      customSemanticsActions: GameActionsScope.of(context).isEmpty
          ? null
          : GameActionsScope.of(context),
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: play,
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                width: 78,
                height: 112,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected
                        ? const Color(0xFFE8C872)
                        : const Color(0xFFD6D3D1),
                    width: selected ? 3 : 1,
                  ),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x66000000),
                      blurRadius: 4,
                      offset: Offset(0, 2),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: CustomPaint(
                    painter: _CardPainter(card: card, ink: color),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                width: 86,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  textDirection: TextDirection.ltr,
                  maxLines: 2,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CardPainter extends CustomPainter {
  _CardPainter({required this.card, required this.ink});

  final PlayingCard card;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final face = Paint()..color = const Color(0xFFFFFBF5);
    canvas.drawRect(Offset.zero & size, face);
    final line = Paint()
      ..color = ink.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(4, 4, size.width - 8, size.height - 8),
        const Radius.circular(4),
      ),
      line,
    );
    _corner(canvas, size, ink, top: true);
    canvas.save();
    canvas.translate(size.width, size.height);
    canvas.rotate(3.14159);
    _corner(canvas, size, ink, top: false);
    canvas.restore();
    if (card.rank >= 11) {
      _court(canvas, size, ink);
    } else {
      _pips(canvas, size, ink);
    }
  }

  void _corner(Canvas canvas, Size size, Color ink, {required bool top}) {
    final rank = TextPainter(
      text: TextSpan(
        text: card.glyph,
        style: TextStyle(color: ink, fontSize: 14, fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final suit = TextPainter(
      text: TextSpan(
        text: card.suitSymbol,
        style: TextStyle(color: ink, fontSize: 12),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    rank.paint(canvas, const Offset(7, 6));
    suit.paint(canvas, const Offset(8, 20));
  }

  void _pips(Canvas canvas, Size size, Color ink) {
    final paint = TextPainter(
      text: TextSpan(
        text: card.suitSymbol,
        style: TextStyle(color: ink, fontSize: card.rank == 1 ? 36 : 16),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final spots = _spots(card.rank);
    for (final spot in spots) {
      final dx = size.width * spot.dx - paint.width / 2;
      final dy = size.height * spot.dy - paint.height / 2;
      canvas.save();
      if (spot.flip) {
        canvas.translate(dx + paint.width / 2, dy + paint.height / 2);
        canvas.rotate(3.14159);
        paint.paint(canvas, Offset(-paint.width / 2, -paint.height / 2));
      } else {
        paint.paint(canvas, Offset(dx, dy));
      }
      canvas.restore();
    }
  }

  void _court(Canvas canvas, Size size, Color ink) {
    final paint = Paint()..color = ink;
    final cx = size.width / 2;
    final cy = size.height / 2;
    canvas.drawCircle(Offset(cx, cy - 8), 10, paint);
    final body = Path()
      ..moveTo(cx - 16, cy + 28)
      ..lineTo(cx - 10, cy + 2)
      ..lineTo(cx + 10, cy + 2)
      ..lineTo(cx + 16, cy + 28)
      ..close();
    canvas.drawPath(body, Paint()..color = ink.withValues(alpha: 0.85));
    if (card.rank == 13) {
      canvas.drawCircle(Offset(cx - 12, cy - 16), 3, paint);
      canvas.drawCircle(Offset(cx + 12, cy - 16), 3, paint);
      canvas.drawLine(
        Offset(cx - 12, cy - 16),
        Offset(cx + 12, cy - 16),
        Paint()
          ..color = ink
          ..strokeWidth = 2,
      );
    } else if (card.rank == 12) {
      canvas.drawCircle(
        Offset(cx + 14, cy - 4),
        4,
        Paint()..color = const Color(0xFFE8C872),
      );
    }
    final letter = TextPainter(
      text: TextSpan(
        text: card.glyph,
        style: TextStyle(
          color: ink.withValues(alpha: 0.18),
          fontSize: 42,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    letter.paint(canvas, Offset(cx - letter.width / 2, cy - 6));
  }

  List<_Spot> _spots(int rank) {
    const mid = 0.50;
    const left = 0.30;
    const right = 0.70;
    const top = 0.34;
    const low = 0.66;
    const higher = 0.42;
    const lower = 0.58;
    switch (rank) {
      case 1:
        return const [_Spot(mid, mid, false)];
      case 2:
        return const [_Spot(mid, top, false), _Spot(mid, low, true)];
      case 3:
        return const [
          _Spot(mid, top, false),
          _Spot(mid, mid, false),
          _Spot(mid, low, true),
        ];
      case 4:
        return const [
          _Spot(left, top, false),
          _Spot(right, top, false),
          _Spot(left, low, true),
          _Spot(right, low, true),
        ];
      case 5:
        return const [
          _Spot(left, top, false),
          _Spot(right, top, false),
          _Spot(mid, mid, false),
          _Spot(left, low, true),
          _Spot(right, low, true),
        ];
      case 6:
        return const [
          _Spot(left, top, false),
          _Spot(right, top, false),
          _Spot(left, mid, false),
          _Spot(right, mid, false),
          _Spot(left, low, true),
          _Spot(right, low, true),
        ];
      case 7:
        return const [
          _Spot(left, top, false),
          _Spot(right, top, false),
          _Spot(mid, higher, false),
          _Spot(left, mid, false),
          _Spot(right, mid, false),
          _Spot(left, low, true),
          _Spot(right, low, true),
        ];
      case 8:
        return const [
          _Spot(left, top, false),
          _Spot(right, top, false),
          _Spot(mid, higher, false),
          _Spot(left, mid, false),
          _Spot(right, mid, false),
          _Spot(mid, lower, true),
          _Spot(left, low, true),
          _Spot(right, low, true),
        ];
      case 9:
        return const [
          _Spot(left, 0.30, false),
          _Spot(right, 0.30, false),
          _Spot(left, 0.46, false),
          _Spot(right, 0.46, false),
          _Spot(mid, mid, false),
          _Spot(left, 0.62, true),
          _Spot(right, 0.62, true),
          _Spot(left, 0.76, true),
          _Spot(right, 0.76, true),
        ];
      default:
        return const [
          _Spot(left, 0.28, false),
          _Spot(right, 0.28, false),
          _Spot(mid, 0.38, false),
          _Spot(left, 0.46, false),
          _Spot(right, 0.46, false),
          _Spot(left, 0.60, true),
          _Spot(right, 0.60, true),
          _Spot(mid, 0.68, true),
          _Spot(left, 0.78, true),
          _Spot(right, 0.78, true),
        ];
    }
  }

  @override
  bool shouldRepaint(covariant _CardPainter oldDelegate) =>
      oldDelegate.card != card;
}

class _Spot {
  const _Spot(this.dx, this.dy, this.flip);
  final double dx;
  final double dy;
  final bool flip;
}
