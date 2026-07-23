import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import 'adaptive_report_chart.dart';
import 'category_breakdown_list.dart';
import 'month_strip.dart';
import 'week_strip.dart';

/// The full report-exploration experience -- time-range tabs, year/month
/// navigation, the chart itself, and the category breakdown -- reached
/// only by tapping the compact month graph on the main Reports page.
/// Self-contained: fetches its own data independently of
/// ReportsScreenState, so switching tabs/months/weeks in here never
/// disturbs the main page's own "this month, right now" view underneath.
///
/// No category-type filter (Food/Transport/...) here -- the full
/// CategoryBreakdownList below already answers "which category," so a
/// separate filter narrowing the chart to one category at a time was
/// redundant. The breakdown list itself stays -- only the filter chips
/// were the redundant part.
class ReportExplorerSheet extends StatefulWidget {
  final int initialYear;
  final DateTime initialMonth;

  const ReportExplorerSheet({super.key, required this.initialYear, required this.initialMonth});

  @override
  State<ReportExplorerSheet> createState() => _ReportExplorerSheetState();
}

class _ReportExplorerSheetState extends State<ReportExplorerSheet> {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  String _selectedView = 'month'; // 'today' | 'week' | 'month'
  late DateTime _currentMonth;
  late String _selectedMonthKey;
  late int _selectedYear;
  int _selectedWeekIndex = 0;

