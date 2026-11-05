import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';

class SegmentationException implements Exception {
  final String message;
  SegmentationException(this.message);
  @override
  String toString() => message;
}

/// A transparent-background, bounding-box-cropped cutout.
class Cutout {
  final Uint8List rgba;
  final int width, height;
  const Cutout(this.rgba, this.width, this.height);
}

/// MobileSAM (ONNX) running in its own isolate so the UI never blocks.
/// The photo is encoded once; each tap only runs the small mask decoder.
class MelonSegmenter {
  static const maxLongSide = 2048;

  Isolate? _isolate;
  SendPort? _send;
  final _pending = <int, Completer<dynamic>>{};
  var _nextId = 0;
  Future<void>? _starting;

  Future<void> _ensureStarted() => _starting ??= _start();

  Future<void> _start() async {
    final enc = (await rootBundle.load('assets/models/mobilesam.encoder.onnx')).buffer.asUint8List();
    final dec = (await rootBundle.load('assets/models/mobilesam.decoder.onnx')).buffer.asUint8List();
    final receive = ReceivePort();
    _isolate = await Isolate.spawn(_worker, receive.sendPort);
    final ready = Completer<void>();
    receive.listen((msg) {
      if (msg is SendPort) {
        _send = msg;
        msg.send({
          'op': 'init',
          'id': -1,
          'enc': TransferableTypedData.fromList([enc]),
          'dec': TransferableTypedData.fromList([dec]),
        });
      } else if (msg is Map) {
        final id = msg['id'] as int;
        if (id == -1) {
          msg['error'] == null ? ready.complete() : ready.completeError(SegmentationException(msg['error'] as String));
          return;
        }
        final c = _pending.remove(id);
        if (c == null) return;
        msg['error'] != null ? c.completeError(SegmentationException(msg['error'] as String)) : c.complete(msg['result']);
      }
    });
    await ready.future;
  }

  Future<dynamic> _call(String op, Map<String, dynamic> args) async {
    await _ensureStarted();
    final id = _nextId++;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _send!.send({'op': op, 'id': id, ...args});
    return c.future;
  }

  /// Decodes and encodes a photo; must be called before [segment].
  Future<void> setImage(Uint8List fileBytes) async {
    await _call('setImage', {'bytes': TransferableTypedData.fromList([fileBytes])});
  }

  /// [fx]/[fy] are the tap position as fractions (0..1) of the photo.
  Future<Cutout> segment(double fx, double fy) async {
    final r = await _call('segment', {'fx': fx, 'fy': fy}) as Map;
    return Cutout(
      (r['rgba'] as TransferableTypedData).materialize().asUint8List(),
      r['w'] as int,
      r['h'] as int,
    );
  }

  /// The (orientation-corrected, size-capped) photo as PNG, for upload.
  Future<Uint8List> originalPng() async {
    final r = await _call('originalPng', {});
    return (r as TransferableTypedData).materialize().asUint8List();
  }

  void dispose() {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _send = null;
    _starting = null;
  }
}

// ---------------------------------------------------------------------------
// Worker isolate
// ---------------------------------------------------------------------------

