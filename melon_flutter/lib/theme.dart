import 'package:flutter/material.dart';

class MelonTheme {
  static const navy = Color.fromRGBO(15, 36, 54, 1);
  static const navyDeep = Color.fromRGBO(8, 20, 33, 1);
  static const leafGreen = Color.fromRGBO(74, 153, 84, 1);
  static const meadowGreen = Color.fromRGBO(125, 189, 115, 1);
  static const limeGreen = Color.fromRGBO(194, 212, 120, 1);
  static const accentTeal = Color.fromRGBO(41, 204, 219, 1);
  static final cardBackground = Colors.white.withValues(alpha: 0.06);

  static ThemeData get data => ThemeData(
        brightness: Brightness.dark,
        useMaterial3: true,
        scaffoldBackgroundColor: Colors.transparent,
        colorScheme: ColorScheme.fromSeed(seedColor: accentTeal, brightness: Brightness.dark, primary: accentTeal),
        appBarTheme: const AppBarTheme(backgroundColor: Colors.transparent, elevation: 0),
        dialogTheme: DialogThemeData(backgroundColor: navy, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24))),
      );
}

/// Navy gradient background used behind every screen.
class MelonBackground extends StatelessWidget {
  final Widget child;
  const MelonBackground({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [MelonTheme.navy, MelonTheme.navyDeep]),
        ),
        child: child,
      );
}

class MelonCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets padding;
  const MelonCard({super.key, required this.child, this.padding = const EdgeInsets.all(16)});
  @override
  Widget build(BuildContext context) => Container(
        padding: padding,
        decoration: BoxDecoration(
          color: MelonTheme.cardBackground,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: child,
      );
}

class PrimaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData? icon;
  final String label;
  const PrimaryButton({super.key, required this.label, this.icon, this.onPressed});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: onPressed,
          icon: icon == null ? const SizedBox.shrink() : Icon(icon),
          label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          style: FilledButton.styleFrom(
            backgroundColor: MelonTheme.accentTeal,
            foregroundColor: MelonTheme.navyDeep,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: const StadiumBorder(),
          ),
        ),
      );
}

class SecondaryButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final IconData? icon;
  final String label;
  const SecondaryButton({super.key, required this.label, this.icon, this.onPressed});
  @override
  Widget build(BuildContext context) => SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: onPressed,
          icon: icon == null ? const SizedBox.shrink() : Icon(icon),
          label: Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: Colors.white.withValues(alpha: 0.08),
            side: BorderSide(color: Colors.white.withValues(alpha: 0.25)),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: const StadiumBorder(),
          ),
        ),
      );
}

class MelonHeader extends StatelessWidget {
  const MelonHeader({super.key});
  @override
  Widget build(BuildContext context) => Row(children: [
        ClipRRect(borderRadius: BorderRadius.circular(12), child: Image.asset('assets/icon.png', width: 44, height: 44)),
        const SizedBox(width: 12),
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(const TextSpan(children: [
            TextSpan(text: 'Melon', style: TextStyle(color: Colors.white)),
            TextSpan(text: ' Segmenter', style: TextStyle(color: MelonTheme.meadowGreen)),
          ]), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)),
          Text('Cut your melon with AI', style: TextStyle(fontSize: 12, color: Colors.white.withValues(alpha: 0.6))),
        ]),
      ]);
}
