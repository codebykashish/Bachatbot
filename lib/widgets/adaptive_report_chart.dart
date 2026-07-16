import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

/// One chart that adapts to the Reports screen's Today/Week/Month tabs and
/// optional category filter, instead of stacking a separate chart per mode.
///
/// - Today: bars = categories (no time axis to show for a single day).
/// - Week: 7 bars, Sun-Sat. "All" shows daily totals; a selected category
///   shows just that category's daily amounts.
/// - Month: one bar per day. Axis labels are sparse (0/5/10/.../30) so a
///   ~30-bar chart doesn't look cluttered, but every day still has a bar.
class AdaptiveReportChart extends StatelessWidget {
  static const Color _primary = Color(0xFF2DBE7F);

  final String mode; // 'today' | 'week' | 'month'
  final Map<String, double> categoryBreakdown; // used when mode == 'today'
  final List<dynamic> dailyBreakdown; // used when mode == 'week' | 'month'
  final String? selectedCategory; // null = "All"

  const AdaptiveReportChart({
    super.key,
    required this.mode,
    this.categoryBreakdown = const {},
    this.dailyBreakdown = const [],
    this.selectedCategory,
  });

  @override
  Widget build(BuildContext context) {
    final entries = mode == 'today' ? _todayEntries() : _dailyEntries();

    if (entries.isEmpty || entries.every((e) => e.value == 0)) {
      return _emptyState();
    }

    final maxY = (entries.map((e) => e.value).reduce((a, b) => a > b ? a : b) * 1.25)
        .clamp(10.0, double.infinity);
    final sparseLabels = mode == 'month';

    return Container(
      height: 220,
      padding: const EdgeInsets.fromLTRB(12, 16, 16, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: BarChart(
        BarChartData(
          maxY: maxY,
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) {
                final e = entries[group.x.toInt()];
                return BarTooltipItem(
                  '${e.label}\nRs ${e.value.toInt()}',
                  const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                );
              },
            ),
          ),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 34,
                getTitlesWidget: (v, _) => Text(
                  v.toInt().toString(),
                  style: TextStyle(fontSize: 9, color: Colors.grey.shade400),
                ),
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 24,
                getTitlesWidget: (v, _) {
                  final i = v.toInt();
                  if (i < 0 || i >= entries.length) return const SizedBox.shrink();
                  final e = entries[i];
                  if (sparseLabels && !e.isSparseLabel) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      e.label,
                      style: TextStyle(fontSize: 9, color: Colors.grey.shade500),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  );
                },
              ),
            ),
          ),
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: maxY / 4,
            getDrawingHorizontalLine: (_) => FlLine(color: Colors.grey.shade100, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          barGroups: List.generate(entries.length, (i) {
            return BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: entries[i].value,
                  color: entries[i].isToday ? _primary : _primary.withValues(alpha: 0.55),
                  width: mode == 'month' ? 6 : 18,
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
                ),
              ],
            );
          }),
        ),
      ),
    );
  }

  List<_ChartEntry> _todayEntries() {
    // A category filter on Today narrows to just that one bar, rather
    // than leaving all categories showing while the chip looks selected.
    final filtered = selectedCategory == null
        ? categoryBreakdown
        : {selectedCategory!: categoryBreakdown[selectedCategory] ?? 0.0};
    final sorted = filtered.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return sorted
        .map((e) => _ChartEntry(label: e.key, value: e.value, isToday: false, isSparseLabel: true))
        .toList();
  }

  List<_ChartEntry> _dailyEntries() {
    final todayStr = DateTime.now().toIso8601String().substring(0, 10);
    return dailyBreakdown.map((raw) {
      final d = raw as Map<String, dynamic>;
      final date = d['date'] as String? ?? '';
      final label = d['label'] as String? ?? '';
      final dayNum = (d['dayNum'] as num?)?.toInt() ?? 0;
      final categories = (d['categories'] as Map?)?.cast<String, dynamic>() ?? {};
      final value = selectedCategory == null
          ? (d['total'] as num?)?.toDouble() ?? 0.0
          : (categories[selectedCategory] as num?)?.toDouble() ?? 0.0;
      final isSparse = dayNum == 1 || dayNum % 5 == 0;
      return _ChartEntry(
        label: label,
        value: value,
        isToday: date == todayStr,
        isSparseLabel: isSparse,
      );
    }).toList();
  }

  Widget _emptyState() {
    return Container(
      height: 220,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Text(
        selectedCategory != null ? 'No spending on $selectedCategory yet' : 'No spending yet',
        style: TextStyle(fontSize: 13, color: Colors.grey.shade400, fontWeight: FontWeight.w500),
      ),
    );
  }
}

class _ChartEntry {
  final String label;
  final double value;
  final bool isToday;
  final bool isSparseLabel;

  _ChartEntry({required this.label, required this.value, required this.isToday, required this.isSparseLabel});
}
