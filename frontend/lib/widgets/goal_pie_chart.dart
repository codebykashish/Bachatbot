import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

/// Small saved-vs-remaining donut chart for a single goal.
class GoalPieChart extends StatelessWidget {
  static const Color _primary = Color(0xFF2DBE7F);
  static const Color _remainingColor = Color(0xFFE0E4E8);

  final double saved;
  final double remaining;
  final double size;

  const GoalPieChart({
    super.key,
    required this.saved,
    required this.remaining,
    this.size = 140,
  });

  @override
  Widget build(BuildContext context) {
    final total = saved + remaining;
    final percent = total > 0 ? (saved / total * 100) : 0.0;

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        alignment: Alignment.center,
        children: [
          PieChart(
            PieChartData(
              sectionsSpace: 2,
              centerSpaceRadius: size * 0.32,
              startDegreeOffset: -90,
              sections: total <= 0
                  ? [
                      PieChartSectionData(
                        value: 1,
                        color: _remainingColor,
                        showTitle: false,
                        radius: size * 0.18,
                      ),
                    ]
                  : [
                      PieChartSectionData(
                        value: saved,
                        color: _primary,
                        showTitle: false,
                        radius: size * 0.18,
                      ),
                      PieChartSectionData(
                        value: remaining,
                        color: _remainingColor,
                        showTitle: false,
                        radius: size * 0.18,
                      ),
                    ],
            ),
          ),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${percent.toStringAsFixed(0)}%',
                style: TextStyle(fontSize: size * 0.16, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
              Text(
                'saved',
                style: TextStyle(fontSize: size * 0.08, color: Colors.grey.shade500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
