import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
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

  static const _batteryChannel = MethodChannel('animagnet/battery');

  /// Ask for POST_NOTIFICATIONS, SCHEDULE_EXACT_ALARM, and battery optimization
  /// exemption. The exact alarm and battery requests open system Settings pages;
  /// the user only sees each once unless they navigate there themselves.
  Future<void> requestPermission() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    await android?.requestNotificationsPermission();
    await android?.requestExactAlarmsPermission();
    await _requestBatteryExemption();
  }

  /// Opens the system dialog asking the user to exempt this app from battery
  /// optimization. Required on Samsung One UI for AlarmManager broadcasts to
  /// fire reliably — without it, the ScheduledNotificationReceiver is silently
  /// blocked even with SCHEDULE_EXACT_ALARM granted.
  Future<void> _requestBatteryExemption() async {
    try {
      final exempt =
          await _batteryChannel.invokeMethod<bool>('isIgnoringBatteryOptimizations') ?? false;
      if (!exempt) {
        await _batteryChannel.invokeMethod('requestIgnoreBatteryOptimizations');
      }
    } catch (e) {
      debugPrint('[Notify] battery exemption request failed: $e');
    }
  }

  Future<bool> _canUseExactAlarms() async {
    final android = _plugin.resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin>();
    return await android?.canScheduleExactNotifications() ?? false;
  }

  int _idFor(WatchEntry entry) => entry.id.hashCode & 0x7fffffff;

  /// Schedules a test notification. Returns a status string to show the user.
  Future<String> scheduleTest({
    required String title,
    required int anilistId,
    required DateTime nextAiringAt,
    required int episode,
    Duration fireIn = const Duration(seconds: 10),
  }) async {
    if (!_ready) return 'NotificationService not ready';
    const testId = 0x7ffffffe;
    await _plugin.cancel(id: testId);

    await _plugin.show(
      id: 0x7ffffffd,
      title: '[TEST] Channel check',
      body: 'Immediate notification — scheduled one follows in ${fireIn.inSeconds}s',
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          _channelId, _channelName,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );

    final fireAt = DateTime.now().add(fireIn);
    final tzFireAt = tz.TZDateTime.from(fireAt, tz.local);
    final exact = await _canUseExactAlarms();
    // alarmClock mode: highest-priority alarm, shows in system clock, cannot
    // be deferred by OEM battery managers. For testing only.
    final mode = exact
        ? AndroidScheduleMode.alarmClock
        : AndroidScheduleMode.inexactAllowWhileIdle;

    // Dart-timer path: fires only while the app is open, but bypasses
    // AlarmManager entirely. If this fires but zonedSchedule doesn't,
    // the issue is AlarmManager / One UI blocking the broadcast receiver.
    Future.delayed(fireIn, () {
      _plugin.show(
        id: 0x7ffffffc,
        title: '[TEST] Dart timer fired ✓',
        body: 'Future.delayed worked — if AlarmManager one is missing, '
            'One UI is blocking the broadcast receiver',
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId, _channelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
      );
    });

    try {
      await _plugin.zonedSchedule(
        id: testId,
        title: '[TEST] AlarmManager fired ✓',
        body: 'zonedSchedule (${exact ? "alarmClock" : "inexact"}) worked',
        scheduledDate: tzFireAt,
        notificationDetails: const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId, _channelName,
            importance: Importance.high,
            priority: Priority.high,
          ),
        ),
        androidScheduleMode: mode,
      );
      return 'Both scheduled for +${fireIn.inSeconds}s — keep app open. '
          'Expect 2 notifs: "Dart timer" + "AlarmManager"';
    } catch (e) {
      return 'zonedSchedule FAILED: $e';
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
