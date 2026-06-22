import 'package:flutter/material.dart';

import '../models/watch_entry.dart';

/// Manual add/edit form for a watchlist entry. Returns the saved [WatchEntry]
/// (pop result), or null if cancelled.
class EditEntryScreen extends StatefulWidget {
  final WatchEntry? existing;
  const EditEntryScreen({super.key, this.existing});

  @override
  State<EditEntryScreen> createState() => _EditEntryScreenState();
}

class _EditEntryScreenState extends State<EditEntryScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _title;
  late final TextEditingController _group;
  late final TextEditingController _quality;
  late final TextEditingController _anilistId;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _title = TextEditingController(text: e?.title ?? '');
    _group = TextEditingController(text: e?.group ?? '');
    _quality = TextEditingController(text: e?.quality ?? '');
    _anilistId =
        TextEditingController(text: e?.anilistId?.toString() ?? '');
  }

  @override
  void dispose() {
    _title.dispose();
    _group.dispose();
    _quality.dispose();
    _anilistId.dispose();
    super.dispose();
  }

  void _save() {
    if (!_formKey.currentState!.validate()) return;
    final e = widget.existing;
    final result = WatchEntry(
      id: e?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
      title: _title.text.trim(),
      group: _group.text.trim(),
      quality: _quality.text.trim(),
      anilistId: int.tryParse(_anilistId.text.trim()),
      // Keep cached cover unless the AniList id changed.
      coverUrl: (int.tryParse(_anilistId.text.trim()) == e?.anilistId)
          ? e?.coverUrl
          : null,
      addedAt: e?.addedAt,
      notificationsEnabled: e?.notificationsEnabled ?? true,
    );
    Navigator.of(context).pop(result);
  }

  @override
  Widget build(BuildContext context) {
    final editing = widget.existing != null;
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
            const SizedBox(height: 16),
            TextFormField(
              controller: _anilistId,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'AniList ID (optional)',
                hintText: 'leave blank to auto-detect by title',
                border: OutlineInputBorder(),
              ),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                return int.tryParse(v.trim()) == null ? 'Must be a number' : null;
              },
            ),
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
