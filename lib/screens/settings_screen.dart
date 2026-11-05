import 'package:flutter/material.dart';

import '../echo_scope.dart';
import '../services/doc_id.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  TextEditingController? _name;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _name ??= TextEditingController(text: EchoScope.of(context).settings.name);
  }

  @override
  void dispose() {
    _name?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final settings = EchoScope.of(context).settings;
    return Scaffold(
      appBar: AppBar(
        title: const Text('الإعدادات'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: 'رجوع',
          onPressed: () => Navigator.of(context).maybePop(),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'الاسم'),
            onChanged: (value) {
              settings.setName(value);
            },
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('إعلان اللعبات'),
            value: settings.speakPlays,
            onChanged: (value) {
              settings.setSpeakPlays(value);
            },
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('استخدام الناطق الداخلي'),
            subtitle: const Text(
              'افتراضياً متوقف — يعتمد التطبيق على TalkBack / VoiceOver',
            ),
            value: settings.useInternalTts,
            onChanged: (value) {
              settings.setUseInternalTts(value);
            },
          ),
                 SwitchListTile(
            title: const Text('لغة نطق الكروت (الإنجليزية / العربية)'),
            subtitle: const Text(
              'عند التفعيل: رقم الكرت ثم اسمه بالإنجليزية (مثل 10 of Diamonds). وعند الإيقاف: بالعربية (مثل 10 الديناري).',
            ),
            value: settings.nameCards,
            onChanged: (v) => settings.setNameCards(v),
                    ),
          const SizedBox(height: 8),
          const Text('تحكم بسرعة البوت'),
          Slider(
            value: settings.botMillis.toDouble(),
            min: 400,
            max: 3000,
            label: 'تحكم بسرعة البوت',
            onChanged: (value) => settings.setBotMillis(value.round()),
          ),
          const SizedBox(height: 24),
          OutlinedButton(
            onPressed: () async {
              final scope = EchoScope.of(context);
              final uid = scope.settings.playerId;
              final social = scope.social;
              if (social != null && isSafeDocId(uid)) {
                try {
                  await social.setOnline(
                    uid: uid,
                    name: scope.settings.displayName,
                    online: false,
                  );
                } catch (_) {}
              }
              await scope.account.signOut();
              if (context.mounted) {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            child: const Text('تسجيل الخروج', textDirection: TextDirection.rtl),
          ),
        ],
      ),
    );
  }
}
