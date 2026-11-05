import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

import '../models.dart';

/// Holds the capture schedule and keeps local reminders in step with it.
class ScheduleStore extends ChangeNotifier {
  static const _key = 'melon.captureSchedule';
  static const _weekdayBase = 1000; // ids 1001..1007
  static const _dayBase = 2000;

  CaptureSchedule schedule = CaptureSchedule();
  bool notificationsBlocked = false;
  final _plugin = FlutterLocalNotificationsPlugin();
  var _tzReady = false;

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw != null) {
      try {
        schedule = CaptureSchedule.fromJson(jsonDecode(raw) as Map<String, dynamic>);
      } catch (_) {}
    }
    await _plugin.initialize(
      settings: const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')),
    );
    notifyListeners();
    await reschedule();
  }

  Future<void> update(CaptureSchedule next) async {
    schedule = next;
    notifyListeners();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(next.toJson()));
    await reschedule();
  }

  Future<void> _initTz() async {
    if (_tzReady) return;
    tzdata.initializeTimeZones();
    try {
      final name = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(name.identifier));
    } catch (_) {}
    _tzReady = true;
  }

  Future<void> reschedule() async {
    await _plugin.cancelAll();
    if (!schedule.isEnabled) {
      notificationsBlocked = false;
      notifyListeners();
      return;
    }
    final android = _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    final granted = await android?.requestNotificationsPermission();
    notificationsBlocked = granted == false;
    notifyListeners();
    if (notificationsBlocked) return;
    await android?.requestExactAlarmsPermission();
    await _initTz();

    final minute = CaptureSchedule.clamp(schedule.reminderMinuteOfDay);
    final details = const NotificationDetails(
      android: AndroidNotificationDetails(
        'capture_reminders',
        'Capture reminders',
        channelDescription: 'Reminds you to photograph your melons',
        importance: Importance.high,
        priority: Priority.high,
      ),
    );
    const title = 'Time to collect melon data';
    const body = "Take today's photos of your melons.";

    Future<void> add(int id, tz.TZDateTime when, DateTimeComponents? repeat) => _plugin.zonedSchedule(
          id: id,
          title: title,
          body: body,
          scheduledDate: when,
          notificationDetails: details,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          matchDateTimeComponents: repeat,
        );

    switch (schedule.mode) {
      case ScheduleMode.weekdays:
        for (final wd in schedule.weekdays) {
          final now = tz.TZDateTime.now(tz.local);
          var when = tz.TZDateTime(tz.local, now.year, now.month, now.day, minute ~/ 60, minute % 60);
          while (when.weekday != wd || !when.isAfter(now)) {
            when = when.add(const Duration(days: 1));
          }
          await add(_weekdayBase + wd, when, DateTimeComponents.dayOfWeekAndTime);
        }
      case ScheduleMode.everyNDays:
        var i = 0;
        for (final m in schedule.upcomingReminders(count: 60)) {
          final when = tz.TZDateTime.from(m, tz.local);
          await add(_dayBase + i++, when, null);
        }
    }
  }
}
