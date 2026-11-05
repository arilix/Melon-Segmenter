import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../segmentation/melon_segmenter.dart';
import '../theme.dart';
import 'processing_flow.dart';

/// Shows the photo; one tap on the melon runs MobileSAM and previews the cutout.
class SegmentationView extends StatefulWidget {
  final MelonSegmenter segmenter;
  final dynamic photoFile;
  final void Function(Cutout) onConfirm;
  final VoidCallback onBack;
  const SegmentationView({
    super.key,
    required this.segmenter,
    required this.photoFile,
    required this.onConfirm,
    required this.onBack,
  });
  @override
  State<SegmentationView> createState() => _SegmentationViewState();
}

class _SegmentationViewState extends State<SegmentationView> {
  Uint8List? _bytes;
  bool _preparing = true; // decoding + encoding the photo
  bool _segmenting = false;
  String? _error;
  Offset? _tap; // fraction of the displayed image
  Cutout? _cutout;
  ImageProvider? _cutoutImage;

  @override
  void initState() {
    super.initState();
    _prepare();
  }

  Future<void> _prepare() async {
    try {
      final bytes = await (widget.photoFile as File).readAsBytes();
      if (!mounted) return;
      setState(() => _bytes = bytes);
      await widget.segmenter.setImage(bytes);
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _preparing = false);
  }

  Future<void> _onTap(Offset fraction) async {
    if (_preparing || _segmenting || _cutout != null) return;
    setState(() {
      _tap = fraction;
      _segmenting = true;
      _error = null;
    });
    try {
      final cutout = await widget.segmenter.segment(fraction.dx, fraction.dy);
      final image = await rgbaToImage(cutout.rgba, cutout.width, cutout.height);
      final png = await imageToPng(image);
      if (!mounted) return;
      setState(() {
        _cutout = cutout;
        _cutoutImage = MemoryImage(png);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    if (mounted) setState(() => _segmenting = false);
  }

  @override
  Widget build(BuildContext context) {
    final String hint;
    if (_error != null) {
      hint = _error!;
    } else if (_preparing) {
      hint = 'Preparing the photo…';
    } else if (_segmenting) {
      hint = 'Segmenting…';
    } else if (_cutout != null) {
      hint = 'Happy with the cutout?';
    } else {
      hint = 'Tap the melon in the photo to segment it';
    }

    return Column(children: [
      Expanded(
        child: MelonCard(
          padding: const EdgeInsets.all(8),
          child: Center(
            child: _cutoutImage != null
                ? Container(
                    decoration: BoxDecoration(color: Colors.black26, borderRadius: BorderRadius.circular(12)),
                    padding: const EdgeInsets.all(8),
                    child: Image(image: _cutoutImage!, fit: BoxFit.contain),
                  )
                : _bytes == null
                    ? const CircularProgressIndicator(color: MelonTheme.accentTeal)
                    : LayoutBuilder(builder: (ctx, box) {
                        return _TapImage(bytes: _bytes!, tap: _tap, busy: _preparing || _segmenting, onTap: _onTap);
                      }),
          ),
        ),
      ),
      const SizedBox(height: 10),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        if (!_cutoutShown) const Icon(Icons.touch_app, size: 16, color: Colors.white54),
        const SizedBox(width: 6),
        Flexible(
          child: Text(hint,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: _error != null ? Colors.orangeAccent : Colors.white.withValues(alpha: 0.6))),
        ),
      ]),
      const SizedBox(height: 10),
      if (_cutout != null)
        Row(children: [
          Expanded(
            child: SecondaryButton(
              label: 'Try Again',
              icon: Icons.refresh,
              onPressed: () => setState(() {
                _cutout = null;
                _cutoutImage = null;
                _tap = null;
              }),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: PrimaryButton(label: 'Analyze Net', icon: Icons.auto_awesome, onPressed: () => widget.onConfirm(_cutout!))),
        ])
      else
        SecondaryButton(label: 'Back', icon: Icons.chevron_left, onPressed: widget.onBack),
    ]);
  }

  bool get _cutoutShown => _cutout != null;
}

class _TapImage extends StatefulWidget {
  final Uint8List bytes;
  final Offset? tap;
  final bool busy;
  final void Function(Offset fraction) onTap;
  const _TapImage({required this.bytes, required this.tap, required this.busy, required this.onTap});
  @override
  State<_TapImage> createState() => _TapImageState();
}

class _TapImageState extends State<_TapImage> {
  late final Future<ui.Size> _size = _computeSize();

  Future<ui.Size> _computeSize() async {
    final codec = await ui.instantiateImageCodec(widget.bytes);
    final f = await codec.getNextFrame();
    final size = ui.Size(f.image.width.toDouble(), f.image.height.toDouble());
    f.image.dispose();
    codec.dispose();
    return size;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<ui.Size>(
      future: _size,
      builder: (ctx, snap) {
        if (!snap.hasData) return const CircularProgressIndicator(color: MelonTheme.accentTeal);
        final s = snap.data!;
        return AspectRatio(
          aspectRatio: s.width / s.height,
          child: LayoutBuilder(builder: (ctx, box) {
            final tap = widget.tap;
            return GestureDetector(
              onTapUp: (d) => widget.onTap(Offset(d.localPosition.dx / box.maxWidth, d.localPosition.dy / box.maxHeight)),
              child: Stack(fit: StackFit.expand, children: [
                Image.memory(widget.bytes, fit: BoxFit.fill, gaplessPlayback: true),
                if (tap != null)
                  Positioned(
                    left: tap.dx * box.maxWidth - 14,
                    top: tap.dy * box.maxHeight - 14,
                    child: Container(
                      width: 28,
                      height: 28,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: MelonTheme.accentTeal.withValues(alpha: 0.35),
                        border: Border.all(color: MelonTheme.accentTeal, width: 2),
                      ),
                    ),
                  ),
                if (widget.busy)
                  Container(color: Colors.black38, child: const Center(child: CircularProgressIndicator(color: MelonTheme.accentTeal))),
              ]),
            );
          }),
        );
      },
    );
  }
}
