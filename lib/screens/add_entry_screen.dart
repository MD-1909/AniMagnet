import 'package:flutter/material.dart';

import '../models/watch_entry.dart';
import '../services/nyaa_service.dart';

/// Automated add flow: search a title on nyaa, show the distinct
/// (group/quality) versions found for episode 1, let the user pick one.
/// Pops the resulting [WatchEntry].
class AddEntryScreen extends StatefulWidget {
  final NyaaService nyaa;
  const AddEntryScreen({super.key, required this.nyaa});

  @override
  State<AddEntryScreen> createState() => _AddEntryScreenState();
}

class _AddEntryScreenState extends State<AddEntryScreen> {
  final _searchCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  String _searchedTitle = '';
  List<ReleaseVersion> _versions = [];

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final title = _searchCtrl.text.trim();
    if (title.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
      _versions = [];
      _searchedTitle = title;
    });
    try {
      final versions = await widget.nyaa.searchVersions(title);
      if (!mounted) return;
      setState(() {
        _versions = versions;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'Search failed: $e';
        _loading = false;
      });
    }
  }

  void _pick(ReleaseVersion v) {
    final entry = WatchEntry(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      title: _searchedTitle,
      group: v.group,
      quality: v.quality,
    );
    Navigator.of(context).pop(entry);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Add anime')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchCtrl,
              textInputAction: TextInputAction.search,
              onSubmitted: (_) => _search(),
              decoration: InputDecoration(
                labelText: 'Search anime title',
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.search),
                  onPressed: _search,
                ),
              ),
            ),
          ),
          if (!_loading && _versions.isNotEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Pick the version you want to track:'),
              ),
            ),
          Expanded(child: _body()),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return _centered(Icons.cloud_off, _error!);
    }
    if (_searchedTitle.isEmpty) {
      return _centered(
          Icons.search, 'Search a title to see available release versions.');
    }
    if (_versions.isEmpty) {
      return _centered(Icons.inbox, 'No releases found for "$_searchedTitle".');
    }
    return ListView.separated(
      itemCount: _versions.length,
      separatorBuilder: (_, __) => const Divider(height: 1),
      itemBuilder: (context, i) {
        final v = _versions[i];
        return ListTile(
          leading: const Icon(Icons.movie_outlined),
          title: Text(v.label),
          subtitle: Text(
            '${v.sampleTitle}\n${v.size}',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          isThreeLine: true,
          trailing: const Icon(Icons.add_circle_outline),
          onTap: () => _pick(v),
        );
      },
    );
  }

  Widget _centered(IconData icon, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
