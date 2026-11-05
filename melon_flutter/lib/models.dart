import 'package:uuid/uuid.dart';

const _uuid = Uuid();

DateTime startOfDay(DateTime d) => DateTime(d.year, d.month, d.day);

int daysBetween(DateTime from, DateTime to) {
  final a = DateTime.utc(from.year, from.month, from.day);
  final b = DateTime.utc(to.year, to.month, to.day);
  return b.difference(a).inDays;
}

/// One melon being tracked. HST (days after planting) is entered once; it is
/// stored as a planting date so the current HST can be derived at any time.
class Melon {
  final String id;
  String captureIndex;
  DateTime plantingDate;
  DateTime createdAt;

  Melon({String? id, required this.captureIndex, required this.plantingDate, DateTime? createdAt})
      : id = id ?? _uuid.v4(),
        createdAt = createdAt ?? DateTime.now();

  int hst([DateTime? on]) => daysBetween(plantingDate, on ?? DateTime.now()).clamp(0, 1 << 30);

  static DateTime plantingDateFor(int hst, [DateTime? on]) =>
      startOfDay(on ?? DateTime.now()).subtract(Duration(days: hst));

  Map<String, dynamic> toJson() => {
        'id': id,
        'captureIndex': captureIndex,
        'plantingDate': plantingDate.toIso8601String(),
        'createdAt': createdAt.toIso8601String(),
      };

  factory Melon.fromJson(Map<String, dynamic> j) => Melon(
        id: j['id'] as String,
        captureIndex: j['captureIndex'] as String,
        plantingDate: DateTime.parse(j['plantingDate'] as String),
        createdAt: DateTime.parse(j['createdAt'] as String),
      );
}

enum CaptureStatus { pending, uploaded }

/// A photo kept for a melon, waiting to be segmented / analyzed / uploaded.
class CaptureRecord {
  final String id;
  final String melonId;
  final DateTime takenAt;
  final int hstAtCapture;
  final String fileName;
  CaptureStatus status;

  CaptureRecord({
    String? id,
    required this.melonId,
    required this.takenAt,
    required this.hstAtCapture,
    required this.fileName,
    this.status = CaptureStatus.pending,
  }) : id = id ?? _uuid.v4();

  Map<String, dynamic> toJson() => {
        'id': id,
        'melonId': melonId,
        'takenAt': takenAt.toIso8601String(),
        'hstAtCapture': hstAtCapture,
        'fileName': fileName,
        'status': status.name,
      };

  factory CaptureRecord.fromJson(Map<String, dynamic> j) => CaptureRecord(
        id: j['id'] as String,
        melonId: j['melonId'] as String,
        takenAt: DateTime.parse(j['takenAt'] as String),
        hstAtCapture: j['hstAtCapture'] as int,
        fileName: j['fileName'] as String,
        status: CaptureStatus.values.firstWhere((s) => s.name == j['status'], orElse: () => CaptureStatus.pending),
      );
}

enum ScheduleMode { weekdays, everyNDays }

/// When data should be collected. Weekdays use DateTime.monday(1)..sunday(7).
class CaptureSchedule {
  bool isEnabled;
  ScheduleMode mode;
  Set<int> weekdays;
  int intervalDays;
  DateTime intervalStart;
  int reminderMinuteOfDay;

  static const earliestMinute = 6 * 60;
  static const latestMinute = 17 * 60 + 30;
  static int clamp(int m) => m.clamp(earliestMinute, latestMinute);

  CaptureSchedule({
    this.isEnabled = false,
    this.mode = ScheduleMode.weekdays,
    Set<int>? weekdays,
    this.intervalDays = 2,
    DateTime? intervalStart,
    this.reminderMinuteOfDay = 7 * 60,
  })  : weekdays = weekdays ?? {1, 3, 5},
        intervalStart = intervalStart ?? startOfDay(DateTime.now());

  CaptureSchedule copy() => CaptureSchedule(
        isEnabled: isEnabled,
        mode: mode,
        weekdays: {...weekdays},
        intervalDays: intervalDays,
        intervalStart: intervalStart,
        reminderMinuteOfDay: reminderMinuteOfDay,
      );

  bool isCaptureDay(DateTime date) {
    switch (mode) {
      case ScheduleMode.weekdays:
        return weekdays.contains(date.weekday);
      case ScheduleMode.everyNDays:
        final days = daysBetween(intervalStart, date);
        return days >= 0 && days % (intervalDays < 1 ? 1 : intervalDays) == 0;
    }
  }

  DateTime reminderDate(DateTime day) {
    final m = clamp(reminderMinuteOfDay);
    return DateTime(day.year, day.month, day.day, m ~/ 60, m % 60);
  }

  List<DateTime> upcomingReminders({DateTime? after, required int count}) {
    if (!isEnabled) return [];
    final now = after ?? DateTime.now();
    final today = startOfDay(now);
    final out = <DateTime>[];
    for (var offset = 0; offset < 800 && out.length < count; offset++) {
      final day = DateTime(today.year, today.month, today.day + offset);
      if (!isCaptureDay(day)) continue;
      final moment = reminderDate(day);
      if (moment.isAfter(now)) out.add(moment);
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'isEnabled': isEnabled,
        'mode': mode.name,
        'weekdays': weekdays.toList(),
        'intervalDays': intervalDays,
        'intervalStart': intervalStart.toIso8601String(),
        'reminderMinuteOfDay': reminderMinuteOfDay,
      };

  factory CaptureSchedule.fromJson(Map<String, dynamic> j) => CaptureSchedule(
        isEnabled: j['isEnabled'] as bool? ?? false,
        mode: ScheduleMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => ScheduleMode.weekdays),
        weekdays: ((j['weekdays'] as List?) ?? [1, 3, 5]).cast<int>().toSet(),
        intervalDays: j['intervalDays'] as int? ?? 2,
        intervalStart: DateTime.tryParse(j['intervalStart'] as String? ?? ''),
        reminderMinuteOfDay: clamp(j['reminderMinuteOfDay'] as int? ?? 7 * 60),
      );
}
