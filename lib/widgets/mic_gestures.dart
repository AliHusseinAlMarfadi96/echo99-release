import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';

/// Vertical swipe up/down or long-press to toggle mic.
///
/// Uses [RawGestureDetector] with a custom long-press that does **not** claim
/// the arena for short taps, so playing-card onTap / VoiceOver double-tap
/// still fire. Vertical drag is claimed only after a clear vertical move.
class MicGestures extends StatelessWidget {
  const MicGestures({
    super.key,
    required this.onMicOn,
    required this.onMicOff,
    required this.onToggle,
    required this.child,
  });

  final VoidCallback onMicOn;
  final VoidCallback onMicOff;
  final VoidCallback onToggle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return RawGestureDetector(
      behavior: HitTestBehavior.translucent,
      gestures: <Type, GestureRecognizerFactory>{
        LongPressGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<LongPressGestureRecognizer>(
              () => LongPressGestureRecognizer(
                duration: const Duration(milliseconds: 550),
              ),
              (instance) {
                instance.onLongPress = onToggle;
              },
            ),
        _VerticalMicDragGestureRecognizer:
            GestureRecognizerFactoryWithHandlers<
              _VerticalMicDragGestureRecognizer
            >(_VerticalMicDragGestureRecognizer.new, (instance) {
              instance.onMicOn = onMicOn;
              instance.onMicOff = onMicOff;
            }),
      },
      child: child,
    );
  }
}

class _VerticalMicDragGestureRecognizer extends OneSequenceGestureRecognizer {
  VoidCallback? onMicOn;
  VoidCallback? onMicOff;

  Offset? _start;
  var _fired = false;

  @override
  void addPointer(PointerDownEvent event) {
    startTrackingPointer(event.pointer);
    _start = event.position;
    _fired = false;
  }

  @override
  void handleEvent(PointerEvent event) {
    if (_start == null || _fired) {
      return;
    }
    if (event is PointerMoveEvent) {
      final delta = event.position - _start!;
      // Require dominant vertical travel before claiming — leave room for
      // taps and horizontal card interactions.
      if (delta.dy.abs() < 48 || delta.dy.abs() <= delta.dx.abs()) {
        return;
      }
      _fired = true;
      resolve(GestureDisposition.accepted);
      if (delta.dy < 0) {
        onMicOn?.call();
      } else {
        onMicOff?.call();
      }
      stopTrackingPointer(event.pointer);
      return;
    }
    if (event is PointerUpEvent || event is PointerCancelEvent) {
      resolve(GestureDisposition.rejected);
      stopTrackingPointer(event.pointer);
      _start = null;
    }
  }

  @override
  void acceptGesture(int pointer) {}

  @override
  void rejectGesture(int pointer) {
    stopTrackingPointer(pointer);
    _start = null;
  }

  @override
  void didStopTrackingLastPointer(int pointer) {
    _start = null;
  }

  @override
  String get debugDescription => 'vertical_mic_drag';
}
