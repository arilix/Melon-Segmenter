import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:melon_segmenter/analysis/net_density_analyzer.dart';
import 'package:melon_segmenter/models.dart';

/// A 400px disk, optionally with a dark grid pattern (the "net") on a light skin.
Uint8List disk({required bool grid}) {
  const size = 400;
  final px = Uint8List(size * size * 4);
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x - size / 2, dy = y - size / 2;
      if (dx * dx + dy * dy > 190 * 190) continue;
      final line = grid && (x % 20 < 3 || y % 20 < 3);
      final v = line ? 60 : 200;
      final o = (y * size + x) * 4;
      px[o] = v;
      px[o + 1] = v;
      px[o + 2] = v;
      px[o + 3] = 255;
    }
  }
  return px;
}

void main() {
  test('detects a grid net and is reproducible', () async {
    final a = await NetDensityAnalyzer.analyze(rgba: disk(grid: true), width: 400, height: 400, invertPolarity: false);
    final b = await NetDensityAnalyzer.analyze(rgba: disk(grid: true), width: 400, height: 400, invertPolarity: false);
    expect(a.$1.branchDensity, greaterThan(0));
    expect(a.$1.lengthDensity, greaterThan(0));
    expect(a.$1.dataFractionOfROI, inInclusiveRange(0.05, 0.6));
    expect(a.$1.branchDensity, b.$1.branchDensity);
    expect(a.$1.lengthDensity, b.$1.lengthDensity);
    expect(a.$1.nodeCount, b.$1.nodeCount);
  });

  test('a plain disk has no net', () async {
    expect(
      NetDensityAnalyzer.analyze(rgba: disk(grid: false), width: 400, height: 400, invertPolarity: false),
      throwsA(isA<NetAnalysisException>()),
    );
  });

  test('HST counts up from the planting date', () {
    final m = Melon(captureIndex: '001', plantingDate: Melon.plantingDateFor(48));
    expect(m.hst(), 48);
    expect(m.hst(DateTime.now().add(const Duration(days: 3))), 51);
  });

  test('capture schedule: weekdays and every-N-days', () {
    final monday = DateTime(2026, 11, 2);
    final s = CaptureSchedule(isEnabled: true, weekdays: {1, 3, 5});
    expect(s.isCaptureDay(monday), isTrue);
    expect(s.isCaptureDay(monday.add(const Duration(days: 1))), isFalse);
    final n = CaptureSchedule(isEnabled: true, mode: ScheduleMode.everyNDays, intervalDays: 3, intervalStart: monday);
    expect(n.isCaptureDay(monday.add(const Duration(days: 6))), isTrue);
    expect(n.isCaptureDay(monday.add(const Duration(days: 4))), isFalse);
    expect(CaptureSchedule.clamp(5 * 60), CaptureSchedule.earliestMinute);
    expect(CaptureSchedule.clamp(20 * 60), CaptureSchedule.latestMinute);
  });
}
