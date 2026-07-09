import 'dart:async';

import 'package:flutter/material.dart';

import '../models/watch_entry.dart';
import '../services/anilist_service.dart';
import '../services/nyaa_service.dart';

/// Manual add/edit form for a watchlist entry. Returns the saved [WatchEntry]
/// (pop result), or null if cancelled.
class EditEntryScreen extends StatefulWidget {
  final WatchEntry? existing;
  final AniListService anilist;
  final NyaaService nyaa;

  const EditEntryScreen({
    super.key,
    this.existing,
    required this.anilist,
    required this.nyaa,
  });

  @override
  State<EditEntryScreen> createState() => _EditEntryScreenState();
}

class _EditEntryScreenState extends State<EditEntryScreen> {
  static const _knownGroups = ['ASW', 'DKB', 'Judas', 'ToonsHub'];
  static const _qualityOptions = ['480p', '720p', '1080p'];

  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _anilistId;
  late final TextEditingController _searchCtrl;
  late final TextEditingController _customGroupCtrl;

  /// Selected group; null = any, 'OTHER' = custom text in [_customGroupCtrl].
  String? _selectedGroup;

  /// Selected quality; null = Unspecified (no quality filter).
  String? _selectedQuality;

  bool _checkingGroup = false;
  int? _groupReleaseCount; // null = not checked; 0 = checked, none found
  Set<String> _availableQualities = {};
  Timer? _checkDebounce;

  String? _resolvedName;
  List<AniListMedia> _searchResults = [];
  bool _searching = false;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _anilistId = TextEditingController(text: e?.anilistId?.toString() ?? '');
    _searchCtrl = TextEditingController();
    _resolvedName = e?.animeName;

    // Map existing group value to the picker state.
    final eg = e?.group.trim() ?? '';
    if (eg.isEmpty) {
      _selectedGroup = null;
      _customGroupCtrl = TextEditingController();
    } else if (_knownGroups.contains(eg)) {
      _selectedGroup = eg;
      _customGroupCtrl = TextEditingController();
    } else {
      _selectedGroup = 'OTHER';
      _customGroupCtrl = TextEditingController(text: eg);
    }

    // Map existing quality to picker state.
    final eq = e?.quality.trim() ?? '';
    _selectedQuality = _qualityOptions.contains(eq) ? eq : null;

    _anilistId.addListener(() {
      final typed = int.tryParse(_anilistId.text.trim());
      if (typed != widget.existing?.anilistId) {
        if (_resolvedName != null) setState(() => _resolvedName = null);
      }
    });

    // Verify the existing group on the first load.
    if (e != null && eg.isNotEmpty) {
      WidgetsBinding.instance
          .addPostFrameCallback((_) => _checkGroupAvailability());
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _checkDebounce?.cancel();
    _title.dispose();
    _anilistId.dispose();
    _searchCtrl.dispose();
    _customGroupCtrl.dispose();
    super.dispose();
  }

  // ---- Nyaa group check ---------------------------------------------------

  /// The actual group string to filter on, or null when none / not yet typed.
  String? get _effectiveGroup {
    if (_selectedGroup == null) return null;
    if (_selectedGroup == 'OTHER') {
      final t = _customGroupCtrl.text.trim();
      return t.isEmpty ? null : t;
    }
    return _selectedGroup;
  }

  /// The nyaa query title: existing entry's stored title, or the typed value
  /// for new manual entries.
  String get _nyaaTitle => widget.existing?.title ?? _title.text.trim();

  void _debounceGroupCheck() {
    _checkDebounce?.cancel();
    _checkDebounce =
        Timer(const Duration(milliseconds: 600), _checkGroupAvailability);
  }

