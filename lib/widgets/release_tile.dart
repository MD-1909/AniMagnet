import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/release.dart';

/// Compact release row used in the right-hand column of an anime card:
/// a NEW dot, the title, and size/date/seeders metadata. Tapping the row
/// opens the magnet link in the OS torrent handler.
class ReleaseTile extends StatelessWidget {
  final Release release;
  final bool isNew;
  final VoidCallback onMagnet;

  /// When true the row is in multi-select mode: a tap toggles selection
  /// (via [onSelectToggle]) instead of opening the magnet link.
  final bool selectionMode;
  final bool selected;
  final VoidCallback? onLongPress;
  final VoidCallback? onSelectToggle;

  const ReleaseTile({
    super.key,
    required this.release,
    required this.isNew,
    required this.onMagnet,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
    this.onSelectToggle,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final date = release.pubDate != null
        ? DateFormat('d MMM yyyy').format(release.pubDate!)
        : 'unknown date';

    return InkWell(
      onTap: selectionMode
          ? onSelectToggle
          : (release.magnet.isEmpty ? null : onMagnet),
      onLongPress: onLongPress,
      child: Container(
        color: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.16)
            : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2, right: 8),
              child: selectionMode
                  ? Icon(
                      selected
                          ? Icons.check_circle
                          : Icons.radio_button_unchecked,
                      size: 18,
                      color: selected
                          ? theme.colorScheme.primary
                          : theme.dividerColor,
                    )
                  : Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: isNew
                              ? Colors.green
                              : Colors.transparent,
                          border: isNew
                              ? null
                              : Border.all(
                                  color: theme.dividerColor, width: 1.5),
                        ),
                      ),
                    ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    release.title,
                    style: theme.textTheme.bodySmall,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 3),
                  Wrap(
                    spacing: 10,
                    children: [
                      _meta(theme, Icons.sd_storage, release.size),
                      _meta(theme, Icons.schedule, date),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _meta(ThemeData theme, IconData icon, String text) {
    final style = theme.textTheme.labelSmall?.copyWith(color: Colors.grey);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 12, color: Colors.grey),
        const SizedBox(width: 3),
        Text(text, style: style),
      ],
    );
  }
}
