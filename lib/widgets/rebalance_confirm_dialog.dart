import 'package:flutter/material.dart';
import '../api_service.dart';

/// Shared confirmation dialog for an overspend that requires taking budget
/// from other categories (or savings). Used from manual expense entry, chat,
/// and notification confirmation — same dialog, same backend contract
/// (/confirm-rebalance/{id}, /reject-rebalance/{id}) everywhere.
///
/// Call this whenever a transaction-creating API response contains a
/// `pendingRebalance` object inside `budgetUpdate`. Returns true if the
/// user confirmed (and the rebalance was applied), false if declined.
Future<bool> showRebalanceConfirmDialog(
  BuildContext context,
  Map<String, dynamic> pendingRebalance,
) async {
  const primary = Color(0xFF2DBE7F);

  final rebalanceId = pendingRebalance['rebalanceId'] as String?;
  final category = pendingRebalance['category'] as String? ?? 'this category';
  final overspend = ((pendingRebalance['overspend'] as num?) ?? 0).toInt();
  final transfers = pendingRebalance['transfers'] as List<dynamic>? ?? [];
  final coveredFully = pendingRebalance['coveredFully'] == true;

  if (rebalanceId == null) return false;

  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: Colors.red.shade600, size: 22),
          const SizedBox(width: 8),
          const Expanded(child: Text('Adjust other budgets?')),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$category is over budget by Rs $overspend. '
            '${coveredFully ? "To cover it" : "To cover part of it"}, unused amounts will be taken from:',
            style: const TextStyle(fontSize: 13),
          ),
          const SizedBox(height: 12),
          ...transfers.map((t) {
            final from = t['from'] as String? ?? '';
            final amount = ((t['amount'] as num?) ?? 0).toInt();
            final label = from == 'savings' ? 'Savings' : from;
            final affectsGoals = (t['affectsGoals'] as List?)?.cast<String>() ?? [];
            final isAlarming = from == 'savings' && affectsGoals.isNotEmpty;

            if (!isAlarming) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '• $label: Rs $amount',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              );
            }

            final goalsList = affectsGoals.join(', ');
            return Container(
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.warning_amber_rounded, color: Colors.red.shade700, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Rs $amount would come from your Savings — money currently counted toward: $goalsList',
                      style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.red.shade800),
                    ),
                  ),
                ],
              ),
            );
          }),
          if (!coveredFully) ...[
            const SizedBox(height: 8),
            Text(
              'Some of the overspend still won\'t be covered.',
              style: TextStyle(fontSize: 12, color: Colors.orange.shade700),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('No, leave it over budget'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          style: ElevatedButton.styleFrom(
            backgroundColor: primary,
            foregroundColor: Colors.white,
          ),
          child: const Text('Confirm'),
        ),
      ],
    ),
  );

  try {
    if (confirmed == true) {
      await ApiService.post('/confirm-rebalance/$rebalanceId', {});
      return true;
    } else {
      await ApiService.post('/reject-rebalance/$rebalanceId', {});
      return false;
    }
  } catch (_) {
    return false;
  }
}
