import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../store/melon_store.dart';
import '../theme.dart';
import 'processing_flow.dart';

class MelonDetailScreen extends StatelessWidget {
  final String melonId;
  const MelonDetailScreen({super.key, required this.melonId});

  Future<void> _pick(BuildContext context, ImageSource source) async {
    final store = context.read<MelonStore>();
    final melon = store.melon(melonId);
    if (melon == null) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final file = await ImagePicker().pickImage(source: source, imageQuality: 95);
      if (file == null) return;
      await store.addCapture(melon, await file.readAsBytes());
      messenger.showSnackBar(const SnackBar(content: Text('Photo kept. Process it now or later.')));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text("Couldn't get the photo: $e")));
    }
  }

  Future<void> _delete(BuildContext context, Melon melon) async {
    final store = context.read<MelonStore>();
    final nav = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${melon.captureIndex}?'),
        content: const Text('The melon and its kept photos will be removed from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok == true) {
      store.deleteMelon(melon);
      nav.pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MelonStore>();
    final melon = store.melon(melonId);
    if (melon == null) return const Scaffold(body: SizedBox.shrink());
    final captures = store.capturesFor(melonId);
    final fmt = DateFormat('MMM d, y');
    final fmtTime = DateFormat("MMM d, y 'at' HH:mm");

    return Scaffold(
      appBar: AppBar(
        actions: [IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => _delete(context, melon))],
      ),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(20), children: [
          Text(melon.captureIndex, style: const TextStyle(fontSize: 34, fontWeight: FontWeight.bold)),
          Text('HST ${melon.hst()}', style: const TextStyle(fontSize: 20, color: MelonTheme.accentTeal, fontWeight: FontWeight.w600)),
          Text('Planted ${fmt.format(melon.plantingDate)}', style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
          const Divider(height: 32),
          PrimaryButton(label: 'Take Photo', icon: Icons.photo_camera, onPressed: () => _pick(context, ImageSource.camera)),
          const SizedBox(height: 12),
          SecondaryButton(label: 'Choose from Library', icon: Icons.photo_library_outlined, onPressed: () => _pick(context, ImageSource.gallery)),
          const SizedBox(height: 28),
          Text('Kept photos', style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 16, fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          if (captures.isEmpty)
            Text('No photos yet.', style: TextStyle(color: Colors.white.withValues(alpha: 0.45))),
          for (final c in captures)
            Dismissible(
              key: ValueKey(c.id),
              direction: DismissDirection.endToStart,
              background: Container(
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 20),
                color: Colors.redAccent,
                child: const Icon(Icons.delete),
              ),
              onDismissed: (_) => store.deleteCapture(c),
              child: Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: MelonTheme.cardBackground, borderRadius: BorderRadius.circular(20)),
                child: Row(children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: c.status == CaptureStatus.pending
                        ? Image.file(store.fileOf(c), width: 56, height: 56, fit: BoxFit.cover, cacheWidth: 160, errorBuilder: (_, _, _) => _placeholder())
                        : _placeholder(),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text('HST ${c.hstAtCapture}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16)),
                      Text(fmtTime.format(c.takenAt), style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6))),
                    ]),
                  ),
                  if (c.status == CaptureStatus.pending)
                    FilledButton(
                      style: FilledButton.styleFrom(backgroundColor: MelonTheme.accentTeal, foregroundColor: MelonTheme.navyDeep),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute<void>(builder: (_) => ProcessingQueueScreen(captureIds: [c.id])),
                      ),
                      child: const Text('Process'),
                    )
                  else
                    const Row(children: [
                      Icon(Icons.cloud_done, size: 18, color: MelonTheme.meadowGreen),
                      SizedBox(width: 4),
                      Text('Uploaded', style: TextStyle(color: MelonTheme.meadowGreen)),
                    ]),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _placeholder() => Container(width: 56, height: 56, color: Colors.white12, child: const Icon(Icons.image_outlined));
}