  double _totalExpense = 0;
  Map<String, double> _categoryBreakdown = {};
  List<dynamic> _dailyBreakdown = [];
  Map<String, String> _categoryHealth = {};
  Map<String, double> _yearMonthTotals = {};

  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _currentMonth = DateTime(widget.initialMonth.year, widget.initialMonth.month, 1);
    _selectedMonthKey = _formatMonthKey(_currentMonth);
    _selectedYear = widget.initialYear;
    _loadReport();
  }

  String _formatMonthKey(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}';

  int _defaultWeekIndexForMonth(DateTime month) {
    final now = DateTime.now();
    if (month.year != now.year || month.month != now.month) return 0;
    final day = now.day;
    if (day <= 7) return 0;
    if (day <= 14) return 1;
    if (day <= 21) return 2;
    return 3;
  }

  void _setView(String view) {
    if (_selectedView == view) return;
    setState(() {
      _selectedView = view;
      _isLoading = true;
      if (view == 'week') _selectedWeekIndex = _defaultWeekIndexForMonth(_currentMonth);
    });
    _loadReport();
  }

  void _selectMonth(int month) {
    final next = DateTime(_selectedYear, month, 1);
    setState(() {
      _currentMonth = next;
      _selectedMonthKey = _formatMonthKey(next);
      _selectedWeekIndex = _defaultWeekIndexForMonth(next);
      _isLoading = true;
    });
    _loadReport();
  }

  void _previousYear() {
    final now = DateTime.now();
    final newYear = _selectedYear - 1;
    final newMonth = (newYear == now.year && _currentMonth.month > now.month) ? now.month : _currentMonth.month;
    final next = DateTime(newYear, newMonth, 1);
    setState(() {
      _selectedYear = newYear;
      _currentMonth = next;
      _selectedMonthKey = _formatMonthKey(next);
      _selectedWeekIndex = _defaultWeekIndexForMonth(next);
      _isLoading = true;
    });
    _loadReport();
  }

  void _nextYear() {
    final now = DateTime.now();
    if (_selectedYear >= now.year) return;
    final newYear = _selectedYear + 1;
    final newMonth = (newYear == now.year && _currentMonth.month > now.month) ? now.month : _currentMonth.month;
    final next = DateTime(newYear, newMonth, 1);
    setState(() {
      _selectedYear = newYear;
      _currentMonth = next;
      _selectedMonthKey = _formatMonthKey(next);
      _selectedWeekIndex = _defaultWeekIndexForMonth(next);
      _isLoading = true;
    });
    _loadReport();
  }

  void _shiftMonth(int delta) {
    final now = DateTime.now();
    final next = DateTime(_currentMonth.year, _currentMonth.month + delta, 1);
    if (next.year > now.year || (next.year == now.year && next.month > now.month)) return;
    setState(() {
      _currentMonth = next;
      _selectedMonthKey = _formatMonthKey(next);
      _selectedYear = next.year;
      _selectedWeekIndex = _defaultWeekIndexForMonth(next);
      _isLoading = true;
    });
    _loadReport();
  }

  void _selectWeek(int index) {
    if (_selectedWeekIndex == index) return;
    setState(() => _selectedWeekIndex = index);
  }

  Future<void> _loadReport() async {
    final myGen = ++_loadGeneration;
    final apiView = _selectedView == 'week' ? 'month' : _selectedView;
    try {
      final futures = await Future.wait([
        ApiService.get('/monthly-report?monthKey=$_selectedMonthKey&view=$apiView'),
        ApiService.get('/financial-health?monthKey=$_selectedMonthKey'),
        ApiService.get('/monthly-report/year-summary?year=$_selectedYear'),
      ]);
      final res = futures[0];
      final healthRes = futures[1];
      final yearRes = futures[2];

      if (!mounted || myGen != _loadGeneration) return;

      if (res['success'] == true) {
        final data = res['data'];
        final report = data?['report'] ?? data;

        Map<String, String> categoryHealth = {};
        if (healthRes['success'] == true) {
          final raw = healthRes['data']?['categoryHealth'] as Map?;
          if (raw != null) {
            categoryHealth = raw.map((k, v) => MapEntry(k.toString(), (v as Map)['status'] as String? ?? 'green'));
          }
        }

        final yearMonthTotals = yearRes['success'] == true ? _mapToDouble(yearRes['data']?['months'] ?? {}) : <String, double>{};

        setState(() {
          _totalExpense = (report?['totalExpense'] ?? 0).toDouble();
          _categoryBreakdown = _mapToDouble(report?['categoryBreakdown'] ?? {});
          _dailyBreakdown = report?['dailyBreakdown'] as List? ?? [];
          _categoryHealth = categoryHealth;
          _yearMonthTotals = yearMonthTotals;
          _isLoading = false;
        });
      } else if (myGen == _loadGeneration) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[ReportExplorerSheet] Error loading report: $e');
      if (mounted && myGen == _loadGeneration) setState(() => _isLoading = false);
    }
  }

  Map<String, double> _mapToDouble(dynamic map) {
    if (map is! Map) return {};
    return map.map<String, double>((k, v) => MapEntry(k.toString(), (v ?? 0).toDouble()));
  }

  // Buckets the month's dailyBreakdown into exactly 4 weeks (days 1-7,
  // 8-14, 15-21, 22-end) -- the 4th absorbs whatever's left (29-31).
  List<WeekBucketData> get _weekBuckets {
    if (_dailyBreakdown.isEmpty) return const [];
    final lastDay = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final ranges = [
      [1, 7], [8, 14], [15, 21], [22, lastDay],
    ];
    return List.generate(4, (i) {
      final start = ranges[i][0];
      final end = ranges[i][1];
      double total = 0;
      for (final raw in _dailyBreakdown) {
        final d = raw as Map<String, dynamic>;
        final dayNum = (d['dayNum'] as num?)?.toInt() ?? 0;
        if (dayNum < start || dayNum > end) continue;
        total += (d['total'] as num?)?.toDouble() ?? 0;
      }
      return WeekBucketData(label: 'Week ${i + 1}', total: total);
    });
  }

  double get _headlineAmount {
    if (_selectedView == 'week') {
      final buckets = _weekBuckets;
      if (buckets.isEmpty) return 0;
      return buckets[_selectedWeekIndex.clamp(0, buckets.length - 1)].total;
    }
    return _totalExpense;
  }

  String get _headlinePeriodLabel {
    switch (_selectedView) {
      case 'today':
        return 'today';
      case 'week':
        return 'in Week ${_selectedWeekIndex + 1}';
      default:
        return 'this month';
    }
  }

  Map<String, double> _weekCategoryBreakdown(int weekIndex) {
    if (_dailyBreakdown.isEmpty) return {};
    final lastDay = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final ranges = [
      [1, 7], [8, 14], [15, 21], [22, lastDay],
    ];
    final start = ranges[weekIndex][0];
    final end = ranges[weekIndex][1];
    final cats = <String, double>{};
    for (final raw in _dailyBreakdown) {
      final d = raw as Map<String, dynamic>;
      final dayNum = (d['dayNum'] as num?)?.toInt() ?? 0;
      if (dayNum < start || dayNum > end) continue;
      final dayCats = (d['categories'] as Map?)?.cast<String, dynamic>() ?? {};
      dayCats.forEach((k, v) => cats[k] = (cats[k] ?? 0) + (v as num? ?? 0).toDouble());
    }
    return cats;
  }

  // What the category breakdown list shows -- scoped to whichever
  // period is currently selected, same rule the headline above follows.
  Map<String, double> get _categoryBreakdownForDisplay {
    if (_selectedView == 'week') {
      final buckets = _weekBuckets;
      if (buckets.isEmpty) return {};
      return _weekCategoryBreakdown(_selectedWeekIndex.clamp(0, buckets.length - 1));
    }
    return _categoryBreakdown;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            const SizedBox(height: 10),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text('Explore Report', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 12),
            Expanded(
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator(color: _primary))
                  : SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(child: _TabChip(label: 'Today', selected: _selectedView == 'today', onTap: () => _setView('today'))),
                              const SizedBox(width: 8),
                              Expanded(child: _TabChip(label: 'Week', selected: _selectedView == 'week', onTap: () => _setView('week'))),
                              const SizedBox(width: 8),
                              Expanded(child: _TabChip(label: 'Month', selected: _selectedView == 'month', onTap: () => _setView('month'))),
                            ],
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _selectedView == 'month' ? 'Monthly Spending' : (_selectedView == 'week' ? 'Weekly Spending' : "Today's Spending"),
                            style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Rs ${NumberFormat('#,##0.00').format(_headlineAmount)}',
                            style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.black87),
                          ),
                          Text(
                            'Spending $_headlinePeriodLabel',
                            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
                          ),
                          const SizedBox(height: 16),
                          if (_selectedView == 'month') ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('$_selectedYear', style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.black87)),
                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(Icons.chevron_left, size: 20),
                                      onPressed: _previousYear,
                                      color: Colors.grey.shade600,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                    IconButton(
                                      icon: const Icon(Icons.chevron_right, size: 20),
                                      onPressed: _selectedYear >= DateTime.now().year ? null : _nextYear,
                                      color: Colors.grey.shade600,
                                      visualDensity: VisualDensity.compact,
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            _chartStripCard(
                              child: MonthStrip(
                                year: _selectedYear,
                                selectedMonth: _currentMonth.month,
                                monthTotals: _yearMonthTotals,
                                onSelect: _selectMonth,
                              ),
                            ),
                          ] else if (_selectedView == 'week') ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                IconButton(
                                  icon: const Icon(Icons.chevron_left, size: 20),
                                  onPressed: () => _shiftMonth(-1),
                                  color: Colors.grey.shade600,
                                  visualDensity: VisualDensity.compact,
                                ),
                                Text(
                                  DateFormat('MMMM yyyy').format(_currentMonth),
                                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.black87),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.chevron_right, size: 20),
                                  onPressed: (_currentMonth.year == DateTime.now().year && _currentMonth.month == DateTime.now().month)
                                      ? null
                                      : () => _shiftMonth(1),
                                  color: Colors.grey.shade600,
                                  visualDensity: VisualDensity.compact,
                                ),
                              ],
                            ),
                            _chartStripCard(
                              child: WeekStrip(
                                buckets: _weekBuckets,
                                selectedIndex: _selectedWeekIndex,
                                onSelect: _selectWeek,
                              ),
                            ),
                          ] else
                            AdaptiveReportChart(
                              mode: _selectedView,
                              categoryBreakdown: _categoryBreakdown,
                              dailyBreakdown: _dailyBreakdown,
                              categoryHealth: _categoryHealth,
                            ),
                          const SizedBox(height: 20),
                          const Text('Categories', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
                          const SizedBox(height: 10),
                          CategoryBreakdownList(categoryBreakdown: _categoryBreakdownForDisplay),
                        ],
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _chartStripCard({required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: child,
    );
  }
}

class _TabChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _TabChip({required this.label, required this.selected, required this.onTap});

  static const Color _primary = Color(0xFF2DBE7F);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? _primary : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? _primary : Colors.grey.shade300),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: selected ? Colors.white : Colors.grey.shade700),
        ),
      ),
    );
  }
}
