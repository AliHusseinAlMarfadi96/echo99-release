import 'package:flutter/material.dart';

import 'mic_gestures.dart';

/// The ONLY place mic gestures live: swipe up = on, swipe down = off,
/// long-press or tap = toggle. The rest of the table never listens for
/// mic gestures, so cards and actions keep their own taps.
class MicPad extends StatelessWidget {
  const MicPad({
    super.key,
    required this.micOn,
    required this.onMicOn,
    required this.onMicOff,
    required this.onToggle,
  });

  final bool micOn;
  final VoidCallback onMicOn;
  final VoidCallback onMicOff;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final label = micOn ? 'الميكروفون مفتوح' : 'الميكروفون مغلق';
    return Semantics(
      container: true,
      button: true,
      enabled: true,
      toggled: micOn,
      label: label,
      hint: 'اضغط للتبديل، أو اسحب لأعلى للفتح ولأسفل للإغلاق',
      onTap: onToggle,
      excludeSemantics: true,
      child: MicGestures(
        onMicOn: onMicOn,
        onMicOff: onMicOff,
        onToggle: onToggle,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          child: Container(
            key: const Key('mic_pad'),
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              color: micOn ? const Color(0xFF2E7D32) : const Color(0xFF3A3A3A),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(micOn ? Icons.mic : Icons.mic_off, color: Colors.white),
                const SizedBox(width: 8),
                Text(label, style: const TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
