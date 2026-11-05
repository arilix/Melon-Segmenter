import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models.dart';
import '../store/auth_manager.dart';
import '../store/melon_store.dart';
import '../store/schedule_store.dart';
import '../theme.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  String _fmtMinute(int m) => '${(m ~/ 60).toString().padLeft(2, '0')}:${(m % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final auth = context.watch<AuthManager>();
    final sched = context.watch<ScheduleStore>();
    final s = sched.schedule;
    final next = s.upcomingReminders(count: 1);
    const days = ['M', 'T', 'W', 'T', 'F', 'S', 'S'];

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: SafeArea(
        child: ListView(padding: const EdgeInsets.all(16), children: [
          _section('Google account'),
          MelonCard(
            child: auth.user == null
                ? Column(children: [
                    if (auth.errorMessage != null)
                      Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(auth.errorMessage!, style: const TextStyle(color: Colors.orangeAccent))),
                    PrimaryButton(label: 'Sign in with Google', icon: Icons.login, onPressed: auth.isSigningIn ? null : auth.signIn),
                  ])
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(auth.email ?? '', style: const TextStyle(fontSize: 16)),
                    const SizedBox(height: 8),
                    TextButton(
                      onPressed: auth.signOut,
                      style: TextButton.styleFrom(padding: EdgeInsets.zero, foregroundColor: Colors.redAccent),
                      child: const Text('Sign out'),
                    ),
                  ]),
          ),
          const SizedBox(height: 20),
          _section('Capture schedule'),
          MelonCard(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Remind me to collect data'),
                value: s.isEnabled,
                activeThumbColor: MelonTheme.accentTeal,
                onChanged: (v) => sched.update(s.copy()..isEnabled = v),
              ),
              if (s.isEnabled) ...[
                SegmentedButton<ScheduleMode>(
                  segments: const [
                    ButtonSegment(value: ScheduleMode.weekdays, label: Text('Days of the week')),
                    ButtonSegment(value: ScheduleMode.everyNDays, label: Text('Every N days')),
                  ],
                  selected: {s.mode},
                  onSelectionChanged: (v) => sched.update(s.copy()..mode = v.first),
                ),
                const SizedBox(height: 12),
                if (s.mode == ScheduleMode.weekdays)
                  Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                    for (var i = 0; i < 7; i++)
                      GestureDetector(
                        onTap: () {
                          final next = s.copy();
                          final wd = i + 1;
                          next.weekdays.contains(wd) ? next.weekdays.remove(wd) : next.weekdays.add(wd);
                          sched.update(next);
                        },
                        child: CircleAvatar(
                          radius: 18,
                          backgroundColor: s.weekdays.contains(i + 1) ? MelonTheme.accentTeal : Colors.white12,
                          child: Text(days[i], style: TextStyle(color: s.weekdays.contains(i + 1) ? MelonTheme.navyDeep : Colors.white, fontWeight: FontWeight.w600)),
                        ),
                      ),
                  ])
                else ...[
                  Row(children: [
                    const Text('Every'),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline),
                      onPressed: s.intervalDays > 1 ? () => sched.update(s.copy()..intervalDays = s.intervalDays - 1) : null,
                    ),
                    Text('${s.intervalDays}', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline),
                      onPressed: s.intervalDays < 60 ? () => sched.update(s.copy()..intervalDays = s.intervalDays + 1) : null,
                    ),
                    const Text('days'),
                  ]),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('First capture day'),
                    trailing: Text('${s.intervalStart.day}/${s.intervalStart.month}/${s.intervalStart.year}'),
                    onTap: () async {
                      final d = await showDatePicker(
                        context: context,
                        initialDate: s.intervalStart,
                        firstDate: DateTime.now().subtract(const Duration(days: 365)),
                        lastDate: DateTime.now().add(const Duration(days: 365)),
                      );
                      if (d != null) sched.update(s.copy()..intervalStart = startOfDay(d));
                    },
                  ),
                ],
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Reminder time'),
                  trailing: Chip(label: Text(_fmtMinute(CaptureSchedule.clamp(s.reminderMinuteOfDay)))),
                  onTap: () async {
                    final m = CaptureSchedule.clamp(s.reminderMinuteOfDay);
                    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: m ~/ 60, minute: m % 60));
                    if (t != null) sched.update(s.copy()..reminderMinuteOfDay = CaptureSchedule.clamp(t.hour * 60 + t.minute));
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Next reminder'),
                  trailing: Text(next.isEmpty ? '—' : '${next.first.day}/${next.first.month}/${next.first.year} ${_fmtMinute(next.first.hour * 60 + next.first.minute)}',
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
                ),
              ],
              if (sched.notificationsBlocked)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text('Notifications are blocked for this app. Allow them in Android settings to get reminders.',
                      style: TextStyle(color: Colors.orangeAccent, fontSize: 12)),
                ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
            child: Text('One schedule for all melons. Reminders can be set between 06:00 and 17:30.',
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.55))),
          ),
          const SizedBox(height: 20),
          _section('Photo storage'),
          MelonCard(
            child: FutureBuilder<int>(
              future: context.read<MelonStore>().usedBytes(),
              builder: (ctx, snap) {
                final mb = ((snap.data ?? 0) / (1024 * 1024)).toStringAsFixed(1);
                return Column(children: [
                  _row('Location', 'Inside the app (private)'),
                  const Divider(),
                  _row('Used', '$mb MB'),
                ]);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
            child: Text('Photos are kept until they are uploaded, then deleted from the device.',
                style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.55))),
          ),
        ]),
      ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Text(t, style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontWeight: FontWeight.w600)),
      );

  Widget _row(String a, String b) => Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
        Text(a),
        Text(b, style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
      ]);
}
