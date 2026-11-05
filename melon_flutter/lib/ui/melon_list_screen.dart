import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../store/melon_store.dart';
import '../store/schedule_store.dart';
import '../theme.dart';
import 'melon_detail_screen.dart';
import 'processing_flow.dart';
import 'settings_screen.dart';

class MelonListScreen extends StatefulWidget {
  const MelonListScreen({super.key});
  @override
  State<MelonListScreen> createState() => _MelonListScreenState();
}

class _MelonListScreenState extends State<MelonListScreen> {
  bool _editing = false;

  Future<void> _add() async {
    final store = context.read<MelonStore>();
    final idCtl = TextEditingController(), hstCtl = TextEditingController();
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Add Melon'),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            TextField(controller: idCtl, decoration: const InputDecoration(hintText: 'Melon ID, e.g. 001')),
            const SizedBox(height: 8),
            TextField(
              controller: hstCtl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(hintText: 'HST today (days after planting)'),
            ),
            const SizedBox(height: 8),
            Text('HST is entered only once. The app counts it up by itself from the day you add the melon.',
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6))),
            if (error != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(error!, style: const TextStyle(color: Colors.orangeAccent))),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
            TextButton(
              onPressed: () {
                final hst = int.tryParse(hstCtl.text.trim());
                if (hst == null || hst < 0) {
                  setLocal(() => error = 'Enter HST as a whole number.');
                  return;
                }
                try {
                  store.addMelon(idCtl.text, hst);
                  Navigator.pop(ctx);
                } on MelonStoreException catch (e) {
                  setLocal(() => error = e.message);
                }
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(Melon m) async {
    final store = context.read<MelonStore>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${m.captureIndex}?'),
        content: const Text('The melon and its kept photos will be removed from this device.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete', style: TextStyle(color: Colors.redAccent))),
        ],
      ),
    );
    if (ok == true) store.deleteMelon(m);
  }

  void _processAll() {
    final store = context.read<MelonStore>();
    final ids = [for (final c in store.pendingCaptures) c.id];
    if (ids.isEmpty) return;
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ProcessingQueueScreen(captureIds: ids)));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<MelonStore>();
    final schedule = context.watch<ScheduleStore>().schedule;
    final pending = store.pendingCaptures.length;
    final today = schedule.isEnabled && schedule.isCaptureDay(DateTime.now());
    final minute = CaptureSchedule.clamp(schedule.reminderMinuteOfDay);
    final time = '${(minute ~/ 60).toString().padLeft(2, '0')}:${(minute % 60).toString().padLeft(2, '0')}';

    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
            child: Row(children: [
              IconButton(
                icon: const Icon(Icons.settings_outlined),
                onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => const SettingsScreen())),
              ),
              TextButton(onPressed: () => setState(() => _editing = !_editing), child: Text(_editing ? 'Done' : 'Edit')),
              const Spacer(),
              PopupMenuButton<MelonSort>(
                icon: const Icon(Icons.swap_vert),
                tooltip: 'Sort',
                onSelected: store.sortMelons,
                itemBuilder: (_) => const [
                  PopupMenuItem(value: MelonSort.idAscending, child: Text('ID (A–Z)')),
                  PopupMenuItem(value: MelonSort.hstDescending, child: Text('HST (highest first)')),
                  PopupMenuItem(value: MelonSort.newestFirst, child: Text('Newest first')),
                ],
              ),
              IconButton(icon: const Icon(Icons.add), onPressed: _add),
            ]),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: Text('Melons', style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.bold)),
            ),
          ),
          if (today)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(color: MelonTheme.limeGreen, borderRadius: BorderRadius.circular(18)),
              child: Row(children: [
                const Icon(Icons.event_available, color: MelonTheme.navyDeep),
                const SizedBox(width: 12),
                Text('Today is a capture day · reminder at $time',
                    style: const TextStyle(color: MelonTheme.navyDeep, fontWeight: FontWeight.w600)),
              ]),
            ),
          if (pending > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: PrimaryButton(label: 'Process all waiting ($pending)', icon: Icons.play_arrow, onPressed: _processAll),
            ),
          Expanded(
            child: store.melons.isEmpty
                ? Center(child: Text('No melons yet. Tap + to add one.', style: TextStyle(color: Colors.white.withValues(alpha: 0.6))))
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                    buildDefaultDragHandles: false,
                    itemCount: store.melons.length,
                    onReorder: store.moveMelon,
                    itemBuilder: (ctx, i) {
                      final m = store.melons[i];
                      final waiting = store.pendingCount(m.id);
                      return Container(
                        key: ValueKey(m.id),
                        margin: const EdgeInsets.only(bottom: 8),
                        decoration: BoxDecoration(color: MelonTheme.cardBackground, borderRadius: BorderRadius.circular(16)),
                        child: ListTile(
                          title: Text(m.captureIndex, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 17)),
                          subtitle: Text('HST ${m.hst()}', style: const TextStyle(color: MelonTheme.accentTeal)),
                          onTap: _editing
                              ? null
                              : () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MelonDetailScreen(melonId: m.id))),
                          trailing: _editing
                              ? Row(mainAxisSize: MainAxisSize.min, children: [
                                  IconButton(icon: const Icon(Icons.delete_outline, color: Colors.redAccent), onPressed: () => _confirmDelete(m)),
                                  ReorderableDragStartListener(index: i, child: const Icon(Icons.drag_handle)),
                                ])
                              : Row(mainAxisSize: MainAxisSize.min, children: [
                                  if (waiting > 0)
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                      decoration: BoxDecoration(color: MelonTheme.limeGreen, borderRadius: BorderRadius.circular(12)),
                                      child: Text('$waiting waiting',
                                          style: const TextStyle(color: MelonTheme.navyDeep, fontSize: 12, fontWeight: FontWeight.w600)),
                                    ),
                                  const Icon(Icons.chevron_right, color: Colors.white38),
                                ]),
                        ),
                      );
                    },
                  ),
          ),
        ]),
      ),
    );
  }
}
