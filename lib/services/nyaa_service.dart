import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/release.dart';
import '../models/watch_entry.dart';

/// One distinct release "version" surfaced during the add-anime search flow,
/// e.g. group "ASW" / quality "1080p". Used to let the user pick a pattern.
class ReleaseVersion {
  final String group;
  final String quality;
  final String sampleTitle; // representative title (prefer episode 1)
  final String size;

  const ReleaseVersion({
    required this.group,
    required this.quality,
    required this.sampleTitle,
    required this.size,
  });

  String get label {
    final g = group.isEmpty ? '(no group)' : group;
    final q = quality.isEmpty ? '(unknown quality)' : quality;
    return '$g · $q';
  }
}

/// Talks to nyaa.si's RSS feed. The RSS items expose torrent metadata in a
/// custom `nyaa:` XML namespace (infoHash, size, seeders) but NOT a magnet
/// link — so we build the magnet from the infoHash.
class NyaaService {
  static const _base = 'https://nyaa.si/';

  // Public trackers appended to constructed magnet links.
  static const _trackers = <String>[
    'http://nyaa.tracker.wf:7777/announce',
    'udp://open.stealth.si:80/announce',
    'udp://tracker.opentrackr.org:1337/announce',
    'udp://exodus.desync.com:6969/announce',
    'udp://tracker.torrent.eu.org:451/announce',
    'udp://tracker.coppersurfer.tk:6969/announce',
  ];

  final http.Client _client;
  NyaaService([http.Client? client]) : _client = client ?? http.Client();

  Uri _rssUri(String query) => Uri.parse(_base).replace(queryParameters: {
        'page': 'rss',
        'q': query,
        'c': '0_0',
        'f': '0',
      });

  /// Fetch + parse the RSS feed for an arbitrary query string.
  Future<List<Release>> _fetch(String query) async {
    final resp = await _client.get(
      _rssUri(query),
      headers: {'User-Agent': 'AniMagnet/1.0 (Flutter)'},
    ).timeout(const Duration(seconds: 20));

    if (resp.statusCode != 200) {
      throw NyaaException('nyaa.si returned HTTP ${resp.statusCode}');
    }
    return _parse(resp.body);
  }

  /// Releases for a configured watchlist entry, filtered by its pattern,
  /// newest first.
  Future<List<Release>> fetchForEntry(WatchEntry entry) async {
    final releases = await _fetch(entry.nyaaQuery);
    final matched =
        releases.where((r) => entry.matches(r.title)).toList(growable: false);
    matched.sort((a, b) => (b.pubDate ?? DateTime(1970))
        .compareTo(a.pubDate ?? DateTime(1970)));
    return matched;
  }

  /// Add-flow: search by title and collapse results into distinct
  /// (group, quality) versions, preferring an episode-1 sample for each.
  Future<List<ReleaseVersion>> searchVersions(String title) async {
    final releases = await _fetch(title);

    // group key -> best sample so far
    final byKey = <String, _VersionAcc>{};
    for (final r in releases) {
      final group = _extractGroup(r.title);
      final quality = _extractQuality(r.title);
      final ep = _extractEpisode(r.title);
      final key = '${group.toLowerCase()}|${quality.toLowerCase()}';

      final isEp1 = ep == 1;
      final existing = byKey[key];
      if (existing == null) {
        byKey[key] = _VersionAcc(group, quality, r.title, r.size, isEp1);
      } else if (isEp1 && !existing.isEp1) {
        // prefer an episode-1 sample title when available
        byKey[key] = _VersionAcc(group, quality, r.title, r.size, true);
      }
    }

    final versions = byKey.values
        .map((a) => ReleaseVersion(
              group: a.group,
              quality: a.quality,
              sampleTitle: a.title,
              size: a.size,
            ))
        .toList();

    // Stable, readable order: group name then quality.
    versions.sort((a, b) {
      final g = a.group.toLowerCase().compareTo(b.group.toLowerCase());
      return g != 0 ? g : a.quality.compareTo(b.quality);
    });
    return versions;
  }

  // ---- Parsing ------------------------------------------------------------

