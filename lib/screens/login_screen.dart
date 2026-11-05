import 'package:flutter/material.dart';

import '../widgets/ar_button.dart';

class LoginScreen extends StatelessWidget {
  const LoginScreen({
    super.key,
    required this.busy,
    required this.error,
    required this.onGoogle,
    required this.onGuest,
  });

  final bool busy;
  final String? error;
  final VoidCallback onGoogle;
  final VoidCallback onGuest;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Echo99',
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.rtl,
                    style: TextStyle(
                      fontSize: 40,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFE8C872),
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'سجّل الدخول قبل القائمة',
                    textAlign: TextAlign.center,
                    textDirection: TextDirection.rtl,
                  ),
                  const SizedBox(height: 28),
                  ArButton(
                    label: 'تسجيل الدخول بحساب Google',
                    onPressed: busy ? null : onGoogle,
                  ),
                  const SizedBox(height: 12),
                  ArButton(
                    label: 'الدخول كضيف',
                    onPressed: busy ? null : onGuest,
                  ),
                  if (busy) ...[
                    const SizedBox(height: 20),
                    const Center(child: CircularProgressIndicator()),
                  ],
                  if (error != null && error!.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    Text(
                      error!,
                      textAlign: TextAlign.center,
                      textDirection: TextDirection.rtl,
                      style: const TextStyle(color: Color(0xFFE8C872)),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
