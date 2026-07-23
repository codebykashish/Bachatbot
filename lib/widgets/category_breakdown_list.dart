import 'package:flutter/material.dart';
import 'shared_widgets.dart';

/// Full per-category breakdown for the Reports screen -- colored icon,
/// amount, % of period total, and a thin progress bar -- replacing the
/// old single "you spent the most on X" line. Used under all three
/// Reports views (Today/Week/Month) so each period gets the same clear
/// answer to "where did my money go," not just Month.
class CategoryBreakdownList extends StatelessWidget {
  final Map<String, double> categoryBreakdown;

  const CategoryBreakdownList({super.key, required this.categoryBreakdown});

  @override
  Widget build(BuildContext context) {
    final entries = categoryBreakdown.entries.where((e) => e.value > 0).toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    if (entries.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.grey.shade200),
        ),
        child: Text('No spending in this period', style: TextStyle(fontSize: 13, color: Colors.grey.shade400)),
      );
    }

    final total = entries.fold<double>(0, (sum, e) => sum + e.value);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(
        children: [
          for (int i = 0; i < entries.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 52),
            _row(entries[i].key, entries[i].value, total),
          ],
        ],
      ),
    );
  }

  Widget _row(String category, double amount, double total) {
    final color = categoryColor(category);
    final pct = total > 0 ? amount / total : 0.0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(categoryIcon(category), color: color, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(category, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: Colors.black87)),
                    ),
                    Text('Rs ${amount.toInt()}', style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.bold, color: Colors.black87)),
                  ],
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: pct.clamp(0.0, 1.0),
                          minHeight: 6,
                          backgroundColor: Colors.grey.shade200,
                          color: color,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${(pct * 100).toStringAsFixed(1)}%', style: TextStyle(fontSize: 11, color: Colors.grey.shade500, fontWeight: FontWeight.w600)),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
