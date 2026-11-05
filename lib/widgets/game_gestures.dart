import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/semantics.dart';
import 'package:flutter/widgets.dart';

/// The four table gestures, identical in every game.
enum GameSwipe { up, down, left, right }

/// Pure multi-finger swipe recogniser (testable without a device).
///
/// * Sighted users / VoiceOver off: two or more fingers moving together.
/// * Android TalkBack passes a two-finger drag through to the app as a
///   **single** synthetic pointer (its touch explorer injects the midpoint),
///   so when a screen reader is running ([screenReader]) a quick single-
///   pointer swipe that starts moving right away is also accepted. A
///   TalkBack «double-tap and hold then drag» starts with a hold, which is
///   rejected by [maxHoldMs].
class SwipeTracker {
  SwipeTracker({
    this.minDistance = 48,
    this.maxDurationMs = 1200,
    this.maxHoldMs = 350,
  });

  final double minDistance;
  final int maxDurationMs;
  final int maxHoldMs;

  final Map<int, Offset> _start = {};
  final Map<int, Offset> _last = {};
  int _maxPointers = 0;
  int _downAt = 0;
  int? _firstMoveAt;

  void down(int pointer, Offset position, int atMs) {
    if (_start.isEmpty) {
      _maxPointers = 0;
      _downAt = atMs;
      _firstMoveAt = null;
    }
    _start[pointer] = position;
    _last[pointer] = position;
    if (_start.length > _maxPointers) _maxPointers = _start.length;
  }

  void move(int pointer, Offset position, int atMs) {
    if (!_start.containsKey(pointer)) return;
    _last[pointer] = position;
    if (_firstMoveAt == null && (position - _start[pointer]!).distance > 8) {
      _firstMoveAt = atMs;
    }
  }

  void cancel(int pointer) {
    // A cancelled pointer invalidates the whole multi-touch gesture. Keeping
    // the other pointers or completed deltas can make the next gesture fire
    // using stale coordinates, so reset all per-gesture state atomically.
    _start.clear();
    _last.clear();
    _done.clear();
    _maxPointers = 0;
    _downAt = 0;
    _firstMoveAt = null;
  }

  /// Returns a swipe when the last finger lifts and the gesture qualifies.
  GameSwipe? up(
    int pointer,
    Offset position,
    int atMs, {
    required bool screenReader,
  }) {
    if (!_start.containsKey(pointer)) return null;
    _last[pointer] = position;
    final start = Map<int, Offset>.from(_start);
    final last = Map<int, Offset>.from(_last);
    _start.remove(pointer);
    _last.remove(pointer);
    if (_start.isNotEmpty) {
      // Wait for every finger; remember this finger's travel.
      _done[pointer] = last[pointer]! - start[pointer]!;
      return null;
    }
    _done[pointer] = last[pointer]! - start[pointer]!;
    final deltas = _done.values.toList();
    _done.clear();
    final fingers = _maxPointers;
    _maxPointers = 0;
    if (atMs - _downAt > maxDurationMs) return null;
    if (fingers < 2) {
      if (!screenReader) return null;
      final moved = _firstMoveAt;
      if (moved == null || moved - _downAt > maxHoldMs) return null;
    }
    var dx = 0.0, dy = 0.0;
    for (final d in deltas) {
      dx += d.dx;
      dy += d.dy;
    }
    dx /= deltas.length;
    dy /= deltas.length;
    if (dx.abs() < minDistance && dy.abs() < minDistance) return null;
    if (dy.abs() >= dx.abs()) {
      return dy < 0 ? GameSwipe.up : GameSwipe.down;
    }
    return dx < 0 ? GameSwipe.left : GameSwipe.right;
  }

  final Map<int, Offset> _done = {};
}

/// Actions every focusable game element exposes (VoiceOver rotor «Actions»,
/// TalkBack actions menu). Provided by [GameGestureSurface].
class GameActionsScope extends InheritedWidget {
  const GameActionsScope({
    super.key,
    required this.actions,
    required super.child,
  });

  final Map<CustomSemanticsAction, VoidCallback> actions;

  static Map<CustomSemanticsAction, VoidCallback> of(BuildContext context) {
    return context
            .dependOnInheritedWidgetOfExactType<GameActionsScope>()
            ?.actions ??
        const {};
  }

  @override
  bool updateShouldNotify(GameActionsScope oldWidget) =>
      oldWidget.actions != actions;
}

bool get _isAndroid {
  if (kIsWeb) return false;
  try {
    return Platform.isAndroid;
  } catch (_) {
    return false;
  }
}

