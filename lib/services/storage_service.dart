import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/watch_entry.dart';

/// Local persistence backed by shared_preferences (everything as JSON).
///
/// Stores three things:
///  - the watchlist (also caches each entry's AniList coverUrl)
///  - the set of "seen" release GUIDs (a release is NEW until its magnet is tapped)
class StorageService {
  static const _kWatchlist = 'watchlist';
  static const _kSeen = 'seen_links';

  late final SharedPreferences _prefs;

  Future<void> init() async {
    _prefs = await SharedPreferences.getInstance();
  }

  // ---- Watchlist ----------------------------------------------------------

  List<WatchEntry> loadWatchlist() {
    final raw = _prefs.getString(_kWatchlist);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      return list
          .map((e) => WatchEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> saveWatchlist(List<WatchEntry> entries) async {
    final raw = jsonEncode(entries.map((e) => e.toJson()).toList());
    await _prefs.setString(_kWatchlist, raw);
  }

  // ---- Seen tracking ------------------------------------------------------

  Set<String> loadSeen() {
    return _prefs.getStringList(_kSeen)?.toSet() ?? <String>{};
  }

  Future<void> markSeen(String guid) async {
    final seen = loadSeen()..add(guid);
    await _prefs.setStringList(_kSeen, seen.toList());
  }

  Future<void> markAllSeen(Iterable<String> guids) async {
    final seen = loadSeen()..addAll(guids);
    await _prefs.setStringList(_kSeen, seen.toList());
  }

  Future<void> markUnseen(String guid) async {
    final seen = loadSeen()..remove(guid);
    await _prefs.setStringList(_kSeen, seen.toList());
  }

  Future<void> markAllUnseen(Iterable<String> guids) async {
    final seen = loadSeen()..removeAll(guids);
    await _prefs.setStringList(_kSeen, seen.toList());
  }

  bool isSeen(String guid) => loadSeen().contains(guid);
}
