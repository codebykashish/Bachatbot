import 'package:flutter/material.dart';

/// The Reports screen's Month view navigator -- one pill per calendar
/// month (Jan-Dec of the given year), each showing that month's total
/// inline. Tapping a month switches the whole screen to it, replacing
/// the old chevron prev/next + separate day-by-day bar chart. Months
/// with no spending render as an empty dot (nothing to show, not a
/// zero-value bar); months after the current one are disabled -- there's
/// no "future" report to view yet.
class MonthStrip extends StatelessWidget {
  static const Color _primary = Color(0xFF2DBE7F);
  static const List<String> _labels = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  final int year;
  final int selectedMonth; // 1-12
  final Map<String, double> monthTotals; // "YYYY-MM" -> total
  final void Function(int month) onSelect;

  const MonthStrip({
    super.key,
    required this.year,
    required this.selectedMonth,
    required this.monthTotals,
    required this.onSelect,
  });

  String _formatValue(double v) {
    if (v <= 0) return '';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(v >= 10000 ? 0 : 2)}K';
    return v.toInt().toString();
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isCurrentYear = year == now.year;
    final maxVal = monthTotals.values.fold<double>(0, (a, b) => a > b ? a : b);

    return SizedBox(
      height: 128,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: 12,
        itemBuilder: (context, i) {
          final month = i + 1;
          final monthKey = '$year-${month.toString().padLeft(2, '0')}';
          final value = monthTotals[monthKey] ?? 0.0;
          final isSelected = month == selectedMonth;
          final isFuture = isCurrentYear && month > now.month;
          final barHeight = maxVal > 0 ? (value / maxVal).clamp(0.0, 1.0) * 56 : 0.0;

          return GestureDetector(
            onTap: isFuture ? null : () => onSelect(month),
            child: Container(
              width: 56,
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    height: 18,
                    child: value > 0
                        ? Text(
                            _formatValue(value),
                            style: TextStyle(
                              fontSize: isSelected ? 12.5 : 10.5,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.w600,
                              color: isSelected ? _primary : Colors.grey.shade500,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 4),
                  Container(
                    width: isSelected ? 22 : 14,
                    height: value > 0 ? (barHeight < 14 ? 14 : barHeight) : 0,
                    decoration: BoxDecoration(
                      color: isFuture
                          ? Colors.grey.shade200
                          : isSelected
                              ? _primary
                              : _primary.withValues(alpha: 0.25),
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isSelected ? _primary : Colors.transparent,
                      border: Border.all(
                        color: isFuture ? Colors.grey.shade300 : (isSelected ? _primary : Colors.grey.shade400),
                        width: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _labels[i],
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isFuture ? Colors.grey.shade400 : (isSelected ? Colors.black87 : Colors.grey.shade600),
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
