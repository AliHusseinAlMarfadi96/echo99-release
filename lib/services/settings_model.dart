import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

class SettingsModel extends ChangeNotifier {
  SettingsModel({
    required this.playerId,
    required this.name,
    required this.speakPlays,
    required this.useInternalTts,
    required this.nameCards,
    required this.botMillis,
  });

  static const minBotMillis = 400;
  static const maxBotMillis = 3000;

  String playerId;
  String name;

  /// Announce plays via Semantics live region / TalkBack / VoiceOver.
  bool speakPlays;

  /// When true, also drive flutter_tts. DEFAULT OFF — rely on screen reader.
  bool useInternalTts;

  /// When true, use English card names («٥ of Clubs») in announcements.
  bool nameCards;

  int botMillis;

  static Future<SettingsModel> load() async {
    final prefs = await SharedPreferences.getInstance();
    var id = prefs.getString('player_id');
    if (id == null || id.isEmpty || id.contains('.') || id.contains('@')) {
      id = const Uuid().v4().replaceAll('-', '');
      await prefs.setString('player_id', id);
    }
    final name = prefs.getString('player_name') ?? '';
    return SettingsModel(
      playerId: id,
      name: name,
      speakPlays: prefs.getBool('speak_plays') ?? true,
      useInternalTts: prefs.getBool('use_internal_tts') ?? false,
      nameCards: prefs.getBool('name_cards') ?? true,
      botMillis: prefs.getInt('bot_millis') ?? 1500,
    );
  }

  Future<void> useIdentity(String id) async {
    if (id.isEmpty ||
        id.contains('.') ||
        id.contains('/') ||
        id.contains('@')) {
      throw ArgumentError('unsafe player id');
    }
    playerId = id;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('player_id', id);
  }

  String get displayName {
    final trimmed = name.trim();
    return trimmed.isEmpty ? 'لاعب' : trimmed;
  }

  Future<void> setName(String value) async {
    name = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('player_name', value);
  }

  Future<void> setSpeakPlays(bool value) async {
    speakPlays = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('speak_plays', value);
  }

  Future<void> setUseInternalTts(bool value) async {
    useInternalTts = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('use_internal_tts', value);
  }

  Future<void> setNameCards(bool value) async {
    nameCards = value;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('name_cards', value);
  }

  Future<void> setBotMillis(int value) async {
    botMillis = value.clamp(minBotMillis, maxBotMillis);
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('bot_millis', botMillis);
  }
}
