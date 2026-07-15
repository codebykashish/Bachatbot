import 'package:flutter/foundation.dart';

enum FinancialStatus { safe, high, overspent }

/// Global, app-wide spending-health signal. Updated whenever the home
/// screen's report refreshes (insights.overallStatus from /monthly-report).
/// Drives the ambient smoky background wash — see AmbientStatusOverlay.
class FinancialStatusService {
  static final FinancialStatusService _instance = FinancialStatusService._internal();

  factory FinancialStatusService() => _instance;

  FinancialStatusService._internal();

  final ValueNotifier<FinancialStatus> status = ValueNotifier(FinancialStatus.safe);

  void updateFromOverallStatus(String? overallStatus) {
    switch (overallStatus) {
      case 'overspent':
        status.value = FinancialStatus.overspent;
        break;
      case 'high':
        status.value = FinancialStatus.high;
        break;
      default:
        status.value = FinancialStatus.safe;
    }
  }
}