  Future<void> _checkGroupAvailability() async {
    final title = _nyaaTitle;
    final group = _effectiveGroup;
    if (title.isEmpty || group == null) {
      setState(() {
        _groupReleaseCount = null;
        _availableQualities = {};
      });
      return;
    }
    setState(() {
      _checkingGroup = true;
      _groupReleaseCount = null;
      _availableQualities = {};
    });
    try {
      // Fetch with group filter, no quality filter, to discover available qualities.
      final temp = WatchEntry(id: '', title: title, group: group, quality: '');
      final releases = await widget.nyaa.fetchForEntry(temp);
      if (!mounted) return;
      final qs = <String>{};
      for (final r in releases) {
        final q = NyaaService.extractStandardQuality(r.title);
        if (q != null) qs.add(q);
      }
      setState(() {
        _checkingGroup = false;
        _groupReleaseCount = releases.length;
        _availableQualities = qs;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _checkingGroup = false);
    }
  }

  // ---- AniList search -----------------------------------------------------

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().isEmpty) {
      setState(() {
        _searchResults = [];
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final results = await widget.anilist.searchMultiple(query.trim());
      if (!mounted) return;
      setState(() {
        _searchResults = results;
        _searching = false;
      });
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

  // ---- Save ---------------------------------------------------------------

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final e = widget.existing;
    final newId = int.tryParse(_anilistId.text.trim());
    final idChanged = newId != e?.anilistId;
    final result = WatchEntry(
      id: e?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      title: e?.title ?? _title.text.trim(),
      group: _effectiveGroup ?? '',
      quality: _selectedQuality ?? '',
      anilistId: newId,
      coverUrl: idChanged ? null : e?.coverUrl,
      animeName: idChanged ? _resolvedName : e?.animeName,
      nextAiringAt: idChanged ? null : e?.nextAiringAt,
      nextEpisode: idChanged ? null : e?.nextEpisode,
      addedAt: e?.addedAt,
      notificationsEnabled: e?.notificationsEnabled ?? true,
    );
    Navigator.of(context).pop(result);
  }

  // ---- UI -----------------------------------------------------------------

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
            // Title only shown for new manual entries; locked in for existing.
            if (!editing) ...[
              TextFormField(
                controller: _title,
                decoration: const InputDecoration(
                  labelText: 'Nyaa search title',
                  hintText: 'e.g. Marriage Toxin',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Title is required' : null,
                onChanged: (_) => _debounceGroupCheck(),
              ),
              const SizedBox(height: 20),
            ],

            _groupPicker(theme, subtle),
            const SizedBox(height: 20),

            _qualityPicker(theme),
            const SizedBox(height: 24),

            // ---- AniList ---------------------------------------------------
            Text('AniList', style: theme.textTheme.labelLarge),
            const SizedBox(height: 10),
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
                              setState(() {
                                _searchResults = [];
                                _searching = false;
                              });
                              _debounce?.cancel();
                            },
                          )
                        : null,
              ),
            ),

            if (_searchResults.isNotEmpty) _searchDropdown(theme, subtle),

            const SizedBox(height: 12),
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

  // ---- Group picker -------------------------------------------------------

  Widget _groupPicker(ThemeData theme, Color subtle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Release group', style: theme.textTheme.labelLarge),
        const SizedBox(height: 4),
        Text('Leave blank to match any group',
            style: TextStyle(fontSize: 12, color: subtle)),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final g in _knownGroups)
              _selChip(
                label: g,
                selected: _selectedGroup == g,
                theme: theme,
                onTap: () {
                  setState(() {
                    _selectedGroup = (_selectedGroup == g) ? null : g;
                    _groupReleaseCount = null;
                    _availableQualities = {};
                  });
                  if (_selectedGroup != null) _checkGroupAvailability();
                },
              ),
            _selChip(
              label: 'Other',
              selected: _selectedGroup == 'OTHER',
              theme: theme,
              onTap: () {
                setState(() {
                  _selectedGroup =
                      (_selectedGroup == 'OTHER') ? null : 'OTHER';
                  _groupReleaseCount = null;
                  _availableQualities = {};
                });
              },
            ),
          ],
        ),
        if (_selectedGroup == 'OTHER') ...[
          const SizedBox(height: 12),
          TextField(
            controller: _customGroupCtrl,
            decoration: const InputDecoration(
              labelText: 'Group name',
              hintText: 'e.g. SubsPlease',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => _debounceGroupCheck(),
          ),
        ],
        const SizedBox(height: 8),
        _groupStatusRow(theme),
      ],
    );
  }

  Widget _groupStatusRow(ThemeData theme) {
    if (_checkingGroup) {
      return Row(children: [
        const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(strokeWidth: 2)),
        const SizedBox(width: 8),
        Text('Checking nyaa…',
            style: TextStyle(
                fontSize: 12,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.55))),
      ]);
    }
    final count = _groupReleaseCount;
    if (count == null) return const SizedBox.shrink();
    if (count == 0) {
      return Row(children: [
        Icon(Icons.warning_amber_rounded,
            size: 16, color: theme.colorScheme.error),
        const SizedBox(width: 6),
        Text('No uploads found for this group',
            style: TextStyle(fontSize: 12, color: theme.colorScheme.error)),
      ]);
    }
    return Row(children: [
      const Icon(Icons.check_circle_outline, size: 16, color: Colors.green),
      const SizedBox(width: 6),
      Text('$count release${count == 1 ? '' : 's'} found',
          style: const TextStyle(fontSize: 12, color: Colors.green)),
    ]);
  }

  // ---- Quality picker -----------------------------------------------------

  Widget _qualityPicker(ThemeData theme) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Quality', style: theme.textTheme.labelLarge),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            ..._qualityOptions.map((q) {
              // Grey out qualities the selected group hasn't uploaded,
              // but still let the user pick them (not a hard block).
              final knownUnavailable = _availableQualities.isNotEmpty &&
                  !_availableQualities.contains(q);
              return _selChip(
                label: q,
                selected: _selectedQuality == q,
                dimmed: knownUnavailable,
                theme: theme,
                onTap: () => setState(() =>
                    _selectedQuality = (_selectedQuality == q) ? null : q),
              );
            }),
            _selChip(
              label: 'Unspecified',
              selected: _selectedQuality == null,
              theme: theme,
              onTap: () => setState(() => _selectedQuality = null),
            ),
          ],
        ),
      ],
    );
  }

  // ---- Shared chip widget -------------------------------------------------

  Widget _selChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required ThemeData theme,
    bool dimmed = false,
  }) {
    final cs = theme.colorScheme;
    final bg = selected
        ? cs.primary
        : dimmed
            ? cs.surfaceContainerHighest.withValues(alpha: 0.5)
            : cs.surfaceContainerHighest;
    final fg = selected
        ? cs.onPrimary
        : dimmed
            ? cs.onSurface.withValues(alpha: 0.35)
            : cs.onSurface;
    final border = selected
        ? cs.primary
        : cs.outline.withValues(alpha: dimmed ? 0.2 : 0.4);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(20),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: border),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: fg,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // ---- AniList search dropdown --------------------------------------------

  Widget _searchDropdown(ThemeData theme, Color subtle) {
    return Container(
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
            color: theme.colorScheme.outline.withValues(alpha: 0.3)),
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
                    color: theme.colorScheme.outline.withValues(alpha: 0.2)),
              InkWell(
                onTap: () => _pickResult(m),
                borderRadius: BorderRadius.vertical(
                  top: i == 0 ? const Radius.circular(8) : Radius.zero,
                  bottom: i == _searchResults.length - 1
                      ? const Radius.circular(8)
                      : Radius.zero,
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(m.title, style: theme.textTheme.bodyMedium),
                            if (meta.isNotEmpty)
                              Text(meta,
                                  style: theme.textTheme.labelSmall
                                      ?.copyWith(color: subtle)),
                          ],
                        ),
                      ),
                      Icon(Icons.chevron_right, size: 18, color: subtle),
                    ],
                  ),
                ),
              ),
            ],
          );
        }).toList(),
      ),
    );
  }
}
