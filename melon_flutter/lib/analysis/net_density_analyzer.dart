import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'gng.dart';
import 'seeded_rng.dart';

class NetDensityMetrics {
  final int nodeCount, prunedEdgeCount, roiAreaPx;
  final double branchDensity, lengthDensity, dataFractionOfROI, strokeWidthPx, dEq;
  final double meanL, meanA, meanB;
  final bool invertPolarity;
  const NetDensityMetrics({
    required this.nodeCount,
    required this.prunedEdgeCount,
    required this.roiAreaPx,
    required this.branchDensity,
    required this.lengthDensity,
    required this.dataFractionOfROI,
    required this.strokeWidthPx,
    required this.dEq,
    required this.meanL,
    required this.meanA,
    required this.meanB,
    required this.invertPolarity,
  });
}

/// Everything the result screen needs; all buffers are width*height long
/// (rgba is 4x) and safe to send between isolates.
class NetDensityVisualization {
  final int width, height;
  final Uint8List rgba; // scale-normalized cutout
  final Uint8List gray; // 0..255
  final Uint8List blur; // 0..255
  final Uint8List mask, roi, data; // 0/1
  final Float64List graphX, graphY;
  final Int32List graphEdges; // pairs
  const NetDensityVisualization({
    required this.width,
    required this.height,
    required this.rgba,
    required this.gray,
    required this.blur,
    required this.mask,
    required this.roi,
    required this.data,
    required this.graphX,
    required this.graphY,
    required this.graphEdges,
  });
}

class NetAnalysisException implements Exception {
  final String message;
  NetAnalysisException(this.message);
  @override
  String toString() => message;
}

const _notEnough = 'Not enough net texture was detected to analyze.';
const _invalid = 'The segmented image is invalid.';

class _Input {
  final Uint8List rgba;
  final int width, height;
  final bool invert;
  _Input(this.rgba, this.width, this.height, this.invert);
}

class NetDensityAnalyzer {
  static const targetDiameter = 700.0;
  static const maxUpscale = 4.0;
  static const roiErosionFraction = 0.04;
  static const smallBlurSigma = 1.0;
  static const localBlurFraction = 0.02;
  static const thresholdOffset = 8.0;
  static const maxPoints = 6000;

  /// Runs the full analysis off the UI isolate.
  static Future<(NetDensityMetrics, NetDensityVisualization)> analyze({
    required Uint8List rgba,
    required int width,
    required int height,
    required bool invertPolarity,
  }) {
    final input = _Input(rgba, width, height, invertPolarity);
    return Isolate.run(() => _run(input));
  }

