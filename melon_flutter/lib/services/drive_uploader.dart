import 'dart:convert';
import 'dart:typed_data';

import 'package:google_sign_in/google_sign_in.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../analysis/net_density_analyzer.dart';

class DriveException implements Exception {
  final String message;
  final int? statusCode;
  DriveException(this.message, [this.statusCode]);
  DriveException.driveScopeNotGranted()
      : message = "Google didn't grant Drive access for this account. In Google Cloud Console, check that the "
            'Drive API is enabled and that this Google account is added as a test user on the OAuth consent '
            'screen, then try again.',
        statusCode = null;
  DriveException.sessionExpired()
      : message = 'Your Google session has expired. Open Settings, sign out, then sign in again and retry. '
            'Your photo is still kept.',
        statusCode = 401;
  @override
  String toString() => message;
}

/// Uploads one capture's artifacts (original photo, segmented cutout, GNG
/// overlay, metrics JSON) to Drive v3 and appends a row to a cumulative CSV.
class DriveUploader {
  static const driveFileScope = 'https://www.googleapis.com/auth/drive.file';
  static const _rootFolder = 'Melon Segmenter';
  static const _logName = 'density_log.csv';

  final GoogleSignInAccount account;
  DriveUploader(this.account);

  Future<Map<String, String>> _headers({bool refresh = false}) async {
    final client = account.authorizationClient;
    final authz = await client.authorizationForScopes([driveFileScope]);
    if (authz == null) throw DriveException.driveScopeNotGranted();
    if (refresh) {
      await client.clearAuthorizationToken(accessToken: authz.accessToken);
      final fresh = await client.authorizationForScopes([driveFileScope]);
      if (fresh == null) throw DriveException.sessionExpired();
      return {'Authorization': 'Bearer ${fresh.accessToken}'};
    }
    return {'Authorization': 'Bearer ${authz.accessToken}'};
  }

  Future<void> uploadCaptureBundle({
    required String captureIndex,
    required int hst,
    required DateTime capturedAt,
    required Uint8List originalPng,
    required Uint8List segmentedPng,
    required Uint8List visualizationPng,
    required NetDensityMetrics metrics,
  }) async {
    Future<void> attempt(bool refresh) async =>
        _uploadOnce(await _headers(refresh: refresh), captureIndex, hst, capturedAt, originalPng, segmentedPng, visualizationPng, metrics);
    try {
      await attempt(false);
    } on DriveException catch (e) {
      if (e.statusCode != 401) rethrow;
      try {
        await attempt(true);
      } on DriveException catch (e2) {
        if (e2.statusCode == 401) throw DriveException.sessionExpired();
        rethrow;
      }
    }
  }

  Future<void> _uploadOnce(
    Map<String, String> h,
    String captureIndex,
    int hst,
    DateTime now,
    Uint8List original,
    Uint8List segmented,
    Uint8List viz,
    NetDensityMetrics m,
  ) async {
    final rootId = await _findOrCreateFolder(_rootFolder, null, h);
    final dateId = await _findOrCreateFolder(DateFormat('dd_MM_yyyy').format(now), rootId, h);
    final timestamp = DateFormat('dd_MM_yyyy HH:mm:ss').format(now);
    final stamp = DateFormat("yyyyMMdd'T'HHmmss").format(now);
    final index = captureIndex.trim();
    final prefix = 'melon-$index-HST$hst-$stamp';

    await _uploadFile(original, '$prefix-original.png', 'image/png', dateId, h);
    await _uploadFile(segmented, '$prefix-segmented.png', 'image/png', dateId, h);
    await _uploadFile(viz, '$prefix-gng.png', 'image/png', dateId, h);

    final json = const JsonEncoder.withIndent('  ').convert({
      'captureIndex': index,
      'hst': hst,
      'date': timestamp,
      'uploadedAt': DateTime.now().toUtc().toIso8601String(),
      'polarity': m.invertPolarity ? 'light' : 'dark',
      'nodeCount': m.nodeCount,
      'prunedEdgeCount': m.prunedEdgeCount,
      'roiAreaPx': m.roiAreaPx,
      'branchDensity': m.branchDensity,
      'lengthDensity': m.lengthDensity,
      'dataFractionOfROI': m.dataFractionOfROI,
      'strokeWidthPx': m.strokeWidthPx,
      'dEq': m.dEq,
      'meanL': m.meanL,
      'meanA': m.meanA,
      'meanB': m.meanB,
    });
    await _uploadFile(Uint8List.fromList(utf8.encode(json)), '$prefix-metrics.json', 'application/json', dateId, h);
    await _appendLogRow(index, hst, timestamp, m, rootId, h);
  }

