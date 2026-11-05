import 'package:flutter/material.dart';

import '../echo_scope.dart';
import '../services/doc_id.dart';

/// Tap a player's name → profile with «إرسال طلب صداقة» and «رسالة خاصة».
/// Friend requests and messages live in Firestore (users/{uid}/...).
Future<void> showProfileDialog(
  BuildContext context, {
  required String uid,
  required String name,
  bool isBot = false,
}) async {
  final scope = EchoScope.of(context);
  final me = scope.settings.playerId;
  final social = scope.social;
  final canSocial =
      !isBot &&
      uid != me &&
      social != null &&
      isSafeDocId(uid) &&
      isSafeDocId(me) &&
      !scope.account.guest;
  final messenger = ScaffoldMessenger.of(context);
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: Text(name, textDirection: TextDirection.rtl),
        content: Text(
          isBot
              ? 'بوت'
              : uid == me
              ? 'هذا أنت'
              : canSocial
              ? 'الملف الشخصي'
              : 'الميزات الاجتماعية تحتاج تسجيل الدخول بحساب Google',
          textDirection: TextDirection.rtl,
        ),
        actions: [
          if (canSocial) ...[
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                try {
                  await social.sendFriendRequest(
                    fromUid: me,
                    fromName: scope.settings.displayName,
                    toUid: uid,
                  );
                  await scope.sounds.play('friend_request');
                  messenger.showSnackBar(
                    SnackBar(content: Text('أُرسل طلب الصداقة إلى $name')),
                  );
                } catch (_) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('تعذر إرسال طلب الصداقة')),
                  );
                }
              },
              child: const Text('إرسال طلب صداقة'),
            ),
            TextButton(
              onPressed: () async {
                Navigator.of(dialogContext).pop();
                final text = await showDialog<String>(
                  context: context,
                  builder: (_) => PrivateMessageDialog(to: name),
                );
                if (text == null || text.trim().isEmpty) {
                  return;
                }
                try {
                  await social.sendPrivateMessage(
                    fromUid: me,
                    toUid: uid,
                    fromName: scope.settings.displayName,
                    text: text,
                  );
                  await scope.sounds.play('dm');
                  messenger.showSnackBar(
                    SnackBar(content: Text('أُرسلت الرسالة إلى $name')),
                  );
                } catch (_) {
                  messenger.showSnackBar(
                    const SnackBar(content: Text('تعذر إرسال الرسالة')),
                  );
                }
              },
              child: const Text('رسالة خاصة'),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('إغلاق'),
          ),
        ],
      );
    },
  );
}

class PrivateMessageDialog extends StatefulWidget {
  const PrivateMessageDialog({super.key, required this.to});

  final String to;

  @override
  State<PrivateMessageDialog> createState() => _PrivateMessageDialogState();
}

class _PrivateMessageDialogState extends State<PrivateMessageDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(
        'رسالة خاصة إلى ${widget.to}',
        textDirection: TextDirection.rtl,
      ),
      content: TextField(
        controller: _controller,
        autofocus: true,
        textDirection: TextDirection.rtl,
        decoration: const InputDecoration(labelText: 'النص'),
        onSubmitted: (value) => Navigator.of(context).pop(value.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('إلغاء'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: const Text('إرسال'),
        ),
      ],
    );
  }
}
