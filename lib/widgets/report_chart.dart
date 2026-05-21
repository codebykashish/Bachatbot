import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class ReportChart extends StatelessWidget {
  static const Color _primary = Color(0xFF2DBE7F);

  final Map<String, double> categoryBreakdown;
  final bool isCompact;
  final bool useLineChart; // true for line chart, false for bar chart

  const ReportChart({
    super.key,
    required this.categoryBreakdown,
    this.isCompact = false,
    this.useLineChart = false,
  });

  @override
  Widget build(BuildContext context) {
    if (categoryBreakdown.isEmpty) {
      return Container(
        height: isCompact ? 150 : 280,
        alignment: Alignment.center,
        child: const Text('No data available'),
      );
    }

    final categories = categoryBreakdown.keys.toList();
    final amounts = categoryBreakdown.values.toList();
    final maxY = amounts.isEmpty
        ? 100.0
        : (amounts.reduce((a, b) => a > b ? a : b) * 1.2).toDouble();

    final chartHeight = isCompact ? 150.0 : 280.0;

    return Container(
      height: chartHeight,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 12,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Category Breakdown',
            style: TextStyle(
              fontSize: isCompact ? 12 : 14,
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: useLineChart
                ? _buildLineChart(categories, amounts, maxY)
                : _buildBarChart(categories, amounts, maxY),
          ),
        ],
      ),
    );
  }

  Widget _buildLineChart(
      List<String> categories, List<double> amounts, double maxY) {
    final spots = List.generate(
      amounts.length,
      (i) => FlSpot(i.toDouble(), amounts[i]),
    );

    return LineChart(
      LineChartData(
        minY: 0,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: maxY / 4,
          getDrawingHorizontalLine: (_) =>
              FlLine(color: Colors.grey.shade100, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: isCompact ? 30 : 40,
              interval: maxY / 4,
              getTitlesWidget: (v, _) => Text(
                v.toInt().toString(),
                style: TextStyle(
                  fontSize: isCompact ? 8 : 10,
                  color: Colors.grey,
                ),
              ),
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) {
                final idx = v.toInt();
                if (idx < 0 || idx >= categories.length) {
                  return const SizedBox.shrink();
                }
                return Text(
                  categories[idx],
                  style: TextStyle(
                    fontSize: isCompact ? 8 : 10,
                    color: Colors.grey,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );
              },
            ),
          ),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: _primary,
            barWidth: 2.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  _primary.withValues(alpha: 0.25),
                  _primary.withValues(alpha: 0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBarChart(
      List<String> categories, List<double> amounts, double maxY) {
    final barGroups = List.generate(
      categories.length,
      (index) => BarChartGroupData(
        x: index,
        barRods: [
          BarChartRodData(
            toY: amounts[index],
            color: _primary,
            width: 16,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
          ),
        ],
      ),
    );

    return BarChart(
      BarChartData(
        maxY: maxY,
        barTouchData: BarTouchData(enabled: false),
        titlesData: FlTitlesData(
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: isCompact ? 30 : 40,
              getTitlesWidget: (value, meta) {
                return Text(
                  '${value.toInt()}',
                  style: TextStyle(
                    fontSize: isCompact ? 8 : 10,
                    color: Colors.grey,
                  ),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final index = value.toInt();
                if (index < 0 || index >= categories.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    categories[index],
                    style: TextStyle(
                      fontSize: isCompact ? 8 : 10,
                      color: Colors.grey,
                    ),
                    textAlign: TextAlign.center,
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
          getDrawingHorizontalLine: (_) => FlLine(
            color: Colors.grey.shade100,
            strokeWidth: 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        barGroups: barGroups,
      ),
    );
  }
}