  Never _fail(http.Response r) {
    var msg = r.body;
    try {
      msg = (jsonDecode(r.body)['error']['message'] as String?) ?? msg;
    } catch (_) {}
    throw DriveException('Upload failed (HTTP ${r.statusCode}): $msg', r.statusCode);
  }

  String _esc(String s) => s.replaceAll(r'\', r'\\').replaceAll("'", r"\'");

  Future<String?> _find(String query, Map<String, String> h) async {
    final r = await http.get(
      Uri.https('www.googleapis.com', '/drive/v3/files', {'q': query, 'fields': 'files(id,name)'}),
      headers: h,
    );
    if (r.statusCode ~/ 100 != 2) _fail(r);
    final files = (jsonDecode(r.body)['files'] as List);
    return files.isEmpty ? null : files.first['id'] as String;
  }

  Future<String> _findOrCreateFolder(String name, String? parent, Map<String, String> h) async {
    final q = "name = '${_esc(name)}' and mimeType = 'application/vnd.google-apps.folder' and trashed = false "
        "and '${parent ?? 'root'}' in parents";
    final existing = await _find(q, h);
    if (existing != null) return existing;
    final r = await http.post(
      Uri.parse('https://www.googleapis.com/drive/v3/files?fields=id'),
      headers: {...h, 'Content-Type': 'application/json; charset=UTF-8'},
      body: jsonEncode({
        'name': name,
        'mimeType': 'application/vnd.google-apps.folder',
        if (parent != null) 'parents': [parent],
      }),
    );
    if (r.statusCode ~/ 100 != 2) _fail(r);
    return jsonDecode(r.body)['id'] as String;
  }

  Future<String> _uploadFile(Uint8List data, String name, String mime, String parent, Map<String, String> h) async {
    final boundary = 'Boundary-${DateTime.now().microsecondsSinceEpoch}';
    final body = BytesBuilder()
      ..add(utf8.encode('--$boundary\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n'))
      ..add(utf8.encode(jsonEncode({'name': name, 'parents': [parent]})))
      ..add(utf8.encode('\r\n--$boundary\r\nContent-Type: $mime\r\n\r\n'))
      ..add(data)
      ..add(utf8.encode('\r\n--$boundary--'));
    final r = await http.post(
      Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=multipart&fields=id'),
      headers: {...h, 'Content-Type': 'multipart/related; boundary=$boundary'},
      body: body.takeBytes(),
    );
    if (r.statusCode ~/ 100 != 2) _fail(r);
    return jsonDecode(r.body)['id'] as String;
  }

  String _csv(String v) => (v.contains(',') || v.contains('"') || v.contains('\n')) ? '"${v.replaceAll('"', '""')}"' : v;

  Future<void> _appendLogRow(String index, int hst, String date, NetDensityMetrics m, String rootId, Map<String, String> h) async {
    const header = 'capture_index,date,polarity,node_count,pruned_edge_count,roi_area_px,branch_density,length_density,'
        'data_fraction_of_roi,stroke_width_px,d_eq,mean_l,mean_a,mean_b,hst\n';
    final polarity = m.invertPolarity ? 'light' : 'dark';
    final row = '${_csv(index)},$date,$polarity,${m.nodeCount},${m.prunedEdgeCount},${m.roiAreaPx},${m.branchDensity},'
        '${m.lengthDensity},${m.dataFractionOfROI},${m.strokeWidthPx},${m.dEq},${m.meanL},${m.meanA},${m.meanB},$hst\n';

    final existing = await _find("name = '$_logName' and trashed = false and '$rootId' in parents", h);
    if (existing != null) {
      final get = await http.get(Uri.parse('https://www.googleapis.com/drive/v3/files/$existing?alt=media'), headers: h);
      if (get.statusCode ~/ 100 != 2) _fail(get);
      final current = utf8.decode(get.bodyBytes);
      final r = await http.patch(
        Uri.parse('https://www.googleapis.com/upload/drive/v3/files/$existing?uploadType=media'),
        headers: {...h, 'Content-Type': 'text/csv'},
        body: utf8.encode(current + row),
      );
      if (r.statusCode ~/ 100 != 2) _fail(r);
    } else {
      await _uploadFile(Uint8List.fromList(utf8.encode(header + row)), _logName, 'text/csv', rootId, h);
    }
  }
}
