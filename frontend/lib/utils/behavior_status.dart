import 'package:flutter/material.dart';

/// Shared wording/color for GET /behavior's `summary.status` — extracted
/// out of BehaviorScreen so ProfileScreen's habit preview shows the exact
/// same label instead of inventing a second phrasing for the same status.
const Map<String, ({String emoji, String label, Color color})> _statusMeta = {
  'excellent': (emoji: '🌟', label: 'Excellent', color: Color(0xFF2DBE7F)),
  'good': (emoji: '🟢', label: 'Good', color: Color(0xFF2DBE7F)),
  'building': (emoji: '🟡', label: 'Building', color: Color(0xFFE67E22)),
  'needs_improvement': (emoji: '🔴', label: 'Needs Improvement', color: Color(0xFFE0223B)),
  'inactive': (emoji: '⚪', label: 'Just Getting Started', color: Color(0xFF8A8F98)),
};

({String emoji, String label, Color color}) behaviorStatusMeta(String? status) =>
    _statusMeta[status] ?? _statusMeta['inactive']!;