void _worker(SendPort main) {
  final port = ReceivePort();
  main.send(port.sendPort);

  OrtSession? encoder, decoder;
  img.Image? photo; // capped, orientation-baked, RGBA
  OrtValueTensor? embedding;
  int resizedW = 0, resizedH = 0;

  port.listen((raw) {
    final msg = raw as Map;
    final id = msg['id'] as int;
    try {
      dynamic result;
      switch (msg['op']) {
        case 'init':
          OrtEnv.instance.init();
          final opts = OrtSessionOptions()..setIntraOpNumThreads(4);
          encoder = OrtSession.fromBuffer((msg['enc'] as TransferableTypedData).materialize().asUint8List(), opts);
          decoder = OrtSession.fromBuffer((msg['dec'] as TransferableTypedData).materialize().asUint8List(), opts);
        case 'setImage':
          final bytes = (msg['bytes'] as TransferableTypedData).materialize().asUint8List();
          var decoded = img.decodeImage(bytes);
          if (decoded == null) throw SegmentationException('Could not read the photo.');
          decoded = img.bakeOrientation(decoded);
          final long = math.max(decoded.width, decoded.height);
          if (long > MelonSegmenter.maxLongSide) {
            final s = MelonSegmenter.maxLongSide / long;
            decoded = img.copyResize(
              decoded,
              width: (decoded.width * s).round(),
              height: (decoded.height * s).round(),
              interpolation: img.Interpolation.average,
            );
          }
          photo = decoded.numChannels == 4 ? decoded : decoded.convert(numChannels: 4);

          // Encoder expects the image resized so its long side is 1024 (it pads itself).
          final s = 1024 / math.max(photo!.width, photo!.height);
          resizedW = (photo!.width * s).round();
          resizedH = (photo!.height * s).round();
          final small = img.copyResize(photo!, width: resizedW, height: resizedH, interpolation: img.Interpolation.linear);
          final data = Float32List(resizedW * resizedH * 3);
          var o = 0;
          for (final p in small) {
            data[o++] = p.r.toDouble();
            data[o++] = p.g.toDouble();
            data[o++] = p.b.toDouble();
          }
          final input = OrtValueTensor.createTensorWithDataList([data], [resizedH, resizedW, 3]);
          final runOptions = OrtRunOptions();
          final out = encoder!.run(runOptions, {'input_image': input});
          input.release();
          runOptions.release();
          embedding?.release();
          embedding = out[0] as OrtValueTensor;
        case 'segment':
          if (photo == null || embedding == null) throw SegmentationException('No photo loaded.');
          final fx = msg['fx'] as double, fy = msg['fy'] as double;
          final px = fx * resizedW, py = fy * resizedH;
          final coords = OrtValueTensor.createTensorWithDataList([Float32List.fromList([px, py, 0, 0])], [1, 2, 2]);
          final labels = OrtValueTensor.createTensorWithDataList([Float32List.fromList([1, -1])], [1, 2]);
          final maskIn = OrtValueTensor.createTensorWithDataList([Float32List(256 * 256)], [1, 1, 256, 256]);
          final hasMask = OrtValueTensor.createTensorWithDataList([Float32List.fromList([0])], [1]);
          final size = OrtValueTensor.createTensorWithDataList(
            [Float32List.fromList([resizedH.toDouble(), resizedW.toDouble()])],
            [2],
          );
          final runOptions = OrtRunOptions();
          final out = decoder!.run(runOptions, {
            'image_embeddings': embedding!,
            'point_coords': coords,
            'point_labels': labels,
            'mask_input': maskIn,
            'has_mask_input': hasMask,
            'orig_im_size': size,
          });
          for (final t in [coords, labels, maskIn, hasMask, size]) {
            t.release();
          }
          runOptions.release();
          final maskValue = (out[0] as OrtValueTensor).value as List; // [1,1,H,W]
          final rows = ((maskValue[0] as List)[0]) as List;
          for (final o in out) {
            o?.release();
          }
          result = _buildCutout(photo!, rows, resizedW, resizedH);
        case 'originalPng':
          if (photo == null) throw SegmentationException('No photo loaded.');
          result = TransferableTypedData.fromList([img.encodePng(photo!)]);
        default:
          throw SegmentationException('Unknown op ${msg['op']}');
      }
      main.send({'id': id, 'result': result});
    } catch (e) {
      main.send({'id': id, 'error': e is SegmentationException ? e.message : 'Segmentation failed: $e'});
    }
  });
}

/// Upscales the 1024-scale mask to the photo and cuts the melon out.
Map<String, dynamic> _buildCutout(img.Image photo, List rows, int mw, int mh) {
  final w = photo.width, h = photo.height;
  final mask = Uint8List(mw * mh);
  for (var y = 0; y < mh; y++) {
    final row = rows[y] as List;
    for (var x = 0; x < mw; x++) {
      mask[y * mw + x] = (row[x] as double) > 0 ? 255 : 0;
    }
  }
  final rgba = Uint8List(w * h * 4);
  var minX = w, minY = h, maxX = -1, maxY = -1;
  final src = photo.toUint8List();
  for (var y = 0; y < h; y++) {
    final fy = ((y + 0.5) * mh / h - 0.5).clamp(0, mh - 1).toDouble();
    final y0 = fy.floor(), y1 = math.min(mh - 1, y0 + 1), ty = fy - y0;
    for (var x = 0; x < w; x++) {
      final fx = ((x + 0.5) * mw / w - 0.5).clamp(0, mw - 1).toDouble();
      final x0 = fx.floor(), x1 = math.min(mw - 1, x0 + 1), tx = fx - x0;
      final v = (mask[y0 * mw + x0] * (1 - tx) + mask[y0 * mw + x1] * tx) * (1 - ty) +
          (mask[y1 * mw + x0] * (1 - tx) + mask[y1 * mw + x1] * tx) * ty;
      if (v >= 127.5) {
        final o = (y * w + x) * 4;
        rgba[o] = src[o];
        rgba[o + 1] = src[o + 1];
        rgba[o + 2] = src[o + 2];
        rgba[o + 3] = 255;
        if (x < minX) minX = x;
        if (x > maxX) maxX = x;
        if (y < minY) minY = y;
        if (y > maxY) maxY = y;
      }
    }
  }
  if (maxX < minX) throw SegmentationException('No object found there. Tap on the melon.');
  final cw = maxX - minX + 1, ch = maxY - minY + 1;
  final out = Uint8List(cw * ch * 4);
  for (var y = 0; y < ch; y++) {
    out.setRange(y * cw * 4, (y + 1) * cw * 4, rgba, ((y + minY) * w + minX) * 4);
  }
  return {'rgba': TransferableTypedData.fromList([out]), 'w': cw, 'h': ch};
}
