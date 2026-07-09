import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/release.dart';
import '../models/watch_entry.dart';
import 'posting_predictor.dart';

/// Schedules local notifications for each anime, timed to when the episode
/// is expected on nyaa. Uses exact alarms when the permission is granted
/// (survives Doze mode), falling back to inexact alarms otherwise.
class NotificationService {
  static const _channelId = 'episode_alerts';
  static const _channelName = 'Episode alerts';

  /// How long after the AniList broadcast time we expect a release to appear on
  /// nyaa. Quick remux groups (SubsPlease, Erai-raws) post within ~1 h; most
  /// encode groups take 2–4 h. 2 h is a sensible default for actively-tracked
  /// series — adjust if your preferred group is consistently faster or slower.
  static const Duration airingToNyaaDelay = Duration(hours: 2);

  /// Fallback buffer added to the cadence-predicted time (used when AniList has
  /// no upcoming schedule, e.g. for completed series).
  static const Duration predictionBuffer = Duration(minutes: 15);

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  bool _ready = false;

  Future<void> init() async {
    tzdata.initializeTimeZones();
    try {
      final info = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(info.identifier));
    } catch (e) {
      debugPrint('[Notify] timezone init failed, defaulting to UTC: $e');
    }

    const init = InitializationSettings(
      android: AndroidInitializationSettings('@mipmap/ic_launcher'),
    );
    await _plugin.initialize(settings: init);

    // Pre-create the channel so settings are stable before the first fire.
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(const AndroidNotificationChannel(
      _channelId,
      _channelName,
      description: 'Predicted new-episode alerts',
      importance: Importance.high,
    ));
    _ready = true;
  }

  /// Ask for POST_NOTIFICATIONS (Android 13+) and SCHEDULE_EXACT_ALARM
  /// (Android 12+). The exact alarm request opens the system Settings page;
  /// the user only sees it once unless they navigate there themselves.
  Future<void> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
  }

  Future<bool> _canUseExactAlarms() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.canScheduleExactNotifications() ?? false;
  }

  int _idFor(WatchEntry entry) => entry.id.hashCode & 0x7fffffff;

  /// Schedules a test notification using a short delay instead of [airingToNyaaDelay].
  /// Pass [fireIn] to control how soon it fires (default: 1 minute from now).
  Future<void> scheduleTest({
    required String title,
    required int anilistId,
    required DateTime nextAiringAt,
    required int episode,
    Duration fireIn = const Duration(minutes: 1),
  }) async {
    if (!_ready) return;
    const testId = 0x7ffffffe; // fixed id so it's easy to cancel
    await _plugin.cancel(id: testId);

    // Immediate show — confirms channel + POST_NOTIFICATIONS are working
    // regardless of alarm permission. Remove once debugging is done.
    await _plugin.show(
      0x7ffffffd,
      '[TEST] Notification channel works',
      'If you see this, POST_NOTIFICATIONS is granted and the channel is fine. '
      'The scheduled one fires in ${fireIn.inSeconds}s — if it doesn\'t arrive, '
      'check Alarms & Reminders permission and battery optimization.',
      const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId,
          _channelName,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
    
    final fireAt = DateTime.now().add(fireIn);
    final exact = await _canUseExactAlarms();
  
    debugPrint('[Notify][TEST] Scheduling test notif for "$title" ep $episode '
        '(airing: $nextAiringAt) → fires at $fireAt');
  
    try {
      await _plugin.zonedSchedule(
        id: testId,
        title: '[TEST] New $title ep $episode likely out',
        body: 'AniMagnet notification test — airing was ${nextAiringAt.toLocal()}',
        scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'Predicted new-episode alerts',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: exact
            ? AndroidScheduleMode.exactAllowWhileIdle
            : AndroidScheduleMode.inexactAllowWhileIdle,
      );
      debugPrint('[Notify][TEST] Scheduled — will fire in ${fireIn.inSeconds}s');
    } catch (e) {
      debugPrint('[Notify][TEST] Failed: $e');
    }
  }

  /// (Re)schedule the episode alert for one entry. Re-scheduling replaces any
  /// previous alert for the same entry, so this is safe to call on every refresh.
  Future<void> scheduleForEntry(WatchEntry entry, List<Release> releases) async {
    if (!_ready) return;
    final id = _idFor(entry);
    await _plugin.cancel(id: id);

    if (!entry.notificationsEnabled) return; // per-entry alerts switched off

    final now = DateTime.now();

    // Primary: use AniList's broadcast schedule + delay for the group to post.
    // Fallback: predict from nyaa posting history when no schedule is available
    // (e.g. completed series, or before AniList data has been fetched).
    DateTime? fireAt;
    final nextAiring = entry.nextAiringAt;
    if (nextAiring != null && nextAiring.isAfter(now.toUtc())) {
      fireAt = nextAiring.add(airingToNyaaDelay).toLocal();
      debugPrint('[Notify] "${entry.title}" using AniList airing time: $nextAiring');
    } else {
      final dates =
          releases.map((r) => r.pubDate).whereType<DateTime>().toList();
      final predicted = PostingPredictor.predictNext(dates, now);
      if (predicted != null) {
        fireAt = predicted.add(predictionBuffer);
        debugPrint('[Notify] "${entry.title}" using cadence prediction: $predicted');
      }
    }

    if (fireAt == null || !fireAt.isAfter(now)) return;

    final detail = entry.group.isNotEmpty || entry.quality.isNotEmpty
        ? 'Open AniMagnet to grab the ${[
            entry.quality,
            entry.group
          ].where((s) => s.isNotEmpty).join(' ')} release.'
        : 'Open AniMagnet to check for the new release.';

    // Prefer exact alarms — they survive Doze mode and OEM battery savers.
    // Fall back to inexact if the user hasn't granted SCHEDULE_EXACT_ALARM.
    final exact = await _canUseExactAlarms();
    final scheduleMode = exact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;
    debugPrint('[Notify] "${entry.title}" using ${exact ? "exact" : "inexact"} alarm, firing at $fireAt');
    
    try {
      await _plugin.zonedSchedule(
        id: id,
        title: 'New ${entry.title} episode likely out',
        body: detail,
        scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: 'Predicted new-episode alerts',
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: scheduleMode,
      );
      debugPrint('[Notify] "${entry.title}" scheduled for $fireAt');
    } catch (e) {
      debugPrint('[Notify] schedule failed for "${entry.title}": $e');
    }
  }

  Future<void> cancelForEntry(WatchEntry entry) =>
      _plugin.cancel(id: _idFor(entry));
}
