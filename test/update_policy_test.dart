import 'package:echo99/app_version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'current build is not forced when the flag is off or versions match',
    () {
      expect(
        forceUpdateBlocks(
          localVersion: appVersion,
          latestVersion: appVersion,
          forceUpdateRequired: false,
        ),
        isFalse,
      );
      expect(
        forceUpdateBlocks(
          localVersion: appVersion,
          latestVersion: appVersion,
          forceUpdateRequired: true,
        ),
        isFalse,
      );
      expect(
        forceUpdateBlocks(
          localVersion: appVersion,
          latestVersion: '9.0.0',
          forceUpdateRequired: true,
        ),
        isTrue,
      );
      expect(
        forceUpdateBlocks(
          localVersion: appVersion,
          latestVersion: '1.0.3',
          forceUpdateRequired: true,
        ),
        isFalse,
      );
    },
  );
}