  static (NetDensityMetrics, NetDensityVisualization) _run(_Input input) {
    final w0 = input.width, h0 = input.height;
    // 1. crop to mask bbox
    var minX = w0, minY = h0, maxX = -1, maxY = -1, area = 0;
    for (var y = 0; y < h0; y++) {
      for (var x = 0; x < w0; x++) {
        if (input.rgba[(y * w0 + x) * 4 + 3] > 10) {
          area++;
          if (x < minX) minX = x;
          if (x > maxX) maxX = x;
          if (y < minY) minY = y;
          if (y > maxY) maxY = y;
        }
      }
    }
    if (area == 0 || maxX < minX) throw NetAnalysisException(_invalid);

    final src = img.Image.fromBytes(
      width: w0,
      height: h0,
      bytes: input.rgba.buffer,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    final cropped = img.copyCrop(src, x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1);

    final dOrig = 2 * math.sqrt(area / math.pi);
    final scale = math.min(targetDiameter / dOrig, maxUpscale);
    final newW = math.max(1, (cropped.width * scale).round());
    final newH = math.max(1, (cropped.height * scale).round());
    final resized = img.copyResize(
      cropped,
      width: newW,
      height: newH,
      interpolation: scale < 1 ? img.Interpolation.average : img.Interpolation.cubic,
    );
    final dEq = dOrig * scale;

    final width = resized.width, height = resized.height;
    if (width <= 2 || height <= 2) throw NetAnalysisException(_invalid);
    final n = width * height;
    final rgba = Uint8List(n * 4);
    {
      var o = 0;
      for (final p in resized) {
        rgba[o++] = p.r.toInt();
        rgba[o++] = p.g.toInt();
        rgba[o++] = p.b.toInt();
        rgba[o++] = p.a.toInt();
      }
    }

    final mask = Uint8List(n);
    final gray = Float32List(n);
    for (var i = 0; i < n; i++) {
      mask[i] = rgba[i * 4 + 3] > 10 ? 1 : 0;
      gray[i] = 0.299 * rgba[i * 4] + 0.587 * rgba[i * 4 + 1] + 0.114 * rgba[i * 4 + 2];
    }

    // 2. ROI via chamfer distance transform
    final dist = _chamfer(mask, width, height);
    final erosionPx = roiErosionFraction * dEq;
    final roi = Uint8List(n);
    var roiArea = 0;
    for (var i = 0; i < n; i++) {
      if (mask[i] == 1 && dist[i] >= erosionPx) {
        roi[i] = 1;
        roiArea++;
      }
    }
    if (roiArea == 0) throw NetAnalysisException(_notEnough);

    // 3 & 4. masked blur + adaptive threshold
    final maskF = Float32List(n);
    for (var i = 0; i < n; i++) {
      maskF[i] = mask[i].toDouble();
    }
    final smallBlur = _maskedBlur(gray, maskF, width, height, (v) => _gaussian(v, width, height, smallBlurSigma));
    final localSigma = localBlurFraction * dEq;
    final local = _maskedBlur(smallBlur, maskF, width, height, (v) => _approxGaussian(v, width, height, localSigma));

    final data = Uint8List(n);
    final dataIdx = <int>[];
    for (var i = 0; i < n; i++) {
      if (roi[i] == 0) continue;
      final hit = input.invert ? smallBlur[i] > local[i] + thresholdOffset : smallBlur[i] < local[i] - thresholdOffset;
      if (hit) {
        data[i] = 1;
        dataIdx.add(i);
      }
    }
    if (dataIdx.isEmpty) throw NetAnalysisException(_notEnough);

    // 5. sample, GNG, prune, measure
    final rng = SeededRng(0);
    rng.shuffle(dataIdx);
    final count = math.min(maxPoints, dataIdx.length);
    if (count < 2) throw NetAnalysisException(_notEnough);
    final px = List<double>.generate(count, (i) => (dataIdx[i] % width).toDouble());
    final py = List<double>.generate(count, (i) => (dataIdx[i] ~/ width).toDouble());

    final gng = GrowingNeuralGas();
    gng.train(px, py, rng);
    final pruned = _prune(gng.xs, gng.ys, gng.edgeList);

    final degree = List<int>.filled(gng.nodeCount, 0);
    var totalLength = 0.0;
    for (final (a, b) in pruned) {
      degree[a]++;
      degree[b]++;
      final dx = gng.xs[a] - gng.xs[b], dy = gng.ys[a] - gng.ys[b];
      totalLength += math.sqrt(dx * dx + dy * dy);
    }
    final branchNodes = degree.where((d) => d >= 3).length;
    final dataCount = dataIdx.length;

    final lab = _averageLab(rgba, roi, n);
    final metrics = NetDensityMetrics(
      nodeCount: gng.nodeCount,
      prunedEdgeCount: pruned.length,
      roiAreaPx: roiArea,
      branchDensity: branchNodes / roiArea * 1e4,
      lengthDensity: totalLength / roiArea * 1e3,
      dataFractionOfROI: dataCount / roiArea,
      strokeWidthPx: totalLength > 0 ? dataCount / totalLength : 0,
      dEq: dEq,
      meanL: lab.$1,
      meanA: lab.$2,
      meanB: lab.$3,
      invertPolarity: input.invert,
    );

    Uint8List to8(Float32List f) {
      final o = Uint8List(n);
      for (var i = 0; i < n; i++) {
        o[i] = f[i].clamp(0, 255).round();
      }
      return o;
    }

    final edges = Int32List(pruned.length * 2);
    for (var i = 0; i < pruned.length; i++) {
      edges[i * 2] = pruned[i].$1;
      edges[i * 2 + 1] = pruned[i].$2;
    }
    return (
      metrics,
      NetDensityVisualization(
        width: width,
        height: height,
        rgba: rgba,
        gray: to8(gray),
        blur: to8(smallBlur),
        mask: mask,
        roi: roi,
        data: data,
        graphX: Float64List.fromList(gng.xs),
        graphY: Float64List.fromList(gng.ys),
        graphEdges: edges,
      ),
    );
  }

  // ---- rendering helpers (RGBA buffers) ----

  static Uint8List renderGray(Uint8List values, Uint8List mask, int n) {
    final px = Uint8List(n * 4);
    for (var i = 0; i < n; i++) {
      final v = values[i];
      px[i * 4] = v;
      px[i * 4 + 1] = v;
      px[i * 4 + 2] = v;
      px[i * 4 + 3] = mask[i] == 1 ? 255 : 0;
    }
    return px;
  }

  /// Binary panel; net pixels optionally grown by [radius] px (display only).
  static Uint8List renderBinary(NetDensityVisualization v, int radius) {
    final w = v.width, h = v.height, n = w * h;
    var data = v.data;
    if (radius > 0) {
      final horiz = Uint8List(n);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (data[y * w + x] == 0) continue;
          for (var dx = math.max(0, x - radius); dx <= math.min(w - 1, x + radius); dx++) {
            horiz[y * w + dx] = 1;
          }
        }
      }
      final dil = Uint8List(n);
      for (var y = 0; y < h; y++) {
        for (var x = 0; x < w; x++) {
          if (horiz[y * w + x] == 0) continue;
          for (var dy = math.max(0, y - radius); dy <= math.min(h - 1, y + radius); dy++) {
            dil[dy * w + x] = 1;
          }
        }
      }
      data = dil;
    }
    final px = Uint8List(n * 4);
    for (var i = 0; i < n; i++) {
      final o = i * 4;
      if (v.roi[i] == 1 && data[i] == 1) {
        px[o] = 20; px[o + 1] = 20; px[o + 2] = 20; px[o + 3] = 255;
      } else if (v.roi[i] == 1) {
        px[o] = 255; px[o + 1] = 255; px[o + 2] = 255; px[o + 3] = 255;
      } else if (v.mask[i] == 1) {
        px[o] = 200; px[o + 1] = 215; px[o + 2] = 230; px[o + 3] = 255;
      }
    }
    return px;
  }

  // ---- internals ----

  static Float32List _chamfer(Uint8List mask, int w, int h) {
    const big = 1e6;
    const diag = 1.4142135;
    final d = Float32List(w * h);
    for (var i = 0; i < d.length; i++) {
      d[i] = mask[i] == 1 ? big : 0;
    }
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final i = y * w + x;
        if (mask[i] == 0) continue;
        var b = d[i];
        if (x > 0) b = math.min(b, d[i - 1] + 1);
        if (y > 0) b = math.min(b, d[i - w] + 1);
        if (x > 0 && y > 0) b = math.min(b, d[i - w - 1] + diag);
        if (x < w - 1 && y > 0) b = math.min(b, d[i - w + 1] + diag);
        d[i] = b;
      }
    }
    for (var y = h - 1; y >= 0; y--) {
      for (var x = w - 1; x >= 0; x--) {
        final i = y * w + x;
        if (mask[i] == 0) continue;
        var b = d[i];
        if (x < w - 1) b = math.min(b, d[i + 1] + 1);
        if (y < h - 1) b = math.min(b, d[i + w] + 1);
        if (x < w - 1 && y < h - 1) b = math.min(b, d[i + w + 1] + diag);
        if (x > 0 && y < h - 1) b = math.min(b, d[i + w - 1] + diag);
        d[i] = b;
      }
    }
    return d;
  }

  static Float32List _maskedBlur(
    Float32List values,
    Float32List maskF,
    int w,
    int h,
    Float32List Function(Float32List) blur,
  ) {
    final weighted = Float32List(values.length);
    for (var i = 0; i < weighted.length; i++) {
      weighted[i] = values[i] * maskF[i];
    }
    final num = blur(weighted);
    final den = blur(maskF);
    final out = Float32List(values.length);
    for (var i = 0; i < out.length; i++) {
      out[i] = den[i] > 1e-4 ? num[i] / den[i] : 0;
    }
    return out;
  }

  static Float32List _gaussian(Float32List src, int w, int h, double sigma) {
    final radius = math.max(1, (sigma * 3).round());
    final kernel = Float32List(2 * radius + 1);
    var sum = 0.0;
    for (var i = -radius; i <= radius; i++) {
      final v = math.exp(-(i * i) / (2 * sigma * sigma));
      kernel[i + radius] = v;
      sum += v;
    }
    for (var i = 0; i < kernel.length; i++) {
      kernel[i] /= sum;
    }
    return _conv(_conv(src, w, h, kernel, true), w, h, kernel, false);
  }

  static Float32List _conv(Float32List src, int w, int h, Float32List k, bool horizontal) {
    final r = k.length ~/ 2;
    final out = Float32List(src.length);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var s = 0.0;
        for (var j = -r; j <= r; j++) {
          final sx = horizontal ? (x + j).clamp(0, w - 1) : x;
          final sy = horizontal ? y : (y + j).clamp(0, h - 1);
          s += src[sy * w + sx] * k[j + r];
        }
        out[y * w + x] = s;
      }
    }
    return out;
  }

  static Float32List _approxGaussian(Float32List src, int w, int h, double sigma) {
    final radius = math.max(1, (sigma * 1.7320508).round());
    var r = src;
    for (var p = 0; p < 3; p++) {
      r = _boxBlur(r, w, h, radius);
    }
    return r;
  }

  static Float32List _boxBlur(Float32List src, int w, int h, int radius) {
    final sw = w + 1;
    final sat = Float64List(sw * (h + 1));
    for (var y = 0; y < h; y++) {
      var row = 0.0;
      for (var x = 0; x < w; x++) {
        row += src[y * w + x];
        sat[(y + 1) * sw + x + 1] = sat[y * sw + x + 1] + row;
      }
    }
    final out = Float32List(src.length);
    for (var y = 0; y < h; y++) {
      final y0 = math.max(0, y - radius), y1 = math.min(h - 1, y + radius);
      for (var x = 0; x < w; x++) {
        final x0 = math.max(0, x - radius), x1 = math.min(w - 1, x + radius);
        final area = ((x1 - x0 + 1) * (y1 - y0 + 1)).toDouble();
        final s = sat[(y1 + 1) * sw + x1 + 1] - sat[y0 * sw + x1 + 1] - sat[(y1 + 1) * sw + x0] + sat[y0 * sw + x0];
        out[y * w + x] = s / area;
      }
    }
    return out;
  }

  static List<(int, int)> _prune(List<double> xs, List<double> ys, List<(int, int)> edges) {
    final adj = <int, Set<int>>{};
    for (final (a, b) in edges) {
      (adj[a] ??= {}).add(b);
      (adj[b] ??= {}).add(a);
    }
    double d(int i, int j) {
      final dx = xs[i] - xs[j], dy = ys[i] - ys[j];
      return math.sqrt(dx * dx + dy * dy);
    }

    final kept = <(int, int)>[];
    for (final (a, b) in edges) {
      final ab = d(a, b);
      final common = (adj[a] ?? {}).intersection(adj[b] ?? {});
      final prune = common.any((c) => math.max(d(a, c), d(b, c)) < ab);
      if (!prune) kept.add((a, b));
    }
    return kept;
  }

  static (double, double, double) _averageLab(Uint8List rgba, Uint8List roi, int n) {
    // Cache the linearisation of 0..255 values.
    final lin = Float64List(256);
    for (var i = 0; i < 256; i++) {
      final c = i / 255.0;
      lin[i] = c <= 0.04045 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();
    }
    double f(double t) {
      const delta = 6.0 / 29.0;
      return t > delta * delta * delta ? math.pow(t, 1.0 / 3.0).toDouble() : (t / (3 * delta * delta) + 4.0 / 29.0);
    }

    var sl = 0.0, sa = 0.0, sb = 0.0;
    var count = 0;
    for (var i = 0; i < n; i++) {
      if (roi[i] == 0) continue;
      final rl = lin[rgba[i * 4]], gl = lin[rgba[i * 4 + 1]], bl = lin[rgba[i * 4 + 2]];
      final x = 0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl;
      final y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl;
      final z = 0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl;
      final fx = f(x / 0.95047), fy = f(y), fz = f(z / 1.08883);
      sl += 116 * fy - 16;
      sa += 500 * (fx - fy);
      sb += 200 * (fy - fz);
      count++;
    }
    if (count == 0) return (0, 0, 0);
    return (sl / count, sa / count, sb / count);
  }
}
