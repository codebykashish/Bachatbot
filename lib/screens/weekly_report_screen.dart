import 'package:flutter/material.dart';
import '../api_service.dart';
import '../widgets/report_chart.dart';
import '../widgets/shared_widgets.dart';
import 'notification_screen.dart';

/// Same structure as the monthly Reports screen (overall status, total
/// spending, category chart, category insights) but scoped to a single
/// week (1-4) within the given month. Has its own Week 1/2/3/4 navigator
/// so the user can browse weeks without going back to the month screen.
class WeeklyReportScreen extends StatefulWidget {
  final String monthKey;   // "YYYY-MM"
  final String monthLabel; // e.g. "July 2026"
  final int initialWeek;   // 1-4

  const WeeklyReportScreen({
    super.key,
    required this.monthKey,
    required this.monthLabel,
    required this.initialWeek,
  });

  @override
  State<WeeklyReportScreen> createState() => _WeeklyReportScreenState();
}

class _WeeklyReportScreenState extends State<WeeklyReportScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  late int _selectedWeek;
  bool _isLoading = true;

  double _totalExpense = 0;
  Map<String, double> _categoryBreakdown = {};
  Map<String, dynamic> _categoryInsights = {};
  String _overallStatus = 'ok';
  String _dateRange = '';

  @override
  void initState() {
    super.initState();
    _selectedWeek = widget.initialWeek;
    _loadReport();
  }

  Map<String, double> _mapToDouble(dynamic map) {
    if (map is! Map) return {};
    return map.map<String, double>((k, v) => MapEntry(k.toString(), (v ?? 0).toDouble()));
  }

  void _setWeek(int week) {
    if (_selectedWeek == week) return;
    setState(() {
      _selectedWeek = week;
      _isLoading = true;
    });
    _loadReport();
  }

  Future<void> _loadReport() async {
    try {
      final res = await ApiService.get('/monthly-report?monthKey=${widget.monthKey}&weekOfMonth=$_selectedWeek');

      if (!mounted) return;

      if (res['success'] == true) {
        final data = res['data'];
        final report = data?['report'] ?? data;

        final weeklyBreakdown = report?['weeklyBreakdown'] as List? ?? [];
        String dateRange = '';
        if (weeklyBreakdown.length >= _selectedWeek) {
          dateRange = (weeklyBreakdown[_selectedWeek - 1] as Map<String, dynamic>)['dateRange'] as String? ?? '';
        }

        setState(() {
          _totalExpense = (report?['totalExpense'] ?? 0).toDouble();
          _categoryBreakdown = _mapToDouble(report?['categoryBreakdown'] ?? {});
          _overallStatus = report?['insights']?['overallStatus'] ?? 'ok';
          _categoryInsights = report?['insights']?['categories'] ?? {};
          _dateRange = dateRange;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[WeeklyReportScreen] Error loading report: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildWeekNavigator() {
    return Row(
      children: List.generate(4, (i) {
        final week = i + 1;
        final selected = week == _selectedWeek;
        return Expanded(
          child: Padding(
            padding: EdgeInsets.only(right: i < 3 ? 8 : 0),
            child: GestureDetector(
              onTap: () => _setWeek(week),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 10),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected ? _primary : Colors.white,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: selected ? _primary : Colors.grey.shade300),
                ),
                child: Text(
                  selected ? '‹ Week $week ›' : '$week',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : Colors.grey.shade700,
                  ),
                ),
              ),
            ),
          ),
        );
      }),
    );
  }

  Widget _buildOverallStatusCard() {
    String statusText;
    Color statusColor;
    IconData statusIcon;

    switch (_overallStatus.toLowerCase()) {
      case 'low':
      case 'on track':
      case 'ok':
        statusText = 'Low spending — on budget';
        statusColor = _primary;
        statusIcon = Icons.check_circle;
        break;
      case 'medium':
      case 'warning':
        statusText = 'Medium — approaching budget limit';
        statusColor = Colors.amber.shade700;
        statusIcon = Icons.info_outline;
        break;
      case 'high':
      case 'danger':
        statusText = 'High — close to budget limit';
        statusColor = Colors.orange.shade700;
        statusIcon = Icons.warning_amber;
        break;
      case 'overspent':
        statusText = 'Overspent this week';
        statusColor = Colors.red;
        statusIcon = Icons.warning_amber;
        break;
      default:
        statusText = 'Overall Status: $_overallStatus';
        statusColor = _primary;
        statusIcon = Icons.check_circle;
    }

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(statusIcon, color: statusColor, size: 24),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Overall Status',
                  style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 4),
                Text(
                  statusText,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: statusColor),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTotalSpendingCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Week $_selectedWeek Spending${_dateRange.isNotEmpty ? ' ($_dateRange)' : ''}',
            style: const TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                'Rs ${_totalExpense.toInt()}',
                style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.black87),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryChart() {
    return ReportChart(categoryBreakdown: _categoryBreakdown, isCompact: false);
  }

  Widget _buildCategoryInsights() {
    if (_categoryInsights.isEmpty) return const SizedBox.shrink();

    final sortedCategories = _categoryInsights.keys.cast<String>().toList()..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Category Insights',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        const SizedBox(height: 12),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: sortedCategories.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final category = sortedCategories[index];
            final insight = _categoryInsights[category] ?? {};
            final status = (insight['status'] ?? 'ok') as String;
            final spent = (insight['spent'] ?? 0).toDouble().toInt();
            final limit = (insight['limit'] ?? 0).toDouble().toInt();
            final pct = limit > 0 ? (spent / limit * 100).clamp(0, 999).toInt() : 0;
            final barValue = (pct / 100).clamp(0.0, 1.0);
            final barColor = progressColor(status);

            return InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => NotificationScreen(
                    initialType: 'expense',
                    initialCategory: category,
                    initialDateRange: 'week',
                  ),
                ),
              ),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(categoryIcon(category), size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Text(
                          category,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade800),
                        ),
                        const Spacer(),
                        statusBadge(status),
                        const SizedBox(width: 6),
                        Icon(Icons.chevron_right, size: 16, color: Colors.grey.shade400),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: barValue,
                        minHeight: 6,
                        backgroundColor: Colors.grey.shade100,
                        valueColor: AlwaysStoppedAnimation<Color>(barColor),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Text(
                          'Rs $spent',
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey.shade800),
                        ),
                        Text(' / Rs $limit', style: TextStyle(fontSize: 12, color: Colors.grey.shade400)),
                        const Spacer(),
                        Text('$pct%', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: barColor)),
                      ],
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: Text('Weekly Report — ${widget.monthLabel}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
      ),
      body: RefreshIndicator(
        color: _primary,
        onRefresh: _loadReport,
        child: _isLoading
            ? const Center(child: CircularProgressIndicator(color: _primary))
            : SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildWeekNavigator(),
                    const SizedBox(height: 20),
                    _buildOverallStatusCard(),
                    const SizedBox(height: 20),
                    _buildTotalSpendingCard(),
                    const SizedBox(height: 16),
                    _buildCategoryChart(),
                    const SizedBox(height: 20),
                    _buildCategoryInsights(),
                    const SizedBox(height: 20),
                  ],
                ),
              ),
      ),
    );
  }
}
