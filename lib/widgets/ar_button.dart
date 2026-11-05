import 'package:flutter/material.dart';

class ArButton extends StatelessWidget {
  const ArButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.outlined = false,
    this.fontSize = 18,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool outlined;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final child = Text(
      label,
      textDirection: TextDirection.rtl,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: fontSize),
    );
    final button = outlined
        ? OutlinedButton(
            style: OutlinedButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
            ),
            onPressed: onPressed,
            child: child,
          )
        : FilledButton(
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(56),
              backgroundColor: const Color(0xFF1F6B4A),
              foregroundColor: const Color(0xFFF8F1DE),
            ),
            onPressed: onPressed,
            child: child,
          );
    // One node: label + real tap action + enabled state (the old wrapper
    // excluded the button's own tap action from the semantics tree).
    return Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      label: label,
      onTap: onPressed,
      textDirection: TextDirection.rtl,
      child: ExcludeSemantics(child: button),
    );
  }
}

class ArTextButton extends StatelessWidget {
  const ArTextButton({super.key, required this.label, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      label: label,
      onTap: onPressed,
      textDirection: TextDirection.rtl,
      child: ExcludeSemantics(
        child: TextButton(
          onPressed: onPressed,
          child: Text(label, textDirection: TextDirection.rtl),
        ),
      ),
    );
  }
}
