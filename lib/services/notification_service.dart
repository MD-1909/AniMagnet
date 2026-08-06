import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models/release.dart';
import '../models/watch_entry.dart';
import 'log_service.dart';
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
    if (nextAiring != null) {
      final candidate = nextAiring.add(airingToNyaaDelay).toLocal();
      if (candidate.isAfter(now)) {
        // If ep3 is >6d 22h away the previous episode aired within the last
        // 2h window. Prefer that sooner notification over scheduling ep3+2h,
        // which covers fresh adds and entries whose nextAiringAt was already
        // bumped to the next episode before this window-guard was in place.
        final prevCandidate = nextAiring
            .subtract(const Duration(days: 7))
            .add(airingToNyaaDelay)
            .toLocal();
        // prevCandidate must be within the next 2h — if it's days away the
        // previous episode hasn't aired yet (show has a non-weekly gap).
        final prevIsImminent = prevCandidate.isAfter(now) &&
            prevCandidate.isBefore(now.add(airingToNyaaDelay));
        final chosen = (prevIsImminent && prevCandidate.isBefore(candidate))
            ? prevCandidate
            : candidate;
        fireAt = chosen;
        LogService.log('NOTIFY',
            '"${entry.displayTitle}" AniList airing $nextAiring → fire ${chosen.toLocal()}');
      }
    }
    if (fireAt == null) {
      final dates =
          releases.map((r) => r.pubDate).whereType<DateTime>().toList();
      final predicted = PostingPredictor.predictNext(dates, now);
      if (predicted != null) {
        fireAt = predicted.add(predictionBuffer);
        LogService.log('NOTIFY',
            '"${entry.displayTitle}" cadence prediction → fire $fireAt');
      }
    }

    if (fireAt == null || !fireAt.isAfter(now)) {
      LogService.log('NOTIFY', '"${entry.displayTitle}" skipped — no valid fire time');
      return;
    }

    final detail = entry.group.isNotEmpty || entry.quality.isNotEmpty
        ? 'Open AniMagnet to grab the ${[
            entry.quality,
            entry.group
          ].where((s) => s.isNotEmpty).join(' ')} release.'
        : 'Open AniMagnet to check for the new release.';

    final exact = await _canUseExactAlarms();
    final scheduleMode = exact
        ? AndroidScheduleMode.exactAllowWhileIdle
        : AndroidScheduleMode.inexactAllowWhileIdle;

    try {
      await _plugin.zonedSchedule(
        id: id,
        title: 'New ${entry.displayTitle} episode likely out',
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
      LogService.log('NOTIFY',
          '"${entry.displayTitle}" scheduled $fireAt (${exact ? "exact" : "inexact"})');
    } catch (e) {
      LogService.log('NOTIFY', '"${entry.displayTitle}" schedule FAILED: $e');
    }
  }

  Future<void> cancelForEntry(WatchEntry entry) async {
    await _plugin.cancel(id: _idFor(entry));
    LogService.log('NOTIFY', '"${entry.displayTitle}" cancelled');
  }
}
