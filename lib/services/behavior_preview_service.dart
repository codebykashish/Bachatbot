import 'package:flutter/material.dart';
import '../api_service.dart';

/// A tiny, app-lifetime holder for the two numbers the top app bar's
/// streak badge needs (Phase 13.3) — just enough to render "🔥 4" without
/// every screen re-fetching GET /behavior itself. Not a full live
/// listener (behaviorState only changes once a day for most streaks
/// anyway, per its own frozen contract) — refresh() is called wherever
/// something might have changed it (app start, after logging a
/// transaction, after opening the full BehaviorScreen).
class BehaviorPreviewService {
  static final ValueNotifier<int> healthySpendingStreak = ValueNotifier(0);
  static final ValueNotifier<int> milestonesUnlocked = ValueNotifier(0);

  static Future<void> refresh() async {
    try {
      final res = await ApiService.get('/behavior');
      if (res['success'] != true) return;
      final data = res['data'] as Map<String, dynamic>?;
      final state = data?['state'] as Map<String, dynamic>?;
      final spending = state?['spending'] as Map<String, dynamic>?;
      final milestones = data?['milestones'] as List? ?? [];
      healthySpendingStreak.value = (spending?['currentHealthyStreak'] as num?)?.toInt() ?? 0;
      milestonesUnlocked.value = milestones.where((m) => m['unlocked'] == true).length;
    } catch (e) {
      debugPrint('[BehaviorPreviewService] refresh failed: $e');
    }
  }
}
