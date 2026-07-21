import 'package:flutter/foundation.dart';

/// Phase 13.5 — global, app-wide Health signal. Deliberately NOT a
/// self-fetching singleton like ActivityFeedService/BehaviorPreviewService
/// — HomeScreen already calls GET /financial-health for its own badge
/// every refresh, so this just gets pushed the real result from there
/// rather than firing a second, redundant fetch of the same endpoint.
///
/// Replaces FinancialStatusService entirely — that service derived a
/// crude "spent > budget limit?" proxy client-side; this carries the
/// real, multi-factor Health Engine verdict (category pressure,
/// projected deficit, recovery state) that already exists server-side.
/// One source of truth, not two that can disagree.
class HealthThemeService {
  static final ValueNotifier<String> status = ValueNotifier('green');

  static void updateFromStatus(String? overallHealthStatus) {
    status.value = overallHealthStatus ?? 'green';
  }
}