/// Wraps the whole game screen.
///
/// iOS VoiceOver: a three-finger swipe calls `accessibilityScroll:` on the
/// focused element and then on each enclosing container. Flutter's engine
/// (SemanticsObject.mm, GetSemanticsActionForScrollDirection) converts the
/// UIKit direction back to the **finger** direction, so a physical swipe up
/// arrives as [SemanticsAction.scrollUp], left as scrollLeft, etc. This node
/// owns those four scroll actions, so whatever game element has focus, the
/// swipe bubbles up to here. Nothing between the elements and this node may
/// be a semantic scrollable (see [GameScrollBody]).
///
/// Android TalkBack: two-finger swipes reach the app as raw touches and are
/// recognised by [SwipeTracker]; the same scroll actions are also exposed.
///
/// Every action is also a [CustomSemanticsAction] (rotor / actions menu) on
/// this node and — through [GameActionsScope] — on every game element.
class GameGestureSurface extends StatefulWidget {
  const GameGestureSurface({
    super.key,
    required this.onSwipe,
    required this.actions,
    required this.child,
    this.label,
    this.hint,
  });

  final void Function(GameSwipe swipe) onSwipe;
  final Map<CustomSemanticsAction, VoidCallback> actions;
  final Widget child;
  final String? label;
  final String? hint;

  @override
  State<GameGestureSurface> createState() => _GameGestureSurfaceState();
}

class _GameGestureSurfaceState extends State<GameGestureSurface> {
  final _tracker = SwipeTracker();
  int _lastFireAt = 0;
  GameSwipe? _lastFireSwipe;
  bool? _lastFireWasSemantic;

  void _fire(GameSwipe swipe, {required bool semantic}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    // Suppress only the duplicate path for one physical gesture. Do not drop
    // two deliberate VoiceOver/TalkBack actions just because they occur
    // within the old 400 ms global debounce window.
    if (_lastFireSwipe == swipe &&
        _lastFireWasSemantic != null &&
        _lastFireWasSemantic != semantic &&
        now - _lastFireAt < 400) {
      return;
    }
    _lastFireAt = now;
    _lastFireSwipe = swipe;
    _lastFireWasSemantic = semantic;
    widget.onSwipe(swipe);
  }

  int get _now => DateTime.now().millisecondsSinceEpoch;

  @override
  Widget build(BuildContext context) {
    final screenReader =
        _isAndroid && MediaQuery.maybeAccessibleNavigationOf(context) == true;
    return GameActionsScope(
      actions: widget.actions,
      child: Semantics(
        container: true,
        explicitChildNodes: true,
        label: widget.label,
        hint: widget.hint,
        onScrollUp: () => _fire(GameSwipe.up, semantic: true),
        onScrollDown: () => _fire(GameSwipe.down, semantic: true),
        onScrollLeft: () => _fire(GameSwipe.left, semantic: true),
        onScrollRight: () => _fire(GameSwipe.right, semantic: true),
        customSemanticsActions: widget.actions,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (e) => _tracker.down(e.pointer, e.position, _now),
          onPointerMove: (e) => _tracker.move(e.pointer, e.position, _now),
          onPointerCancel: (e) => _tracker.cancel(e.pointer),
          onPointerUp: (e) {
            final swipe = _tracker.up(
              e.pointer,
              e.position,
              _now,
              screenReader: screenReader,
            );
            if (swipe != null) _fire(swipe, semantic: false);
          },
          child: widget.child,
        ),
      ),
    );
  }
}

/// Scrollable body that is NOT a semantic scrollable, so VoiceOver's
/// three-finger swipes bubble past it to [GameGestureSurface].
class GameScrollBody extends StatelessWidget {
  const GameScrollBody({super.key, required this.child, this.padding});

  final Widget child;
  final EdgeInsets? padding;

  @override
  Widget build(BuildContext context) {
    return Scrollable(
      excludeFromSemantics: true,
      axisDirection: AxisDirection.down,
      viewportBuilder: (context, offset) => Viewport(
        offset: offset,
        slivers: [
          SliverFillRemaining(
            hasScrollBody: false,
            child: Padding(
              padding: padding ?? EdgeInsets.zero,
              child: Align(alignment: Alignment.bottomCenter, child: child),
            ),
          ),
        ],
      ),
    );
  }
}

/// One focusable game element (piece, card, target, button): its own
/// semantic node with a full label, tap / long-press, and the table actions.
class GameNode extends StatelessWidget {
  const GameNode({
    super.key,
    required this.label,
    required this.child,
    this.hint,
    this.onTap,
    this.onLongPress,
    this.button = true,
    this.selected,
    this.extraActions = const {},
    this.textDirection,
  });

  final String label;
  final String? hint;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool button;
  final bool? selected;
  final Map<CustomSemanticsAction, VoidCallback> extraActions;
  final Widget child;
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) {
    final actions = {...GameActionsScope.of(context), ...extraActions};
    return Semantics(
      container: true,
      button: button,
      enabled: button ? onTap != null : null,
      selected: selected,
      label: label,
      hint: hint,
      textDirection: textDirection,
      onTap: onTap,
      onLongPress: onLongPress,
      customSemanticsActions: actions.isEmpty ? null : actions,
      excludeSemantics: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        onLongPress: onLongPress,
        child: child,
      ),
    );
  }
}
