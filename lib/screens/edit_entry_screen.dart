import 'dart:async';

import 'package:flutter/material.dart';

import '../models/watch_entry.dart';
import '../services/anilist_service.dart';

/// Manual add/edit form for a watchlist entry. Returns the saved [WatchEntry]
/// (pop result), or null if cancelled.
class EditEntryScreen extends StatefulWidget {
  final WatchEntry? existing;
  final AniListService anilist;
  const EditEntryScreen({super.key, this.existing, required this.anilist});

  @override
  State<EditEntryScreen> createState() => _EditEntryScreenState();
}

class _EditEntryScreenState extends State<EditEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _group;
  late final TextEditingController _quality;
  late final TextEditingController _anilistId;
  late final TextEditingController _searchCtrl;

  /// Name of the currently selected AniList entry (for display only).
  String? _resolvedName;
  List<AniListMedia> _searchResults = [];
  bool _searching = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _group = TextEditingController(text: e?.group ?? '');
    _quality = TextEditingController(text: e?.quality ?? '');
    _anilistId = TextEditingController(text: e?.anilistId?.toString() ?? '');
    _searchCtrl = TextEditingController();
    _resolvedName = e?.animeName;

    // Clear the resolved name when the user types a different ID manually.
    _anilistId.addListener(() {
      final typed = int.tryParse(_anilistId.text.trim());
      if (typed != widget.existing?.anilistId) {
        if (_resolvedName != null) setState(() => _resolvedName = null);
      }
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _title.dispose();
    _group.dispose();
    _quality.dispose();
    _anilistId.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() { _searchResults = []; _searching = false; });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final results = await widget.anilist.searchMultiple(query.trim());
      if (!mounted) return;
      setState(() { _searchResults = results; _searching = false; });
    });
  }

  void _pickResult(AniListMedia media) {
    setState(() {
      _anilistId.text = media.id.toString();
      _resolvedName = media.title;
      _searchResults = [];
      _searchCtrl.clear();
      _searching = false;
    });
    _debounce?.cancel();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final e = widget.existing;
    final newId = int.tryParse(_anilistId.text.trim());
    final idChanged = newId != e?.anilistId;
    final result = WatchEntry(
      id: e?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      title: _title.text.trim(),
      group: _group.text.trim(),
      quality: _quality.text.trim(),
      anilistId: newId,
      // Clear all AniList caches when the ID changes so a fresh fetch
      // picks up the correct season's name and airing schedule.
      coverUrl: idChanged ? null : e?.coverUrl,
      animeName: idChanged ? _resolvedName : e?.animeName,
      nextAiringAt: idChanged ? null : e?.nextAiringAt,
      nextEpisode: idChanged ? null : e?.nextEpisode,
      addedAt: e?.addedAt,
      notificationsEnabled: e?.notificationsEnabled ?? true,
    );
    Navigator.of(context).pop(result);
  }

  String _statusLabel(String? status) => switch (status) {
    'RELEASING' => 'Airing',
    'FINISHED' => 'Finished',
    'NOT_YET_RELEASED' => 'Upcoming',
    'CANCELLED' => 'Cancelled',
    'HIATUS' => 'Hiatus',
    _ => '',
  };

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
    final theme = Theme.of(context);
    final subtle = theme.colorScheme.onSurface.withValues(alpha: 0.55);

    return Scaffold(
      appBar: AppBar(title: Text(editing ? 'Edit anime' : 'Add manually')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _title,
              decoration: const InputDecoration(
                labelText: 'Anime title',
                hintText: 'e.g. Marriage Toxin',
                border: OutlineInputBorder(),
              ),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Title is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _group,
              decoration: const InputDecoration(
                labelText: 'Release group / source',
                hintText: 'e.g. ASW, ToonsHub',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _quality,
              decoration: const InputDecoration(
                labelText: 'Quality',
                hintText: 'e.g. 1080p',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 24),

            // ---- AniList ID picker ------------------------------------------
            Text('AniList', style: theme.textTheme.labelLarge),
            const SizedBox(height: 10),

            // Search field
            TextFormField(
              controller: _searchCtrl,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                labelText: 'Search by title',
                hintText: 'e.g. Re:Zero Season 4',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.search),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(12),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear),
                            onPressed: () {
                              _searchCtrl.clear();
                              setState(() { _searchResults = []; _searching = false; });
                              _debounce?.cancel();
                            },
                          )
                        : null,
              ),
            ),

            // Search results dropdown
            if (_searchResults.isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: _searchResults.asMap().entries.map((e) {
                    final i = e.key;
                    final m = e.value;
                    final meta = [
                      if (m.seasonYear != null) '${m.seasonYear}',
                      _statusLabel(m.status),
                    ].where((s) => s.isNotEmpty).join(' · ');
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (i > 0)
                          Divider(
                            height: 1,
                            color: theme.colorScheme.outline.withValues(alpha: 0.2),
                          ),
                        InkWell(
                          onTap: () => _pickResult(m),
                          borderRadius: BorderRadius.vertical(
                            top: i == 0 ? const Radius.circular(8) : Radius.zero,
                            bottom: i == _searchResults.length - 1
                                ? const Radius.circular(8)
                                : Radius.zero,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(m.title,
                                          style: theme.textTheme.bodyMedium),
                                      if (meta.isNotEmpty)
                                        Text(meta,
                                            style: theme.textTheme.labelSmall
                                                ?.copyWith(color: subtle)),
                                    ],
                                  ),
                                ),
                                Icon(Icons.chevron_right,
                                    size: 18, color: subtle),
                              ],
                            ),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),

            const SizedBox(height: 12),

            // Manual ID field
            TextFormField(
              controller: _anilistId,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'AniList ID (optional)',
                hintText: 'set automatically when you pick from search',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                return int.tryParse(v.trim()) == null ? 'Must be a number' : null;
              },
            ),

            // Resolved name
            if (_resolvedName != null) ...[
              const SizedBox(height: 6),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  'Resolved: $_resolvedName',
                  style: TextStyle(fontSize: 12, color: subtle),
                ),
              ),
            ],

            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save),
              label: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }
}
