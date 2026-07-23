import 'package:flutter/material.dart';

class WeekBucketData {
  final String label;
  final double total;

  const WeekBucketData({required this.label, required this.total});
}

/// The Reports screen's Week view navigator -- always exactly 4 pills
/// (Week 1..Week 4 of the currently selected month), each showing that
/// week's total inline. Replaces the old rolling "last 7 days" chart --
/// a month's weeks are a more useful lens than a trailing window that
/// silently crosses month boundaries.
class WeekStrip extends StatelessWidget {
  static const Color _primary = Color(0xFF2DBE7F);

  final List<WeekBucketData> buckets; // always 4, index 0 = Week 1
  final int selectedIndex;
  final void Function(int index) onSelect;

  const WeekStrip({
    super.key,
    required this.buckets,
    required this.selectedIndex,
    required this.onSelect,
  });

  String _formatValue(double v) {
    if (v <= 0) return '';
    if (v >= 1000) return '${(v / 1000).toStringAsFixed(v >= 10000 ? 0 : 2)}K';
    return v.toInt().toString();
  }

  @override
  Widget build(BuildContext context) {
    final maxVal = buckets.fold<double>(0, (a, b) => a > b.total ? a : b.total);

    return SizedBox(
      height: 164,
      child: Row(
        children: List.generate(buckets.length, (i) {
          final bucket = buckets[i];
          final isSelected = i == selectedIndex;
          final barHeight = maxVal > 0 ? (bucket.total / maxVal).clamp(0.0, 1.0) * 92 : 0.0;

          return Expanded(
            child: GestureDetector(
              onTap: () => onSelect(i),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  SizedBox(
                    height: 18,
                    child: bucket.total > 0
                        ? Text(
                            _formatValue(bucket.total),
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
                    height: bucket.total > 0 ? (barHeight < 14 ? 14 : barHeight) : 0,
                    decoration: BoxDecoration(
                      color: isSelected ? _primary : _primary.withValues(alpha: 0.25),
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
                        color: isSelected ? _primary : Colors.grey.shade400,
                        width: 1.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    bucket.label,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                      color: isSelected ? Colors.black87 : Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }
}
