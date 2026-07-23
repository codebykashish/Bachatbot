import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

// ── Category icon ─────────────────────────────────────────────────────────────

IconData categoryIcon(String? category) {
  switch (category?.toLowerCase()) {
    case 'food':          return Icons.restaurant_outlined;
    case 'transport':     return Icons.directions_bus_outlined;
    case 'rent':          return Icons.home_outlined;
    case 'shopping':      return Icons.shopping_bag_outlined;
    case 'health':        return Icons.local_hospital_outlined;
    case 'education':     return Icons.school_outlined;
    case 'bills':         return Icons.receipt_long_outlined;
    case 'entertainment': return Icons.movie_outlined;
    default:              return Icons.category_outlined;
  }
}

// Same palette Categories/Home already use per category (previously
// duplicated as a local `_catMeta` list in each of those screens) --
// one source of truth so a category reads as the same color everywhere,
// including the new Reports category breakdown list.
Color categoryColor(String? category) {
  switch (category?.toLowerCase()) {
    case 'food':          return const Color(0xFFFF7043);
    case 'transport':     return const Color(0xFF42A5F5);
    case 'rent':          return const Color(0xFF26A69A);
    case 'education':     return const Color(0xFF7E57C2);
    case 'shopping':      return const Color(0xFFAB47BC);
    case 'health':        return const Color(0xFFEF5350);
    case 'bills':         return const Color(0xFFFFA726);
    case 'entertainment': return const Color(0xFF8D6E63);
    default:              return const Color(0xFFFFCA28);
  }
}

// ── Alert time formatting ─────────────────────────────────────────────────────

String formatAlertTime(String? isoString) {
  if (isoString == null || isoString.isEmpty) return '';
  final dt = DateTime.tryParse(isoString)?.toLocal();
  if (dt == null) return '';
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final yesterday = today.subtract(const Duration(days: 1));
  final dtDay = DateTime(dt.year, dt.month, dt.day);
  final timeStr = DateFormat('h:mm a').format(dt);
  if (dtDay == today) return 'Today, $timeStr';
  if (dtDay == yesterday) return 'Yesterday, $timeStr';
  if (today.difference(dtDay).inDays < 7) {
    return '${DateFormat('EEE').format(dt)}, $timeStr';
  }
  return '${DateFormat('MMM d').format(dt)}, $timeStr';
}

// ── Budget status helpers ─────────────────────────────────────────────────────

Color progressColor(String status) {
  switch (status.toLowerCase()) {
    case 'low':       return Colors.blue.shade400;
    case 'warning':   return Colors.amber.shade600;
    case 'high':
    case 'danger':
    case 'overspent': return Colors.red.shade500;
    default:          return Colors.green;
  }
}

Widget statusBadge(String status) {
  final Color bg;
  final Color fg;
  final String label;
  switch (status.toLowerCase()) {
    case 'low':
      bg = Colors.blue.shade50; fg = Colors.blue.shade700; label = 'LOW';
      break;
    case 'warning':
      bg = Colors.amber.shade50; fg = Colors.amber.shade800; label = 'WARNING';
      break;
    case 'high':
    case 'danger':
    case 'overspent':
      bg = Colors.red.shade50; fg = Colors.red.shade700; label = 'HIGH';
      break;
    case 'ok':
    case 'exact':
      bg = Colors.green.shade50; fg = Colors.green.shade700; label = 'OK';
      break;
    default:
      bg = Colors.grey.shade100; fg = Colors.grey.shade600;
      label = status.toUpperCase();
  }
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        color: fg,
        letterSpacing: 0.5,
      ),
    ),
  );
}

// ── Choice chip (filter row) ──────────────────────────────────────────────────

Widget buildChoiceChip({
  required String label,
  required bool selected,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: selected ? Colors.green.shade50 : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: selected ? Colors.green : Colors.grey.shade300,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: selected ? Colors.green : Colors.grey,
          fontWeight: selected ? FontWeight.bold : FontWeight.normal,
        ),
      ),
    ),
  );
}

// ── AlertCard ─────────────────────────────────────────────────────────────────
// Notification-screen card. Income unread = green bg; expense = white bg.
// Pass onUndo to show a compact undo button.

class AlertCard extends StatelessWidget {
  final Map<String, dynamic> alert;
  final VoidCallback? onTap;
  final VoidCallback? onUndo;

