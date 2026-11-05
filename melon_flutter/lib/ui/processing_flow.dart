import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../analysis/net_density_analyzer.dart';
import '../segmentation/melon_segmenter.dart';
import '../services/drive_uploader.dart';
import '../store/auth_manager.dart';
import '../store/melon_store.dart';
import '../theme.dart';
import 'result_view.dart';
import 'segmentation_view.dart';

/// Runs the flow for each queued photo in turn. Leaving with Back stops the queue.
class ProcessingQueueScreen extends StatefulWidget {
  final List<String> captureIds;
  const ProcessingQueueScreen({super.key, required this.captureIds});
  @override
  State<ProcessingQueueScreen> createState() => _ProcessingQueueScreenState();
}

class _ProcessingQueueScreenState extends State<ProcessingQueueScreen> {
  int _position = 0;

  void _advance() {
    if (_position + 1 < widget.captureIds.length) {
      setState(() => _position++);
    } else {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.read<MelonStore>();
    final count = widget.captureIds.length;
    final id = widget.captureIds[_position];
    final capture = store.captures.where((c) => c.id == id).firstOrNull;
    final melon = capture == null ? null : store.melon(capture.melonId);
    if (capture == null || melon == null || !store.fileOf(capture).existsSync()) {
      // Photo is gone (deleted meanwhile): skip it.
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _advance() : null);
      return const Scaffold(body: SizedBox.shrink());
    }
    return ProcessingFlow(
      key: ValueKey(capture.id),
      photoFile: store.fileOf(capture),
      captureIndex: melon.captureIndex,
      hst: capture.hstAtCapture,
      capturedAt: capture.takenAt,
      progress: count > 1 ? '${_position + 1} of $count' : null,
      doneTitle: _position + 1 < count ? 'Next photo' : 'Done',
      onClose: (uploaded) {
        if (uploaded) {
          store.markUploaded(capture.id);
          _advance();
        } else {
          Navigator.of(context).pop();
        }
      },
    );
  }
}

enum _Stage { segmenting, analyzing, uploading, success, failure }

/// Segment one kept photo with SAM, analyze its net, upload the result.
class ProcessingFlow extends StatefulWidget {
  final dynamic photoFile; // dart:io File
  final String captureIndex;
  final int hst;
  final DateTime capturedAt;
  final String? progress;
  final String doneTitle;
  final void Function(bool uploaded) onClose;
  const ProcessingFlow({
    super.key,
    required this.photoFile,
    required this.captureIndex,
    required this.hst,
    required this.capturedAt,
    required this.onClose,
    this.progress,
    this.doneTitle = 'Done',
  });
  @override
  State<ProcessingFlow> createState() => _ProcessingFlowState();
}

class _ProcessingFlowState extends State<ProcessingFlow> {
  final _segmenter = MelonSegmenter();
  _Stage _stage = _Stage.segmenting;
  Cutout? _cutout;
  String _error = '';

  @override
  void dispose() {
    _segmenter.dispose();
    super.dispose();
  }

  Future<void> _upload(NetDensityMetrics metrics, Uint8List segmentedPng, Uint8List overlayPng) async {
    final auth = context.read<AuthManager>();
    final user = auth.user;
    if (user == null) {
      setState(() {
        _stage = _Stage.failure;
        _error = 'Not signed in. Open Settings from the Melons screen, sign in with Google, then retry. Your photo is still kept.';
      });
      return;
    }
    setState(() => _stage = _Stage.uploading);
    try {
      final original = await _segmenter.originalPng();
      await DriveUploader(user).uploadCaptureBundle(
        captureIndex: widget.captureIndex,
        hst: widget.hst,
        capturedAt: widget.capturedAt,
        originalPng: original,
        segmentedPng: segmentedPng,
        visualizationPng: overlayPng,
        metrics: metrics,
      );
      if (mounted) setState(() => _stage = _Stage.success);
    } catch (e) {
      if (mounted) {
        setState(() {
          _stage = _Stage.failure;
          _error = 'Upload failed: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final subtitle = 'Melon ${widget.captureIndex} · HST ${widget.hst}${widget.progress == null ? '' : ' · photo ${widget.progress}'}';
    return PopScope(
      canPop: _stage != _Stage.uploading,
      child: Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(children: [
              const Align(alignment: Alignment.centerLeft, child: MelonHeader()),
              const SizedBox(height: 12),
              Text(subtitle, style: const TextStyle(color: MelonTheme.accentTeal, fontSize: 13, fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              Expanded(child: _body()),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _body() {
    switch (_stage) {
      case _Stage.segmenting:
        return SegmentationView(
          segmenter: _segmenter,
          photoFile: widget.photoFile,
          onConfirm: (cutout) => setState(() {
            _cutout = cutout;
            _stage = _Stage.analyzing;
          }),
          onBack: () => widget.onClose(false),
        );
      case _Stage.analyzing:
        return ResultView(
          cutout: _cutout!,
          onUpload: _upload,
          onBack: () => widget.onClose(false),
        );
      case _Stage.uploading:
        return const Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            CircularProgressIndicator(color: MelonTheme.accentTeal),
            SizedBox(height: 20),
            Text('Uploading to Google Drive…', style: TextStyle(fontSize: 17)),
          ]),
        );
      case _Stage.success:
        return Column(children: [
          const Spacer(),
          const Icon(Icons.check_circle, size: 72, color: MelonTheme.meadowGreen),
          const SizedBox(height: 16),
          const Text('Upload successful! 🎉', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(
            'The original photo, segmentation result, GNG visualization, and density data have been saved to the '
            '"Melon Segmenter" folder, including a new row in density_log.csv.',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withValues(alpha: 0.65)),
          ),
          const Spacer(),
          PrimaryButton(label: widget.doneTitle, icon: Icons.check, onPressed: () => widget.onClose(true)),
          const SizedBox(height: 16),
        ]);
      case _Stage.failure:
        return Column(children: [
          const Spacer(),
          const Icon(Icons.warning_amber_rounded, size: 64, color: Colors.orange),
          const SizedBox(height: 16),
          const Text('Oops, something went wrong', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Text(_error, textAlign: TextAlign.center, style: TextStyle(color: Colors.white.withValues(alpha: 0.65))),
          const Spacer(),
          PrimaryButton(label: 'Back', icon: Icons.chevron_left, onPressed: () => widget.onClose(false)),
          const SizedBox(height: 16),
        ]);
    }
  }
}

/// RGBA buffer -> ui.Image.
Future<ui.Image> rgbaToImage(Uint8List rgba, int width, int height) {
  final c = Completer<ui.Image>();
  ui.decodeImageFromPixels(rgba, width, height, ui.PixelFormat.rgba8888, c.complete);
  return c.future;
}

Future<Uint8List> imageToPng(ui.Image image) async =>
    (await image.toByteData(format: ui.ImageByteFormat.png))!.buffer.asUint8List();
