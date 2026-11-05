import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analysis/net_density_analyzer.dart';
import '../segmentation/melon_segmenter.dart';
import '../theme.dart';
import 'processing_flow.dart';

/// Six-panel net analysis: segmentation, grayscale, blur, binary, GNG, metrics.
class ResultView extends StatefulWidget {
  final Cutout cutout;
  final Future<void> Function(NetDensityMetrics metrics, Uint8List segmentedPng, Uint8List overlayPng) onUpload;
  final VoidCallback onBack;
  const ResultView({super.key, required this.cutout, required this.onUpload, required this.onBack});
  @override
  State<ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<ResultView> {
  bool _invert = false;
  double _edgeThickness = 1.0;
  double _dataThickness = 0;
  int _selected = 5;

  bool _analyzing = true;
  String? _error;
  NetDensityMetrics? _metrics;
  NetDensityVisualization? _viz;
  ui.Image? _segmentation, _gray, _blur, _binary, _overlay;
  int _run = 0;

  @override
  void initState() {
    super.initState();
    _loadPrefsAndRun();
  }

  Future<void> _loadPrefsAndRun() async {
    try {
      final p = await SharedPreferences.getInstance();
      _invert = p.getBool('melon.invertPolarity') ?? false;
      _edgeThickness = p.getDouble('melon.edgeThicknessScale') ?? 1.0;
      _dataThickness = p.getDouble('melon.dataThickness') ?? 0;
    } catch (_) {}
    await _analyze();
  }

  Future<void> _savePref(void Function(SharedPreferences) f) async {
    try {
      f(await SharedPreferences.getInstance());
    } catch (_) {}
  }

  Future<void> _analyze() async {
    final run = ++_run;
    setState(() {
      _analyzing = true;
      _error = null;
    });
    try {
      final (m, v) = await NetDensityAnalyzer.analyze(
        rgba: widget.cutout.rgba,
        width: widget.cutout.width,
        height: widget.cutout.height,
        invertPolarity: _invert,
      );
      final n = v.width * v.height;
      final seg = await rgbaToImage(v.rgba, v.width, v.height);
      final gray = await rgbaToImage(NetDensityAnalyzer.renderGray(v.gray, v.mask, n), v.width, v.height);
      final blur = await rgbaToImage(NetDensityAnalyzer.renderGray(v.blur, v.mask, n), v.width, v.height);
      if (!mounted || run != _run) return;
      _segmentation = seg;
      _gray = gray;
      _blur = blur;
      _metrics = m;
      _viz = v;
      await _redrawBinary();
      await _redrawOverlay();
    } catch (e) {
      if (mounted && run == _run) _error = 'Analysis failed: $e';
    }
    if (mounted && run == _run) setState(() => _analyzing = false);
  }

  Future<void> _redrawBinary() async {
    final v = _viz;
    if (v == null) return;
    final img = await rgbaToImage(NetDensityAnalyzer.renderBinary(v, _dataThickness.round()), v.width, v.height);
    if (!mounted) return;
    setState(() => _binary = img);
  }

  Future<ui.Image> _renderOverlay() async {
    final v = _viz!;
    final base = _segmentation!;
    final rec = ui.PictureRecorder();
    final canvas = Canvas(rec);
    canvas.drawImage(base, Offset.zero, Paint());
    final unit = (v.width > v.height ? v.width : v.height) / 300.0;
    final u = (unit < 1 ? 1.0 : unit) * _edgeThickness;
    Path path() {
      final p = Path();
      for (var i = 0; i + 1 < v.graphEdges.length; i += 2) {
        final a = v.graphEdges[i], b = v.graphEdges[i + 1];
        p.moveTo(v.graphX[a], v.graphY[a]);
        p.lineTo(v.graphX[b], v.graphY[b]);
      }
      return p;
    }

    final pth = path();
    Paint stroke(Color c, double w) => Paint()
      ..color = c
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(pth, stroke(Colors.black.withValues(alpha: 0.7), 3 * u));
    canvas.drawPath(pth, stroke(const Color.fromRGBO(255, 38, 38, 1), 1.5 * u));
    return rec.endRecording().toImage(v.width, v.height);
  }

  Future<void> _redrawOverlay() async {
    if (_viz == null || _segmentation == null) return;
    final img = await _renderOverlay();
    if (!mounted) return;
    setState(() => _overlay = img);
  }

  Future<void> _upload() async {
    final m = _metrics!;
    final segPng = await imageToPng(await rgbaToImage(widget.cutout.rgba, widget.cutout.width, widget.cutout.height));
    final overlayPng = await imageToPng(_overlay ?? await _renderOverlay());
    await widget.onUpload(m, segPng, overlayPng);
  }

  @override
  Widget build(BuildContext context) {
    if (_analyzing) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(color: MelonTheme.accentTeal),
          SizedBox(height: 20),
          Text('Analyzing net density…', style: TextStyle(fontSize: 17)),
        ]),
      );
    }
    if (_error != null) {
      return Column(children: [
        const Spacer(),
        const Icon(Icons.warning_amber_rounded, size: 56, color: Colors.orange),
        const SizedBox(height: 12),
        Text(_error!, textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
        const SizedBox(height: 16),
        SwitchListTile(
          title: const Text('Net is lighter than skin', style: TextStyle(fontSize: 13)),
          value: _invert,
          activeThumbColor: MelonTheme.accentTeal,
          onChanged: (v) {
            _invert = v;
            _savePref((p) => p.setBool('melon.invertPolarity', v));
            _analyze();
          },
        ),
        const Spacer(),
        SecondaryButton(label: 'Back', icon: Icons.chevron_left, onPressed: widget.onBack),
      ]);
    }

    final m = _metrics!;
    return Column(children: [
      Expanded(
        child: ListView(children: [
          LayoutBuilder(builder: (ctx, box) {
            final cols = box.maxWidth > 700 ? 3 : 2;
            final w = (box.maxWidth - (cols - 1) * 8) / cols;
            return Wrap(spacing: 8, runSpacing: 10, children: [
              _panel(1, 'Segmentation', _segmentation!, w),
              _panel(2, 'Grayscale', _gray!, w),
              _panel(3, 'Gaussian blur', _blur!, w),
              _panel(4, 'Binary = graph data', _binary ?? _gray!, w),
              _panel(5, 'GNG (pruned)', _overlay ?? _segmentation!, w),
              _metricsPanel(m, w),
            ]);
          }),
          const SizedBox(height: 12),
          _thicknessControl(),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('Net is lighter than skin', style: TextStyle(fontSize: 13, color: Colors.white.withValues(alpha: 0.8))),
            value: _invert,
            activeThumbColor: MelonTheme.accentTeal,
            onChanged: (v) {
              _invert = v;
              _savePref((p) => p.setBool('melon.invertPolarity', v));
              _analyze();
            },
          ),
        ]),
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(child: SecondaryButton(label: 'Back', icon: Icons.chevron_left, onPressed: widget.onBack)),
        const SizedBox(width: 12),
        Expanded(flex: 2, child: PrimaryButton(label: 'Upload All', icon: Icons.cloud_upload, onPressed: _upload)),
      ]),
      const SizedBox(height: 8),
    ]);
  }

  Widget _panel(int number, String title, ui.Image image, double width) {
    final selected = _selected == number;
    return SizedBox(
      width: width,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('$number $title', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.7))),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => setState(() => _selected = number),
          child: AspectRatio(
            aspectRatio: 1,
            child: Container(
              decoration: BoxDecoration(
                color: Colors.black26,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: MelonTheme.accentTeal, width: selected ? 2.5 : 0),
              ),
              padding: const EdgeInsets.all(2),
              child: RawImage(image: image, fit: BoxFit.contain),
            ),
          ),
        ),
      ]),
    );
  }

  Widget _metricsPanel(NetDensityMetrics m, double width) {
    String f(double v, [int d = 1]) => v.toStringAsFixed(d);
    Widget row(String l, double v) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text(l, style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.75))),
          Text(f(v, 2), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: MelonTheme.accentTeal)),
        ]);
    final small = TextStyle(fontSize: 10.5, color: Colors.white.withValues(alpha: 0.75));
    return SizedBox(
      width: width,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('6 Metrics', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.white.withValues(alpha: 0.7))),
        const SizedBox(height: 4),
        AspectRatio(
          aspectRatio: 1,
          child: Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(color: MelonTheme.cardBackground, borderRadius: BorderRadius.circular(10)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              row('Branch density', m.branchDensity),
              const SizedBox(height: 3),
              row('Length density', m.lengthDensity),
              const Divider(height: 12),
              Text('Data: ${m.invertPolarity ? 'net lighter than skin' : 'net darker than skin'} (${f(m.dataFractionOfROI * 100)}% of ROI)', style: small),
              Text('Stroke width ${f(m.strokeWidthPx)}px, diameter ${m.dEq.round()}px', style: small),
              Text('Color Lab: ${f(m.meanL)} / ${f(m.meanA)} / ${f(m.meanB)}', style: small),
              Text('GNG: ${m.nodeCount} nodes, ${m.prunedEdgeCount} pruned edges', style: small),
            ]),
          ),
        ),
      ]),
    );
  }

  Widget _thicknessControl() {
    final style = TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.8));
    return Container(
      padding: const EdgeInsets.all(10),
      width: double.infinity,
      decoration: BoxDecoration(color: MelonTheme.cardBackground, borderRadius: BorderRadius.circular(12)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (_selected == 5) ...[
          Text('Panel 5 – edge thickness: ${_edgeThickness.toStringAsFixed(1)}×', style: style),
          Slider(
            value: _edgeThickness,
            min: 0.3,
            max: 4.0,
            activeColor: MelonTheme.accentTeal,
            onChanged: (v) => setState(() => _edgeThickness = v),
            onChangeEnd: (v) {
              _savePref((p) => p.setDouble('melon.edgeThicknessScale', v));
              _redrawOverlay();
            },
          ),
        ] else if (_selected == 4) ...[
          Text('Panel 4 – net pixel thickness: ${_dataThickness.round()} px', style: style),
          Slider(
            value: _dataThickness,
            min: 0,
            max: 6,
            divisions: 6,
            activeColor: MelonTheme.accentTeal,
            onChanged: (v) => setState(() => _dataThickness = v),
            onChangeEnd: (v) {
              _savePref((p) => p.setDouble('melon.dataThickness', v));
              _redrawBinary();
            },
          ),
          Text('Display only – the metrics are not affected.', style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.5))),
        ] else
          Text('Tap panel 4 or 5 to adjust its thickness.', style: style),
      ]),
    );
  }
}