  const AlertCard({super.key, required this.alert, this.onTap, this.onUndo});

  @override
  Widget build(BuildContext context) {
    final isRead = alert['isRead'] == true;
    final rawType = (alert['type'] as String?)?.toLowerCase() ?? 'expense';
    final category = (alert['category'] as String?) ?? 'Other';
    final amount = (alert['amount'] as num?)?.toDouble() ?? 0;
    final note = (alert['message'] as String?) ?? (alert['note'] as String?) ?? '';
    final createdAt = ((alert['createdAt'] ?? alert['date']) as Object?)?.toString();

    final isBudget = rawType.contains('budget');
    final isIncome = rawType == 'income';
    final isUndoConfirm = rawType == 'undo_confirm';

    // ── Urgent alert detection: a budget threshold crossed (severity
    // medium/high) or a budget transfer/rebalance. These get a distinct
    // red/orange treatment so they read as an "alert", not a routine entry.
    final severity = (alert['severity'] as String?) ?? 'low';
    final isRebalance = rawType == 'budget_rebalanced';
    final isThresholdAlert = rawType == 'expense' && (severity == 'medium' || severity == 'high');
    final isPendingTx = rawType == 'pending_transaction';
    final isUrgentAlert = isRebalance || isThresholdAlert || isPendingTx;
    final Color urgentColor = isPendingTx
        ? const Color(0xFF2B6CB0)
        : (isRebalance ? const Color(0xFFE67E22) : const Color(0xFFE0223B));
    final String urgentBadgeText = isPendingTx ? 'NEW' : 'ALERT';

    // ── Title
    final String title;
    if (isUndoConfirm) {
      title = 'Undo Successful';
    } else if (isPendingTx) {
      title = 'Transaction Detected';
    } else if (isRebalance) {
      title = 'Budget Adjusted';
    } else if (isThresholdAlert) {
      title = 'Budget Alert';
    } else if (isBudget) {
      title = 'Budget Update';
    } else if (isIncome) {
      title = 'Income';
    } else {
      title = category;
    }

    // ── Circle icon
    final Widget circleIcon;
    if (isUndoConfirm) {
      circleIcon = CircleAvatar(
        backgroundColor: Colors.orange.shade50,
        child: Icon(Icons.undo_rounded, color: Colors.orange.shade700, size: 20),
      );
    } else if (isUrgentAlert) {
      circleIcon = CircleAvatar(
        backgroundColor: urgentColor.withValues(alpha: 0.12),
        child: Icon(
          isPendingTx
              ? Icons.receipt_long_rounded
              : (isRebalance ? Icons.swap_horiz_rounded : Icons.warning_amber_rounded),
          color: urgentColor,
          size: 20,
        ),
      );
    } else if (isBudget) {
      circleIcon = CircleAvatar(
        backgroundColor: Colors.blue.shade50,
        child: const Icon(Icons.account_balance_wallet_outlined,
            color: Colors.blue, size: 20),
      );
    } else if (isIncome) {
      circleIcon = CircleAvatar(
        backgroundColor: Colors.green.shade50,
        child: const Icon(Icons.arrow_downward_rounded,
            color: Colors.green, size: 20),
      );
    } else {
      circleIcon = CircleAvatar(
        backgroundColor: Colors.red.shade50,
        child: Icon(categoryIcon(category), color: Colors.red.shade400, size: 20),
      );
    }

    // ── Amount
    final String amountStr;
    final Color amountColor;
    if (amount == 0) {
      amountStr = ''; amountColor = Colors.grey;
    } else if (isPendingTx) {
      // Not yet categorized — type (income/expense) isn't settled, so no
      // +/- sign is shown until the user confirms.
      amountStr = 'Rs ${amount.toInt()}'; amountColor = urgentColor;
    } else if (isIncome) {
      amountStr = '+Rs ${amount.toInt()}'; amountColor = Colors.green.shade700;
    } else if (isBudget) {
      amountStr = 'Rs ${amount.toInt()}'; amountColor = Colors.blue;
    } else {
      amountStr = '-Rs ${amount.toInt()}'; amountColor = Colors.red.shade600;
    }

    // Budget rebalanced messages are longer — give them 3 lines
    final int msgMaxLines = rawType == 'budget_rebalanced' ? 3 : 2;

    // Unread → subtle green highlight (like Facebook unread); read → white.
    // Urgent alerts keep a tinted background + colored left border even
    // after being read, so they never blend in with routine notifications.
    final bool showGreenBg = !isRead && !isUrgentAlert;

    final card = Stack(
      children: [
        Container(
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
          decoration: BoxDecoration(
            color: isUrgentAlert
                ? urgentColor.withValues(alpha: 0.06)
                : (showGreenBg ? Colors.green.shade50 : Colors.white),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isUrgentAlert
                  ? urgentColor.withValues(alpha: 0.35)
                  : (showGreenBg ? Colors.green.shade200 : Colors.grey.shade200),
            ),
            boxShadow: isUrgentAlert
                ? [BoxShadow(color: urgentColor.withValues(alpha: 0.12), blurRadius: 8, offset: const Offset(0, 2))]
                : null,
          ),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 40, height: 40, child: circleIcon),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: isUrgentAlert ? urgentColor : Colors.grey.shade800,
                            ),
                          ),
                          if (isUrgentAlert) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: urgentColor,
                                borderRadius: BorderRadius.circular(5),
                              ),
                              child: Text(
                                urgentBadgeText,
                                style: const TextStyle(
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  color: Colors.white,
                                  letterSpacing: 0.4,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (note.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          note,
                          style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                          maxLines: msgMaxLines,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                      const SizedBox(height: 4),
                      Text(
                        formatAlertTime(createdAt),
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    if (amountStr.isNotEmpty)
                      Text(
                        amountStr,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: amountColor,
                        ),
                      ),
                    if (onUndo != null) ...[
                      const SizedBox(height: 6),
                      GestureDetector(
                        onTap: onUndo,
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: Colors.orange.shade50,
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: Colors.orange.shade200),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.undo_rounded, size: 11, color: Colors.orange.shade700),
                              const SizedBox(width: 3),
                              Text(
                                'Undo',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: Colors.orange.shade700,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
        if (!isRead)
          Positioned(
            top: 8,
            right: 20,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.green,
                shape: BoxShape.circle,
              ),
            ),
          ),
      ],
    );

    if (onTap == null) return card;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: card,
    );
  }
}

