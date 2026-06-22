import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../models/release.dart';
import '../models/watch_entry.dart';
import '../services/anilist_service.dart';
import '../services/notification_service.dart';
import '../services/nyaa_service.dart';
import '../services/storage_service.dart';
import '../widgets/release_tile.dart';
import 'add_entry_screen.dart';
import 'edit_entry_screen.dart';

/// Per-entry fetch state.
class _Fetch {
  final bool loading;
  final String? error;
  final List<Release> releases;
  const _Fetch({this.loading = false, this.error, this.releases = const []});
}

/// Ways the watchlist can be ordered.
enum _SortMode { title, lastRelease, lastAdded }

class HomeScreen extends StatefulWidget {
  final StorageService storage;
  final NyaaService nyaa;
  final AniListService anilist;
  final NotificationService notifications;

  const HomeScreen({
    super.key,
    required this.storage,
    required this.nyaa,
    required this.anilist,
    required this.notifications,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<WatchEntry> _watchlist = [];
  final Map<String, _Fetch> _fetches = {};
  final Set<String> _expanded = {}; // entry ids whose release list is expanded
  final Set<String> _selected = {}; // selected release guids (multi-select mode)
  Set<String> _seen = {};

  _SortMode? _sortMode;
  bool _sortAsc = true;

  bool get _selecting => _selected.isNotEmpty;

  /// Fixed card height. The cover fills the first column at a poster-like
  /// 2:3 ratio; the taller card leaves blank space under the top episode when
  /// collapsed, and a comfortable scroll area once expanded.
  static const double _cardHeight = 264;
  static const double _coverWidth = 168;

  @override
  void initState() {
    super.initState();
    _watchlist = widget.storage.loadWatchlist();
    _seen = widget.storage.loadSeen();
    widget.notifications.requestPermission();
    _refreshAll();
  }

  // ---- Data ---------------------------------------------------------------

  Future<void> _refreshAll() async {
    if (_watchlist.isEmpty) {
      setState(() {});
      return;
    }
    await Future.wait(_watchlist.map(_refreshEntry));
  }

  Future<void> _refreshEntry(WatchEntry entry) async {
    setState(() => _fetches[entry.id] = const _Fetch(loading: true));
    unawaited(_resolveCover(entry));
    try {
      final releases = await widget.nyaa.fetchForEntry(entry);
      if (!mounted) return;
      setState(() => _fetches[entry.id] = _Fetch(releases: releases));
      // Re-arm the predictive notification with the freshest history.
      unawaited(widget.notifications.scheduleForEntry(entry, releases));
    } catch (e) {
      if (!mounted) return;
      setState(() => _fetches[entry.id] = _Fetch(error: '$e'));
    }
  }

  Future<void> _resolveCover(WatchEntry entry) async {
    final needCover = entry.coverUrl == null || entry.coverUrl!.isEmpty;
    final needName = entry.animeName == null || entry.animeName!.trim().isEmpty;
    if (!needCover && !needName) return;
    final media = entry.anilistId != null
        ? await widget.anilist.fetchById(entry.anilistId!)
        : await widget.anilist.searchByTitle(entry.searchTitle);
    if (media == null) return;
    var changed = false;
    if (needCover && media.coverUrl != null && media.coverUrl!.isNotEmpty) {
      entry.coverUrl = media.coverUrl;
      changed = true;
    }
    if (needName && media.title.trim().isNotEmpty) {
      entry.animeName = media.title.trim();
      changed = true;
    }
    if (entry.anilistId == null) {
      entry.anilistId = media.id;
      changed = true;
    }
    if (!changed) return;
    await widget.storage.saveWatchlist(_watchlist);
    if (mounted) setState(() {});
  }

  Future<void> _openMagnet(Release release) async {
    try {
      final ok = await launchUrl(
        Uri.parse(release.magnet),
        mode: LaunchMode.externalApplication,
      );
      if (!ok) throw 'no handler';
      await widget.storage.markSeen(release.guid);
      if (mounted) setState(() => _seen = widget.storage.loadSeen());
    } catch (_) {
      _snack('No torrent app found to open the magnet link.');
    }
  }

  // ---- Mutations ----------------------------------------------------------

  Future<void> _addViaSearch() async {
    final entry = await Navigator.of(context).push<WatchEntry>(
      MaterialPageRoute(builder: (_) => AddEntryScreen(nyaa: widget.nyaa)),
    );
    if (entry != null) await _commitNew(entry);
  }

  Future<void> _addManual() async {
    final entry = await Navigator.of(context).push<WatchEntry>(
      MaterialPageRoute(builder: (_) => const EditEntryScreen()),
    );
    if (entry != null) await _commitNew(entry);
  }

  Future<void> _commitNew(WatchEntry entry) async {
    setState(() => _watchlist = [..._watchlist, entry]);
    await widget.storage.saveWatchlist(_watchlist);
    await _refreshEntry(entry);
  }

  Future<void> _edit(WatchEntry entry) async {
    final updated = await Navigator.of(context).push<WatchEntry>(
      MaterialPageRoute(builder: (_) => EditEntryScreen(existing: entry)),
    );
    if (updated == null) return;
    setState(() {
      _watchlist =
          _watchlist.map((e) => e.id == updated.id ? updated : e).toList();
    });
    await widget.storage.saveWatchlist(_watchlist);
    await _refreshEntry(updated);
  }

  Future<void> _delete(WatchEntry entry) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "${entry.title}"?'),
        content: const Text('This removes it from your watchlist.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Remove')),
        ],
      ),
    );
    if (ok != true) return;
    await widget.notifications.cancelForEntry(entry);
    setState(() {
      _watchlist = _watchlist.where((e) => e.id != entry.id).toList();
      _fetches.remove(entry.id);
    });
    await widget.storage.saveWatchlist(_watchlist);
  }

  Future<void> _markAllSeen() async {
    final all = _fetches.values.expand((f) => f.releases).map((r) => r.guid);
    await widget.storage.markAllSeen(all);
    setState(() => _seen = widget.storage.loadSeen());
  }

  // ---- Multi-select -------------------------------------------------------

  void _toggleSelect(Release r) {
    setState(() {
      if (!_selected.remove(r.guid)) _selected.add(r.guid);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  Future<void> _markSelected({required bool watched}) async {
    if (_selected.isEmpty) return;
    if (watched) {
      await widget.storage.markAllSeen(_selected);
    } else {
      await widget.storage.markAllUnseen(_selected);
    }
    final count = _selected.length;
    setState(() {
      _seen = widget.storage.loadSeen();
      _selected.clear();
    });
    _snack('Marked $count as ${watched ? 'watched' : 'unwatched'}.');
  }

  void _snack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text(
          msg,
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        backgroundColor: const Color(0xFF1E1E26),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 2),
        margin: const EdgeInsets.fromLTRB(40, 0, 40, 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
      ));
  }

  // ---- Ordering -----------------------------------------------------------

  /// Most recent release date among an entry's fetched releases, if any.
  DateTime? _latestRelease(WatchEntry entry) {
    final dates = (_fetches[entry.id]?.releases ?? const <Release>[])
        .map((r) => r.pubDate)
        .whereType<DateTime>();
    if (dates.isEmpty) return null;
    return dates.reduce((a, b) => a.isAfter(b) ? a : b);
  }

  Future<void> _sortBy(_SortMode mode) async {
    setState(() {
      if (_sortMode == mode) {
        _sortAsc = !_sortAsc; // same button: flip direction
      } else {
        _sortMode = mode;
        // Title defaults A-Z; date-based sorts default to newest-first.
        _sortAsc = mode == _SortMode.title;
      }
    });
    _applySort();
    await widget.storage.saveWatchlist(_watchlist);
  }

  void _applySort() {
    final mode = _sortMode;
    if (mode == null) return;
    final dir = _sortAsc ? 1 : -1;
    final list = [..._watchlist];
    switch (mode) {
      case _SortMode.title:
        list.sort((a, b) =>
            dir *
            a.displayTitle
                .toLowerCase()
                .compareTo(b.displayTitle.toLowerCase()));
        break;
      case _SortMode.lastRelease:
        list.sort((a, b) {
          final da = _latestRelease(a);
          final db = _latestRelease(b);
          if (da == null && db == null) return 0;
          if (da == null) return 1; // entries without releases stay last
          if (db == null) return -1;
          return dir * da.compareTo(db);
        });
        break;
      case _SortMode.lastAdded:
        list.sort((a, b) => dir * a.addedAt.compareTo(b.addedAt));
        break;
    }
    setState(() => _watchlist = list);
  }

  Future<void> _onReorder(int oldIndex, int newIndex) async {
    setState(() {
      if (newIndex > oldIndex) newIndex -= 1;
      final item = _watchlist.removeAt(oldIndex);
      _watchlist.insert(newIndex, item);
    });
    await widget.storage.saveWatchlist(_watchlist);
  }

  Future<void> _toggleNotifications(WatchEntry entry) async {
    setState(() => entry.notificationsEnabled = !entry.notificationsEnabled);
    await widget.storage.saveWatchlist(_watchlist);
    if (entry.notificationsEnabled) {
      final releases = _fetches[entry.id]?.releases ?? const <Release>[];
      await widget.notifications.scheduleForEntry(entry, releases);
      _snack('Notifications enabled for "${entry.displayTitle}".');
    } else {
      await widget.notifications.cancelForEntry(entry);
      _snack('Notifications disabled for "${entry.displayTitle}".');
    }
  }

  // ---- UI -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _selecting ? _selectionAppBar() : _defaultAppBar(),
      floatingActionButton: _selecting
          ? null
          : FloatingActionButton.extended(
              onPressed: _addViaSearch,
              icon: const Icon(Icons.add),
              label: const Text('Add anime'),
            ),
      body: RefreshIndicator(
        onRefresh: _refreshAll,
        child: _watchlist.isEmpty ? _emptyState() : _list(),
      ),
    );
  }

  AppBar _defaultAppBar() {
    return AppBar(
      title: const Text('AniMagnet'),
      actions: [
        IconButton(
          tooltip: 'Refresh',
          icon: const Icon(Icons.refresh),
          onPressed: _refreshAll,
        ),
        PopupMenuButton<_SortMode>(
          tooltip: 'Sort',
          icon: const Icon(Icons.sort),
          onSelected: _sortBy,
          itemBuilder: (_) => [
            _sortItem(_SortMode.title, 'Title'),
            _sortItem(_SortMode.lastRelease, 'Last episode release'),
            _sortItem(_SortMode.lastAdded, 'Last added'),
          ],
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            if (v == 'manual') _addManual();
            if (v == 'seen') _markAllSeen();
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'manual', child: Text('Add manually')),
            PopupMenuItem(value: 'seen', child: Text('Mark all as seen')),
          ],
        ),
      ],
    );
  }

  /// A sort menu entry that shows a direction arrow when it is the active sort.
  PopupMenuItem<_SortMode> _sortItem(_SortMode mode, String label) {
    final active = _sortMode == mode;
    return PopupMenuItem(
      value: mode,
      child: Row(
        children: [
          Expanded(child: Text(label)),
          if (active)
            Icon(_sortAsc ? Icons.arrow_upward : Icons.arrow_downward,
                size: 16),
        ],
      ),
    );
  }

  AppBar _selectionAppBar() {
    return AppBar(
      leading: IconButton(
        tooltip: 'Cancel selection',
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('${_selected.length} selected'),
      actions: [
        IconButton(
          tooltip: 'Mark watched',
          icon: const Icon(Icons.visibility),
          onPressed: () => _markSelected(watched: true),
        ),
        IconButton(
          tooltip: 'Mark unwatched',
          icon: const Icon(Icons.visibility_off),
          onPressed: () => _markSelected(watched: false),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.25),
        const Icon(Icons.tv_off, size: 64, color: Colors.grey),
        const SizedBox(height: 16),
        const Center(
          child: Text('No anime tracked yet.\nTap "Add anime" to start.',
              textAlign: TextAlign.center),
        ),
      ],
    );
  }

  Widget _list() {
    return ReorderableListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 88),
      buildDefaultDragHandles: false,
      onReorder: _onReorder,
      itemCount: _watchlist.length,
      itemBuilder: (context, i) => _entryCard(_watchlist[i], i),
    );
  }

  Widget _entryCard(WatchEntry entry, int index) {
    final fetch = _fetches[entry.id] ?? const _Fetch();
    final unseen =
        fetch.releases.where((r) => !_seen.contains(r.guid)).toList();
    final seen = fetch.releases.where((r) => _seen.contains(r.guid)).toList();

    return Card(
      key: ValueKey(entry.id),
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: SizedBox(
        height: _cardHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ReorderableDelayedDragStartListener(
              index: index,
              child: _cover(entry),
            ),
            Expanded(child: _content(entry, fetch, unseen, seen)),
          ],
        ),
      ),
    );
  }

  Widget _cover(WatchEntry entry) {
    const w = _coverWidth;
    final hasCover = entry.coverUrl != null && entry.coverUrl!.isNotEmpty;
    final placeholder = Container(
      width: w,
      color: const Color(0xFF15151B),
      child: const Center(
        child: Icon(Icons.image_not_supported, color: Colors.grey, size: 36),
      ),
    );
    if (!hasCover) return placeholder;
    return SizedBox(
      width: w,
      child: CachedNetworkImage(
        imageUrl: entry.coverUrl!,
        fit: BoxFit.cover,
        placeholder: (_, __) =>
            Container(width: w, color: const Color(0xFF15151B)),
        errorWidget: (_, __, ___) => placeholder,
      ),
    );
  }

  Widget _content(
    WatchEntry entry,
    _Fetch fetch,
    List<Release> unseen,
    List<Release> seen,
  ) {
    final theme = Theme.of(context);
    final isOpen = _expanded.contains(entry.id);

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 4, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: title + actions
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(entry.displayTitle,
                    style: theme.textTheme.titleMedium
                        ?.copyWith(fontWeight: FontWeight.w600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              SizedBox(
                height: 32,
                width: 32,
                child: PopupMenuButton<String>(
                  padding: EdgeInsets.zero,
                  iconSize: 20,
                  onSelected: (v) {
                    if (v == 'edit') _edit(entry);
                    if (v == 'notify') _toggleNotifications(entry);
                    if (v == 'delete') _delete(entry);
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(
                      value: 'notify',
                      child: Text(entry.notificationsEnabled
                          ? 'Disable notifications'
                          : 'Enable notifications'),
                    ),
                    const PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(spacing: 6, runSpacing: 4, children: [
            if (entry.quality.isNotEmpty) _chip(entry.quality),
            if (unseen.isNotEmpty)
              _chip('${unseen.length} NEW', color: Colors.green),
            if (!entry.notificationsEnabled) _chip('🔕 OFF'),
          ]),
          const Divider(height: 14),
          Expanded(child: _releaseArea(entry, fetch, unseen, seen, isOpen)),
          if (seen.isNotEmpty) _watchedToggle(entry, seen.length, isOpen),
        ],
      ),
    );
  }

  Widget _releaseArea(
    WatchEntry entry,
    _Fetch fetch,
    List<Release> unseen,
    List<Release> seen,
    bool isOpen,
  ) {
    final theme = Theme.of(context);

    if (fetch.loading && fetch.releases.isEmpty) {
      return const Center(
        child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (fetch.error != null) {
      return Row(
        children: [
          const Icon(Icons.cloud_off, color: Colors.redAccent, size: 18),
          const SizedBox(width: 8),
          Expanded(
              child: Text('Could not fetch releases',
                  style: theme.textTheme.bodySmall)),
          TextButton(
              onPressed: () => _refreshEntry(entry), child: const Text('Retry')),
        ],
      );
    }
    if (unseen.isEmpty && seen.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('No matching releases yet',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
      );
    }

    // Unwatched are always shown; watched are revealed only when expanded.
    final visible = <Release>[...unseen, if (isOpen) ...seen];
    if (visible.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: Text('No new releases',
            style: theme.textTheme.bodySmall?.copyWith(color: Colors.grey)),
      );
    }

    return ListView.builder(
      padding: EdgeInsets.zero,
      physics: const AlwaysScrollableScrollPhysics(),
      itemCount: visible.length,
      itemBuilder: (_, i) {
        final r = visible[i];
        return ReleaseTile(
          release: r,
          isNew: !_seen.contains(r.guid),
          selectionMode: _selecting,
          selected: _selected.contains(r.guid),
          onMagnet: () => _openMagnet(r),
          onLongPress: () => _toggleSelect(r),
          onSelectToggle: () => _toggleSelect(r),
        );
      },
    );
  }

  Widget _watchedToggle(WatchEntry entry, int count, bool isOpen) {
    final theme = Theme.of(context);
    final label = isOpen
        ? 'Hide watched'
        : 'Show watched ($count episode${count == 1 ? '' : 's'})';
    return InkWell(
      onTap: () => setState(() {
        if (isOpen) {
          _expanded.remove(entry.id);
        } else {
          _expanded.add(entry.id);
        }
      }),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(isOpen ? Icons.expand_less : Icons.expand_more,
                size: 18, color: theme.colorScheme.primary),
            const SizedBox(width: 4),
            Text(
              label,
              style: theme.textTheme.labelMedium
                  ?.copyWith(color: theme.colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(String text, {Color? color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color ?? const Color(0xFF1E1E26),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: color != null ? Colors.white : Colors.white70),
      ),
    );
  }
}
