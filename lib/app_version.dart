/// Must match the version name in pubspec.yaml.
const appVersion = '1.3.5';
const appBuild = '22';

const androidUpdateUrl =
    'https://github.com/AliHusseinAlMarfadi96/echo99-flutter/releases/download/v1.2.0/Echo99.apk';

const iosUpdateUrl =
    'https://github.com/AliHusseinAlMarfadi96/echo99-flutter/releases/download/v1.2.0/Echo99.ipa';

/// Blocks only when the server requires a strictly newer version.
/// This build is never forced out by an equal or older version.
bool forceUpdateBlocks({
  required String localVersion,
  required String latestVersion,
  required bool forceUpdateRequired,
}) {
  if (!forceUpdateRequired) {
    return false;
  }
  final latest = _versionParts(latestVersion);
  final local = _versionParts(localVersion);
  if (latest == null || local == null) {
    return false;
  }
  for (var i = 0; i < latest.length; i++) {
    if (latest[i] > local[i]) {
      return true;
    }
    if (latest[i] < local[i]) {
      return false;
    }
  }
  return false;
}

List<int>? _versionParts(String raw) {
  final bits = raw.trim().split('.');
  if (bits.isEmpty || bits.length > 4) {
    return null;
  }
  final parts = <int>[];
  for (final bit in bits) {
    final match = RegExp(r'^\d+').stringMatch(bit);
    if (match == null) {
      return null;
    }
    parts.add(int.parse(match));
  }
  while (parts.length < 3) {
    parts.add(0);
  }
  return parts;
}
