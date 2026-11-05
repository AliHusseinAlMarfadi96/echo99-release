import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ForceUpdateScreen extends StatelessWidget {
  const ForceUpdateScreen({
    super.key,
    required this.androidUrl,
    required this.iosUrl,
  });

  final String androidUrl;
  final String iosUrl;

  Future<void> _open() async {
    final raw = defaultTargetPlatform == TargetPlatform.iOS
        ? iosUrl
        : androidUrl;
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme) {
      return;
    }
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: Scaffold(
        body: SafeArea(
          child: Center(
            child: Semantics(
              namesRoute: true,
              label: 'يتوفر تحديث جديد. يرجى التحديث للاستمرار',
              child: AlertDialog(
                title: const Text('يتوفر تحديث جديد. يرجى التحديث للاستمرار'),
                actions: [
                  TextButton(
                    onPressed: _open,
                    child: const Text(
                      'تحديث الآن',
                      textDirection: TextDirection.rtl,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
