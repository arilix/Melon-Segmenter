import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models.dart';

class MelonStoreException implements Exception {
  final String message;
  MelonStoreException(this.message);
  @override
  String toString() => message;
}

enum MelonSort { idAscending, hstDescending, newestFirst }

/// Local library of melons and their kept (not yet uploaded) photos.
/// Metadata is one JSON file; photos live in a "Captures" folder inside the
/// app's private storage (not visible to other apps).
class MelonStore extends ChangeNotifier {
  List<Melon> melons = [];
  List<CaptureRecord> captures = [];
  late Directory _root;
  late Directory _capturesDir;
  bool ready = false;

  File get _library => File('${_root.path}/library.json');

  Future<void> load() async {
    final base = await getApplicationSupportDirectory();
    _root = Directory('${base.path}/MelonSegmenter')..createSync(recursive: true);
    _capturesDir = Directory('${_root.path}/Captures')..createSync(recursive: true);
    if (_library.existsSync()) {
      try {
        final j = jsonDecode(await _library.readAsString()) as Map<String, dynamic>;
        melons = [for (final m in j['melons'] as List) Melon.fromJson(m as Map<String, dynamic>)];
        captures = [for (final c in j['captures'] as List) CaptureRecord.fromJson(c as Map<String, dynamic>)];
      } catch (_) {}
    }
    for (final c in captures.where((c) => c.status == CaptureStatus.uploaded)) {
      _removeFile(c);
    }
    ready = true;
    notifyListeners();
  }

  Future<void> _save() async {
    final data = jsonEncode({
      'melons': [for (final m in melons) m.toJson()],
      'captures': [for (final c in captures) c.toJson()],
    });
    final tmp = File('${_library.path}.tmp');
    await tmp.writeAsString(data, flush: true);
    await tmp.rename(_library.path);
  }

  File fileOf(CaptureRecord c) => File('${_capturesDir.path}/${c.fileName}');
  void _removeFile(CaptureRecord c) {
    try {
      fileOf(c).deleteSync();
    } catch (_) {}
  }

  // ---- melons ----

  Melon addMelon(String captureIndex, int hst) {
    final index = captureIndex.trim();
    if (index.isEmpty) throw MelonStoreException('Enter an ID for the melon.');
    if (melons.any((m) => m.captureIndex.toLowerCase() == index.toLowerCase())) {
      throw MelonStoreException('A melon with ID "$index" already exists.');
    }
    final melon = Melon(captureIndex: index, plantingDate: Melon.plantingDateFor(hst));
    melons.add(melon);
    _save();
    notifyListeners();
    return melon;
  }

  Melon? melon(String id) {
    for (final m in melons) {
      if (m.id == id) return m;
    }
    return null;
  }

  void moveMelon(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) newIndex -= 1;
    final m = melons.removeAt(oldIndex);
    melons.insert(newIndex, m);
    _save();
    notifyListeners();
  }

  static int _natural(String a, String b) {
    final re = RegExp(r'(\d+|\D+)');
    final pa = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
    final pb = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      final na = int.tryParse(pa[i]), nb = int.tryParse(pb[i]);
      final c = (na != null && nb != null) ? na.compareTo(nb) : pa[i].compareTo(pb[i]);
      if (c != 0) return c;
    }
    return pa.length.compareTo(pb.length);
  }

  void sortMelons(MelonSort order) {
    switch (order) {
      case MelonSort.idAscending:
        melons.sort((a, b) => _natural(a.captureIndex, b.captureIndex));
      case MelonSort.hstDescending:
        melons.sort((a, b) => b.hst().compareTo(a.hst()));
      case MelonSort.newestFirst:
        melons.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    _save();
    notifyListeners();
  }

  void deleteMelon(Melon melon) {
    for (final c in capturesFor(melon.id)) {
      _removeFile(c);
    }
    captures.removeWhere((c) => c.melonId == melon.id);
    melons.removeWhere((m) => m.id == melon.id);
    _save();
    notifyListeners();
  }

  // ---- captures ----

  List<CaptureRecord> capturesFor(String melonId) =>
      captures.where((c) => c.melonId == melonId).toList()..sort((a, b) => b.takenAt.compareTo(a.takenAt));

  int pendingCount(String melonId) =>
      captures.where((c) => c.melonId == melonId && c.status == CaptureStatus.pending).length;

  List<CaptureRecord> get pendingCaptures =>
      captures.where((c) => c.status == CaptureStatus.pending).toList()..sort((a, b) => a.takenAt.compareTo(b.takenAt));

  Future<CaptureRecord> addCapture(Melon melon, Uint8List jpegBytes) async {
    final now = DateTime.now();
    final record = CaptureRecord(
      melonId: melon.id,
      takenAt: now,
      hstAtCapture: melon.hst(now),
      fileName: '${now.microsecondsSinceEpoch}.jpg',
    );
    await fileOf(record).writeAsBytes(jpegBytes, flush: true);
    captures.add(record);
    await _save();
    notifyListeners();
    return record;
  }

  /// Marks a photo uploaded and deletes its file; the record stays as history.
  void markUploaded(String captureId) {
    final i = captures.indexWhere((c) => c.id == captureId);
    if (i < 0) return;
    captures[i].status = CaptureStatus.uploaded;
    _removeFile(captures[i]);
    _save();
    notifyListeners();
  }

  void deleteCapture(CaptureRecord c) {
    _removeFile(c);
    captures.removeWhere((x) => x.id == c.id);
    _save();
    notifyListeners();
  }

  Future<int> usedBytes() async {
    var total = 0;
    for (final f in _capturesDir.listSync().whereType<File>()) {
      total += f.lengthSync();
    }
    return total;
  }
}