  List<Release> _parse(String xmlBody) {
    final doc = XmlDocument.parse(xmlBody);
    final items = doc.findAllElements('item');
    final out = <Release>[];

    for (final item in items) {
      final title = _text(item, 'title');
      if (title.isEmpty) continue;

      final guid = _text(item, 'guid');
      final torrentUrl = _text(item, 'link');
      final infoHash = _nyaaText(item, 'infoHash');
      final size = _nyaaText(item, 'size');
      final seeders = int.tryParse(_nyaaText(item, 'seeders')) ?? 0;
      final pubDate = _parseDate(_text(item, 'pubDate'));

      out.add(Release(
        title: title,
        guid: guid.isNotEmpty ? guid : torrentUrl,
        magnet: _buildMagnet(infoHash, title),
        torrentUrl: torrentUrl,
        size: size.isEmpty ? 'unknown size' : size,
        pubDate: pubDate,
        seeders: seeders,
      ));
    }
    return out;
  }

  String _buildMagnet(String infoHash, String title) {
    if (infoHash.isEmpty) return '';
    final dn = Uri.encodeQueryComponent(title);
    final tr =
        _trackers.map((t) => '&tr=${Uri.encodeQueryComponent(t)}').join();
    return 'magnet:?xt=urn:btih:$infoHash&dn=$dn$tr';
  }

  String _text(XmlElement item, String name) {
    final el = item.findElements(name);
    return el.isEmpty ? '' : el.first.innerText.trim();
  }

  // Elements in the nyaa namespace are serialized as <nyaa:size> etc.
  String _nyaaText(XmlElement item, String local) {
    for (final e in item.childElements) {
      if (e.name.local == local) return e.innerText.trim();
    }
    return '';
  }

  DateTime? _parseDate(String raw) {
    if (raw.isEmpty) return null;
    // RFC-822, e.g. "Sun, 22 Jun 2026 12:00:00 -0000"
    try {
      return _Rfc822.parse(raw);
    } catch (_) {
      return null;
    }
  }

  // ---- Title heuristics ---------------------------------------------------

  String _extractGroup(String title) {
    // Leading [Group] or (Group)
    final m = RegExp(r'^\s*[\[\(]([^\]\)]+)[\]\)]').firstMatch(title);
    return m?.group(1)?.trim() ?? '';
  }

  String _extractQuality(String title) {
    final m = RegExp(r'(\d{3,4}p|2160p|1080p|720p|480p|4K)', caseSensitive: false)
        .firstMatch(title);
    return m?.group(1) ?? '';
  }

  /// Best-effort episode number: " - 01 ", "E01", "Episode 1", "[01]".
  int? _extractEpisode(String title) {
    final patterns = [
      RegExp(r'(?:[-–]\s*)(\d{1,3})(?:\s*(?:v\d)?\s*[\[\(])', caseSensitive: false),
      RegExp(r'\bE(?:P)?\s*(\d{1,3})\b', caseSensitive: false),
      RegExp(r'\bEpisode\s*(\d{1,3})\b', caseSensitive: false),
      RegExp(r'[-–]\s*(\d{1,3})\s*$'),
    ];
    for (final p in patterns) {
      final m = p.firstMatch(title);
      if (m != null) {
        final n = int.tryParse(m.group(1)!);
        if (n != null) return n;
      }
    }
    return null;
  }

  void dispose() => _client.close();
}

class _VersionAcc {
  final String group;
  final String quality;
  final String title;
  final String size;
  final bool isEp1;
  _VersionAcc(this.group, this.quality, this.title, this.size, this.isEp1);
}

class NyaaException implements Exception {
  final String message;
  NyaaException(this.message);
  @override
  String toString() => message;
}

/// Minimal RFC-822 date parser (the format nyaa uses in <pubDate>).
class _Rfc822 {
  static const _months = {
    'Jan': 1, 'Feb': 2, 'Mar': 3, 'Apr': 4, 'May': 5, 'Jun': 6,
    'Jul': 7, 'Aug': 8, 'Sep': 9, 'Oct': 10, 'Nov': 11, 'Dec': 12,
  };

  static DateTime parse(String raw) {
    // e.g. "Sun, 22 Jun 2026 12:00:00 -0000"
    final m = RegExp(
      r'(\d{1,2})\s+(\w{3})\s+(\d{4})\s+(\d{2}):(\d{2}):(\d{2})',
    ).firstMatch(raw);
    if (m == null) throw const FormatException('bad date');
    return DateTime.utc(
      int.parse(m.group(3)!),
      _months[m.group(2)] ?? 1,
      int.parse(m.group(1)!),
      int.parse(m.group(4)!),
      int.parse(m.group(5)!),
      int.parse(m.group(6)!),
    ).toLocal();
  }
}
