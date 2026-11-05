import 'package:flutter/material.dart';

import '../widgets/ar_button.dart';

class MenuScreen extends StatelessWidget {
  const MenuScreen({
    super.key,
    required this.onCreate,
    required this.onJoin,
    required this.onSettings,
    required this.onOnline,
    required this.onFriends,
    required this.onLatency,
    required this.latencyLabel,
    this.notice,
    this.onNotice,
    this.noticeAction,
  });

  final VoidCallback onCreate;
  final VoidCallback onJoin;
  final VoidCallback onSettings;
  final VoidCallback onOnline;
  final VoidCallback onFriends;
  final VoidCallback onLatency;
  final String latencyLabel;

  /// Non-blocking Arabic note, e.g. voice chat unavailable. Tables still work.
  final String? notice;
  final VoidCallback? onNotice;
  final String? noticeAction;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: ListView(
              padding: const EdgeInsets.all(24),
              shrinkWrap: true,
              children: [
                const Text(
                  'Echo99',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 40,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFFE8C872),
                  ),
                ),
                const SizedBox(height: 20),
                // Quick menu before creating a table.
                Semantics(
                  container: true,
                  label: 'القائمة السريعة',
                  explicitChildNodes: true,
                  child: Row(
                    children: [
                      Expanded(
                        child: ArButton(
                          label: 'الإعدادات',
                          onPressed: onSettings,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ArButton(
                          label: 'المتصلون',
                          onPressed: onOnline,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: ArButton(
                          label: 'الأصدقاء',
                          onPressed: onFriends,
                          fontSize: 16,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                ArButton(
                  label: 'إنشاء طاولة',
                  onPressed: onCreate,
                  fontSize: 20,
                ),
                const SizedBox(height: 12),
                ArButton(
                  label: 'الانضمام إلى طاولة',
                  onPressed: onJoin,
                  fontSize: 20,
                ),
                const SizedBox(height: 12),
                ArButton(
                  label: latencyLabel,
                  onPressed: onLatency,
                  fontSize: 20,
                ),
                if (notice != null) ...[
                  const SizedBox(height: 16),
                  Semantics(
                    liveRegion: true,
                    textDirection: TextDirection.rtl,
                    child: Text(
                      notice!,
                      key: const Key('menu_notice'),
                      textAlign: TextAlign.center,
                      textDirection: TextDirection.rtl,
                      style: const TextStyle(color: Color(0xFFFFD58A)),
                    ),
                  ),
                  if (onNotice != null && noticeAction != null) ...[
                    const SizedBox(height: 8),
                    ArButton(
                      label: noticeAction!,
                      onPressed: onNotice!,
                      fontSize: 18,
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
