/// Predicts when the next episode of an anime is likely to be posted, based on
/// the cadence of past releases. Pure logic — no I/O — so it's easy to reason about.
class PostingPredictor {
  /// Returns the predicted next post time, rolled forward to be in the future,
  /// or null if there isn't enough history to make a sensible guess.
  ///
  /// [dates] are the publish times of past matching releases (any order).
  /// Near-duplicate uploads (e.g. v2 re-releases within 12h) are collapsed so
  /// they don't poison the interval estimate. The median interval is used so a
  /// single irregular gap (hiatus, double-episode) doesn't skew the cadence.
  static DateTime? predictNext(List<DateTime> dates, DateTime now) {
    final sorted = [...dates]..sort();
    if (sorted.length < 2) return null;

    // Collapse posts that are within 12h of the previous kept post.
    final collapsed = <DateTime>[sorted.first];
    for (final d in sorted.skip(1)) {
      if (d.difference(collapsed.last).inHours.abs() >= 12) collapsed.add(d);
    }
    if (collapsed.length < 2) return null;

    final intervals = <int>[]; // minutes between consecutive posts
    for (var i = 1; i < collapsed.length; i++) {
      intervals.add(collapsed[i].difference(collapsed[i - 1]).inMinutes);
    }
    final step = _median(intervals);
    if (step <= 0) return null;

    var next = collapsed.last.add(Duration(minutes: step));
    // Roll forward past any episodes we've already missed.
    var guard = 0;
    while (next.isBefore(now) && guard++ < 1000) {
      next = next.add(Duration(minutes: step));
    }
    return next;
  }

  static int _median(List<int> xs) {
    final s = [...xs]..sort();
    final n = s.length;
    if (n == 0) return 0;
    return n.isOdd ? s[n ~/ 2] : ((s[n ~/ 2 - 1] + s[n ~/ 2]) / 2).round();
  }
}
