/// A single torrent release parsed from a nyaa.si RSS item.
class Release {
  final String title;
  final String guid; // unique nyaa view URL — used as identity for "seen" tracking
  final String magnet; // constructed from infoHash + trackers
  final String torrentUrl; // .torrent download link
  final String size; // human-readable, e.g. "1.4 GiB"
  final DateTime? pubDate;
  final int seeders;

  const Release({
    required this.title,
    required this.guid,
    required this.magnet,
    required this.torrentUrl,
    required this.size,
    required this.pubDate,
    required this.seeders,
  });
}