// ── TransactionCard ───────────────────────────────────────────────────────────
// Professional record-style card for category detail and income pages.
// Distinct from AlertCard: no notification dot, cleaner layout, undo button.

class TransactionCard extends StatelessWidget {
  final Map<String, dynamic> item;
  final bool isIncome;
  final VoidCallback? onUndo;

  const TransactionCard({
    super.key,
    required this.item,
    this.isIncome = false,
    this.onUndo,
  });

  @override
  Widget build(BuildContext context) {
    final amount = (item['amount'] as num?)?.toDouble() ?? 0;
    final note = (item['note'] as String?)?.trim().isNotEmpty == true
        ? (item['note'] as String)
        : ((item['message'] as String?) ?? (item['description'] as String?) ?? '');
    final createdAt = ((item['createdAt'] ?? item['date']) as Object?)?.toString();
    final category = (item['category'] as String?) ?? '';

    final String title = isIncome ? 'Income' : (category.isNotEmpty ? category : 'Expense');
    final String amountStr = isIncome ? '+Rs ${amount.toInt()}' : '-Rs ${amount.toInt()}';
    final Color amountColor = isIncome ? Colors.green.shade700 : Colors.red.shade600;
    final IconData icon = isIncome ? Icons.arrow_downward_rounded : categoryIcon(category);
    final Color iconBg = isIncome ? Colors.green.shade50 : Colors.red.shade50;
    final Color iconColor = isIncome ? Colors.green.shade600 : Colors.red.shade400;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.03),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 20,
            backgroundColor: iconBg,
            child: Icon(icon, color: iconColor, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    note,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 3),
                Text(
                  formatAlertTime(createdAt),
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
                ),
              ],
            ),
          ),
          if (amount > 0 || onUndo != null) ...[
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (amount > 0)
                Text(
                  amountStr,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: amountColor,
                  ),
                ),
              if (onUndo != null) ...[
                const SizedBox(height: 4),
                GestureDetector(
                  onTap: onUndo,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: Colors.orange.shade50,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.orange.shade200),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.undo_rounded, size: 11, color: Colors.orange.shade700),
                        const SizedBox(width: 3),
                        Text(
                          'Undo',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.w600,
                            color: Colors.orange.shade700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
          ],            // closes outer ...[
        ],              // closes Row children
      ),
    );
  }
}
