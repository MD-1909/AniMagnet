import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Result of an AniList media lookup.
class AniListMedia {
  final int id;
  final String title;
  final String? coverUrl;
  /// UTC time the next episode airs, from AniList's schedule. Null for
  /// completed/unreleased series that have no upcoming airing date.
  final DateTime? nextAiringAt;
  final int? nextEpisode;
  const AniListMedia({
    required this.id,
    required this.title,
    this.coverUrl,
    this.nextAiringAt,
    this.nextEpisode,
  });
}

/// Queries AniList's public GraphQL API for cover art.
/// https://graphql.anilist.co
class AniListService {
  static final Uri _endpoint = Uri.parse('https://graphql.anilist.co');

  final http.Client _client;
  AniListService([http.Client? client]) : _client = client ?? http.Client();

  Future<Map<String, dynamic>?> _post(String query, Map<String, dynamic> vars) async {
    try {
      final resp = await _client
          .post(
            _endpoint,
            headers: {
              'Content-Type': 'application/json',
              'Accept': 'application/json',
              // Cloudflare in front of AniList can reject the default Dart UA.
              'User-Agent':
                  'Mozilla/5.0 (Android) AniMagnet/1.0 (+flutter http)',
            },
            body: jsonEncode({'query': query, 'variables': vars}),
          )
          .timeout(const Duration(seconds: 15));
      if (resp.statusCode != 200) {
        debugPrint('[AniList] HTTP ${resp.statusCode}: ${resp.body}');
        return null;
      }
      final body = jsonDecode(resp.body) as Map<String, dynamic>;
      return body['data']?['Media'] as Map<String, dynamic>?;
    } catch (e) {
      // Cover art is best-effort; never break a refresh over it.
      debugPrint('[AniList] request failed: $e');
      return null;
    }
  }

  /// Look up a single anime by free-text title.
  Future<AniListMedia?> searchByTitle(String title) async {
    const q = r'''
      query ($search: String) {
        Media(search: $search, type: ANIME) {
          id
          title { romaji english }
          coverImage { large }
          nextAiringEpisode { airingAt episode }
        }
      }''';
    final media = await _post(q, {'search': title});
    return _toMedia(media);
  }

  /// Fetch by a known AniList ID.
  Future<AniListMedia?> fetchById(int id) async {
    const q = r'''
      query ($id: Int) {
        Media(id: $id, type: ANIME) {
          id
          title { romaji english }
          coverImage { large }
          nextAiringEpisode { airingAt episode }
        }
      }''';
    final media = await _post(q, {'id': id});
    return _toMedia(media);
  }

  AniListMedia? _toMedia(Map<String, dynamic>? media) {
    if (media == null) return null;
    final titles = media['title'] as Map<String, dynamic>?;
    final name = (titles?['english'] ?? titles?['romaji'] ?? '') as String;
    final cover = media['coverImage'] as Map<String, dynamic>?;

    final airing = media['nextAiringEpisode'] as Map<String, dynamic>?;
    DateTime? nextAiringAt;
    int? nextEpisode;
    if (airing != null) {
      final airingAt = airing['airingAt'];
      if (airingAt is int) {
        nextAiringAt = DateTime.fromMillisecondsSinceEpoch(airingAt * 1000, isUtc: true);
      }
      nextEpisode = airing['episode'] as int?;
    }

    return AniListMedia(
      id: media['id'] as int,
      title: name,
      coverUrl: cover?['large'] as String?,
      nextAiringAt: nextAiringAt,
      nextEpisode: nextEpisode,
    );
  }

  void dispose() => _client.close();
}
