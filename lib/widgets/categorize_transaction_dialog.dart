import 'package:flutter/material.dart';
import '../api_service.dart';
import 'rebalance_confirm_dialog.dart';

/// Shown when the user taps a "Transaction Detected" alert (from SMS or
/// notification capture) — lets them pick a category and confirm, or
/// reject it outright. Same backend contract as MockNotificationScreen's
/// inline confirm/reject flow (/confirm-transaction, /reject-transaction).
Future<void> showCategorizeTransactionDialog(
  BuildContext context, {
  required String transactionId,
  required double amount,
  required String sourceApp,
}) async {
  const primary = Color(0xFF2DBE7F);
  const categories = [
    'Food', 'Transport', 'Rent', 'Education',
    'Shopping', 'Health', 'Entertainment', 'Other',
  ];
  const categoryIcons = {
    'Food': Icons.restaurant,
    'Transport': Icons.directions_car,
    'Rent': Icons.home,
    'Education': Icons.school,
    'Shopping': Icons.shopping_bag,
    'Health': Icons.favorite,
    'Entertainment': Icons.tv,
    'Other': Icons.more_horiz,
  };

  String? selectedCategory;
  bool isSaving = false;

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(Icons.receipt_long_rounded, color: Color(0xFF2B6CB0), size: 22),
            const SizedBox(width: 8),
            const Expanded(child: Text('Transaction Detected')),
            // Postpone -- closes without confirming or discarding, so the
            // pending transaction is still there to categorize later
            // (from Activity Feed, or the usual chat yes/no flow).
            InkWell(
              onTap: isSaving ? null : () => Navigator.of(ctx).pop(),
              borderRadius: BorderRadius.circular(16),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 20, color: Colors.grey),
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Rs ${amount.toInt()} detected from $sourceApp. Which category?',
              style: const TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 14),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: categories.map((cat) {
                final isSelected = selectedCategory == cat;
                return GestureDetector(
                  onTap: () => setState(() => selectedCategory = cat),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    decoration: BoxDecoration(
                      color: isSelected ? primary : const Color(0xFFF6F7F9),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: isSelected ? primary : Colors.grey.shade300),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(categoryIcons[cat], size: 14, color: isSelected ? Colors.white : Colors.black54),
                        const SizedBox(width: 5),
                        Text(
                          cat,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                            color: isSelected ? Colors.white : Colors.black87,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: isSaving
                ? null
                : () async {
                    final confirmed = await showDialog<bool>(
                      context: ctx,
                      builder: (confirmCtx) => AlertDialog(
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                        title: const Text('Discard this transaction?'),
                        content: const Text("This can't be undone."),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.of(confirmCtx).pop(false),
                            child: const Text('Cancel'),
                          ),
                          TextButton(
                            onPressed: () => Navigator.of(confirmCtx).pop(true),
                            style: TextButton.styleFrom(foregroundColor: Colors.red),
                            child: const Text('Discard'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed != true) return;

                    setState(() => isSaving = true);
                    try {
                      await ApiService.post('/reject-transaction/$transactionId', {});
                    } catch (_) {}
                    if (ctx.mounted) Navigator.of(ctx).pop();
                  },
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Discard'),
          ),
          ElevatedButton(
            onPressed: (isSaving || selectedCategory == null)
                ? null
                : () async {
                    setState(() => isSaving = true);
                    try {
                      final res = await ApiService.post(
                        '/confirm-transaction/$transactionId',
                        {'category': selectedCategory},
                      );
                      final pendingRebalance =
                          res['data']?['budgetUpdate']?['pendingRebalance'];
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      if (pendingRebalance != null && context.mounted) {
                        await showRebalanceConfirmDialog(
                          context,
                          Map<String, dynamic>.from(pendingRebalance),
                        );
                      }
                    } catch (e) {
                      if (ctx.mounted) Navigator.of(ctx).pop();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(content: Text('Could not confirm: $e'), backgroundColor: Colors.red),
                        );
                      }
                    }
                  },
            style: ElevatedButton.styleFrom(backgroundColor: primary, foregroundColor: Colors.white),
            child: isSaving
                ? const SizedBox(
                    width: 16, height: 16,
                    child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                  )
                : const Text('Confirm'),
          ),
        ],
      ),
    ),
  );
}
