import 'package:flutter/material.dart';

/// Phase 13.5 — the frozen 3-row lookup this whole feature hangs off:
/// one real backend signal (Health Engine's overallHealth.status,
/// green/amber/red — never a client-side budget-percentage guess)
/// mapped to a consistent visual language, reused everywhere rather
/// than each screen inventing its own status colors.
///
/// Reuses the exact brand colors already used elsewhere in the app
/// (Streak's flame, Notification priority colors, the Health badge) —
/// this is a lookup, not a new palette.
///
/// [iconStyle]/[animationStyle] from the original design (a
/// celebratory vs. neutral vs. focused visual/motion language per
/// status) are deliberately NOT part of this class yet — named here so
/// they aren't forgotten, but left unbuilt rather than faked with a
/// placeholder value. A later phase, not this one.
class HealthTheme {
  final Color accent;
  final Color statusColor;
  final Color progressColor;
  final Color cardTint;
  // null = no ambient wash at all — "calm" reads better as the absence
  // of a mood layer than as a green one (spec's own caution against
  // overdoing it).
  final Color? backgroundTintTop;
  final Color? backgroundTintBottom;

  const HealthTheme({
    required this.accent,
    required this.statusColor,
    required this.progressColor,
    required this.cardTint,
    this.backgroundTintTop,
    this.backgroundTintBottom,
  });

  static const HealthTheme _green = HealthTheme(
    accent: Color(0xFF2DBE7F),
    statusColor: Color(0xFF2DBE7F),
    progressColor: Color(0xFF2DBE7F),
    cardTint: Color(0xFFF6F7F9),
  );

  static const HealthTheme _amber = HealthTheme(
    accent: Color(0xFFE67E22),
    statusColor: Color(0xFFE67E22),
    progressColor: Color(0xFFE67E22),
    cardTint: Color(0xFFFFF3E8),
    backgroundTintTop: Color(0xFF7A6438),
    backgroundTintBottom: Color(0xFF2A2318),
  );

  static const HealthTheme _red = HealthTheme(
    accent: Color(0xFFE0223B),
    statusColor: Color(0xFFE0223B),
    progressColor: Color(0xFFE0223B),
    cardTint: Color(0xFFFCEBEC),
    backgroundTintTop: Color(0xFF6B3A3A),
    backgroundTintBottom: Color(0xFF2A1D1E),
  );

  static HealthTheme forStatus(String? status) {
    switch (status) {
      case 'amber':
        return _amber;
      case 'red':
        return _red;
      default:
        return _green;
    }
  }
}
