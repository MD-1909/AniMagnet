import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Lightweight in-process event log for debugging notification timing,
/// AniList responses, and watchlist mutations. Holds the last [_maxEntries]
/// lines in memory and can export them as a plain-text file for sharing.
///
/// Usage anywhere:  LogService.log('NOTIFY', 'scheduled for 01:30');
class LogService {
  static final LogService _i = LogService._();
  LogService._();

  static const _maxEntries = 1000;
  final List<String> _entries = [];

  /// Append a tagged, timestamped line to the in-memory log.
  static void log(String tag, String message) => _i._write(tag, message);

  /// Write the log to a temp file and return its path, ready for [Share.shareXFiles].
  static Future<String?> exportPath() => _i._export();

  /// Erase all in-memory entries.
  static void clear() => _i._entries.clear();

  // ---- internals ----------------------------------------------------------

  void _write(String tag, String message) {
    final now = DateTime.now();
    final ts = '${now.year}-${_p(now.month)}-${_p(now.day)} '
        '${_p(now.hour)}:${_p(now.minute)}:${_p(now.second)}';
    final line = '$ts [$tag] $message';
    if (_entries.length >= _maxEntries) _entries.removeAt(0);
    _entries.add(line);
    debugPrint(line);
  }

  String _p(int n) => n.toString().padLeft(2, '0');

  Future<String?> _export() async {
    try {
      final dir = await getTemporaryDirectory();
      final file = File('${dir.path}/animagnet.log');
      await file.writeAsString(_entries.join('\n'));
      return file.path;
    } catch (e) {
      debugPrint('[LOG] export failed: $e');
      return null;
    }
  }
}
