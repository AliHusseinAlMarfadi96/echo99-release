import 'package:flutter/material.dart';

import '../echo_scope.dart';
import '../widgets/ar_button.dart';
import '../widgets/profile_dialog.dart';
import '../services/doc_id.dart';
import '../services/social_repository.dart';

class FriendsScreen extends StatelessWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final scope = EchoScope.of(context);
    final social = scope.social;
    final uid = scope.settings.playerId;
    if (social == null || !isSafeDocId(uid)) {
      return Scaffold(
        appBar: AppBar(title: const Text('الأصدقاء')),
        body: const Center(child: Text('تعذر الاتصال بـ Firestore')),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('الأصدقاء')),
      body: Column(
        children: [
          StreamBuilder<List<FriendRequest>>(
            stream: social.watchFriendRequestList(uid),
            builder: (context, snapshot) {
              final requests = snapshot.data ?? const <FriendRequest>[];
              if (requests.isEmpty) {
                return const SizedBox.shrink();
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'طلبات الصداقة',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ),
                  for (final request in requests)
                    ListTile(
                      title: Text('طلب صداقة من ${request.name}'),
                      trailing: Wrap(
                        spacing: 8,
                        children: [
                          ArTextButton(
                            label: 'قبول',
                            onPressed: () async {
                              try {
                                await social.acceptFriendRequest(
                                  uid: uid,
                                  name: scope.settings.displayName,
                                  fromUid: request.fromUid,
                                  fromName: request.name,
                                );
                                await scope.sounds.play('friend_on');
                              } catch (_) {
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text('تعذر قبول الطلب'),
                                    ),
                                  );
                                }
                              }
                            },
                          ),
                          ArTextButton(
                            label: 'رفض',
                            onPressed: () => social.declineFriendRequest(
                              uid: uid,
                              fromUid: request.fromUid,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const Divider(),
                ],
              );
            },
          ),
          Expanded(
            child: StreamBuilder<List<Friend>>(
              stream: social.watchFriends(uid),
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Center(child: Text('تعذر الاتصال بـ Firestore'));
                }
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final friends = snapshot.data!;
                if (friends.isEmpty) {
                  return const Center(child: Text('لا يوجد أصدقاء بعد'));
                }
                return ListView.separated(
                  itemCount: friends.length,
                  separatorBuilder: (_, _) => const Divider(height: 1),
                  itemBuilder: (context, index) {
                    final friend = friends[index];
                    return ListTile(
                      title: Text(friend.name),
                      onTap: () => showProfileDialog(
                        context,
                        uid: friend.uid,
                        name: friend.name,
                      ),
                      trailing: ArTextButton(
                        label: 'إزالة',
                        onPressed: () =>
                            social.unfollow(uid: uid, friendUid: friend.uid),
                      ),
                    );
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
