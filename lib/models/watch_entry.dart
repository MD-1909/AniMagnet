/// A configured anime in the watchlist. The (group + quality) act as the
/// match pattern: on refresh we only keep releases whose title contains both.
class WatchEntry {
  final String id;
  String title; // anime title, e.g. "Marriage Toxin"
  String group; // release group/source, e.g. "ASW"
  String quality; // e.g. "1080p"
  int? anilistId;
  String? coverUrl; // cached AniList coverImage.large
  String? animeName; // cached clean AniList display name, used for the card title
  final DateTime addedAt; // when the entry was added, used for "last added" sorting
  bool notificationsEnabled; // per-entry predicted-episode alerts toggle

  WatchEntry({
    required this.id,
    required this.title,
    required this.group,
    required this.quality,
    this.anilistId,
    this.coverUrl,
    this.animeName,
    DateTime? addedAt,
    this.notificationsEnabled = true,
  }) : addedAt = addedAt ?? DateTime.now();

  /// Card heading, formatted as "Anime Name | Uploader" (the release group).
  /// Falls back to the raw [title] until the AniList name is resolved.
  String get displayTitle {
    final name = (animeName != null && animeName!.trim().isNotEmpty)
        ? animeName!.trim()
        : title;
    return group.trim().isEmpty ? name : '$name | ${group.trim()}';
  }

  /// Query string sent to nyaa RSS: title + group + quality (full-text AND).
  String get nyaaQuery =>
      [title, group, quality].where((s) => s.trim().isNotEmpty).join(' ');

  /// Title cleaned of group/quality/encoding noise, for AniList cover lookup.
  /// (A title like "marriagetoxin asw" won't match AniList; "marriagetoxin" does.)
  String get searchTitle {
    var t = title;
    for (final token in [group, quality]) {
      if (token.trim().isNotEmpty) {
        t = t.replaceAll(
            RegExp(RegExp.escape(token.trim()), caseSensitive: false), ' ');
      }
    }
    t = t.replaceAll(
        RegExp(
            r'\b(1080p|720p|480p|2160p|4k|bluray|web[\- ]?dl|hevc|x26[45]|dual[\- ]?audio|multi|hi10p?|10bit|aac|flac|batch|uncensored)\b',
            caseSensitive: false),
        ' ');
    t = t.replaceAll(RegExp(r'[\[\]\(\)]'), ' ');
    final cleaned = t.replaceAll(RegExp(r'\s+'), ' ').trim();
    return cleaned.isEmpty ? title : cleaned;
  }

  /// Client-side guard: a release belongs to this entry only if its title
  /// contains the configured group and quality (case-insensitive).
  bool matches(String releaseTitle) {
    final t = releaseTitle.toLowerCase();
    final okGroup = group.trim().isEmpty || t.contains(group.toLowerCase());
    final okQuality =
        quality.trim().isEmpty || t.contains(quality.toLowerCase());
    return okGroup && okQuality;
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'group': group,
        'quality': quality,
        'anilistId': anilistId,
        'coverUrl': coverUrl,
        'animeName': animeName,
        'addedAt': addedAt.toIso8601String(),
        'notificationsEnabled': notificationsEnabled,
      };

  factory WatchEntry.fromJson(Map<String, dynamic> json) => WatchEntry(
        id: json['id'] as String,
        title: json['title'] as String,
        group: (json['group'] ?? '') as String,
        quality: (json['quality'] ?? '') as String,
        anilistId: json['anilistId'] as int?,
        coverUrl: json['coverUrl'] as String?,
        animeName: json['animeName'] as String?,
        addedAt: _parseAddedAt(json),
        notificationsEnabled: (json['notificationsEnabled'] ?? true) as bool,
      );

  /// Backward-compatible "added" timestamp: use the stored value, else derive
  /// it from the legacy microsecond-timestamp id, else fall back to now.
  static DateTime _parseAddedAt(Map<String, dynamic> json) {
    final raw = json['addedAt'] as String?;
    if (raw != null) {
      final parsed = DateTime.tryParse(raw);
      if (parsed != null) return parsed;
    }
    final micros = int.tryParse((json['id'] ?? '') as String);
    if (micros != null) {
      return DateTime.fromMicrosecondsSinceEpoch(micros);
    }
    return DateTime.now();
  }
}
