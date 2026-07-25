import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import 'adaptive_report_chart.dart';
import 'category_breakdown_list.dart';
import 'month_strip.dart';
import 'week_strip.dart';

/// The full report-exploration experience -- time-range tabs, year/month
/// navigation, the chart itself, a live Insights section, and the category
/// breakdown -- reached only by tapping the compact month graph on the main
/// Reports page. Self-contained: fetches its own data independently of
/// ReportsScreenState, so switching tabs/months/weeks in here never
/// disturbs the main page's own "this month, right now" view underneath.
///
/// Insights are context-aware: the cards shown change completely
/// depending on whether Today, Week, or Month is selected, using data
/// that was already in the /monthly-report response but previously unused.
class ReportExplorerSheet extends StatefulWidget {
  final int initialYear;
  final DateTime initialMonth;

  const ReportExplorerSheet({super.key, required this.initialYear, required this.initialMonth});

  @override
  State<ReportExplorerSheet> createState() => _ReportExplorerSheetState();
}

class _ReportExplorerSheetState extends State<ReportExplorerSheet> {
  static const Color _primary = Color(0xFF2DBE7F);
  static const Color _red    = Color(0xFFE0223B);
  static const Color _orange = Color(0xFFE67E22);
  static const Color _blue   = Color(0xFF2B6CB0);

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

  // ── Insight fields — parsed from the same /monthly-report response,
  // zero extra API calls needed.
  Map<String, dynamic> _categoryInsights = {};
  double _todayExpense = 0;
  String? _todayTopCategory;
  String? _paceWarningText;
  int _survivalBudgetPerDay = 0;
  int _daysRemaining = 0;

  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _currentMonth = DateTime(widget.initialMonth.year, widget.initialMonth.month, 1);
    _selectedMonthKey = _formatMonthKey(_currentMonth);
    _selectedYear = widget.initialYear;
    _loadReport();
  }

  String _formatMonthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

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
    final newMonth = (newYear == now.year && _currentMonth.month > now.month)
        ? now.month
        : _currentMonth.month;
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
    final newMonth = (newYear == now.year && _currentMonth.month > now.month)
        ? now.month
        : _currentMonth.month;
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
      final res      = futures[0];
      final healthRes = futures[1];
      final yearRes  = futures[2];

      if (!mounted || myGen != _loadGeneration) return;

      if (res['success'] == true) {
        final data   = res['data'];
        final report = data?['report'] ?? data;

        Map<String, String> categoryHealth = {};
        if (healthRes['success'] == true) {
          final raw = healthRes['data']?['categoryHealth'] as Map?;
          if (raw != null) {
            categoryHealth = raw.map(
              (k, v) => MapEntry(k.toString(), (v as Map)['status'] as String? ?? 'green'),
            );
          }
        }

        final yearMonthTotals = yearRes['success'] == true
            ? _mapToDouble(yearRes['data']?['months'] ?? {})
            : <String, double>{};

        // ── Parse insight fields from the existing report payload ──────────
        final rawInsights       = report?['insights'];
        final rawCategoryInsights =
            (rawInsights is Map ? rawInsights['categories'] : null) as Map? ?? {};

        setState(() {
          _totalExpense      = (report?['totalExpense'] ?? 0).toDouble();
          _categoryBreakdown = _mapToDouble(report?['categoryBreakdown'] ?? {});
          _dailyBreakdown    = report?['dailyBreakdown'] as List? ?? [];
          _categoryHealth    = categoryHealth;
          _yearMonthTotals   = yearMonthTotals;
          // Insights
          _categoryInsights    = Map<String, dynamic>.from(rawCategoryInsights);
          _todayExpense        = (report?['todayTotalExpense'] ?? 0).toDouble();
          _todayTopCategory    = report?['todayTopCategory'] as String?;
          _paceWarningText     = report?['paceWarningText'] as String?;
          _survivalBudgetPerDay =
              ((report?['survivalBudgetPerDay'] ?? 0) as num).round();
          _daysRemaining       = ((report?['daysRemaining'] ?? 0) as num).round();
          _isLoading           = false;
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
    return map.map<String, double>(
      (k, v) => MapEntry(k.toString(), (v ?? 0).toDouble()),
    );
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
      final end   = ranges[i][1];
      double total = 0;
      for (final raw in _dailyBreakdown) {
        final d      = raw as Map<String, dynamic>;
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
      case 'today': return 'today';
      case 'week':  return 'in Week ${_selectedWeekIndex + 1}';
      default:      return 'this month';
    }
  }

  Map<String, double> _weekCategoryBreakdown(int weekIndex) {
    if (_dailyBreakdown.isEmpty) return {};
    final lastDay = DateTime(_currentMonth.year, _currentMonth.month + 1, 0).day;
    final ranges = [
      [1, 7], [8, 14], [15, 21], [22, lastDay],
    ];
    final start = ranges[weekIndex][0];
    final end   = ranges[weekIndex][1];
    final cats  = <String, double>{};
    for (final raw in _dailyBreakdown) {
      final d      = raw as Map<String, dynamic>;
      final dayNum = (d['dayNum'] as num?)?.toInt() ?? 0;
      if (dayNum < start || dayNum > end) continue;
      final dayCats = (d['categories'] as Map?)?.cast<String, dynamic>() ?? {};
      dayCats.forEach((k, v) => cats[k] = (cats[k] ?? 0) + (v as num? ?? 0).toDouble());
    }
    return cats;
  }

  // What the category breakdown list shows — scoped to whichever period
  // is currently selected, same rule the headline above follows.
  Map<String, double> get _categoryBreakdownForDisplay {
    if (_selectedView == 'week') {
      final buckets = _weekBuckets;
      if (buckets.isEmpty) return {};
      return _weekCategoryBreakdown(_selectedWeekIndex.clamp(0, buckets.length - 1));
    }
    return _categoryBreakdown;
  }

  // ── Insight section dispatch ─────────────────────────────────────────────

  Widget _buildInsightsSection() {
    switch (_selectedView) {
      case 'today': return _buildTodayInsights();
      case 'week':  return _buildWeekInsights();
      default:      return _buildMonthInsights();
    }
  }

  // Today — compares each category's actual spend against its daily pace
  // (monthly budget ÷ 30). Uses _categoryBreakdown which is already
  // scoped to today when view=today is passed to the API.
  Widget _buildTodayInsights() {
    final cards = <Widget>[];

    if (_todayExpense == 0) {
      cards.add(const _InsightCard(
        icon: Icons.check_circle_outline_rounded,
        color: _primary,
        title: 'No expenses today',
        subtitle: "Nothing logged yet — great spending day so far!",
      ));
      return _insightSection(cards);
    }

    bool anyOverPace = false;
    for (final entry in _categoryBreakdown.entries) {
      final cat        = entry.key;
      final todaySpent = entry.value;
      final rawInfo    = _categoryInsights[cat];
      final monthlyLimit = rawInfo != null
          ? ((rawInfo as Map)['limit'] as num?)?.toDouble() ?? 0.0
          : 0.0;
      if (monthlyLimit <= 0) continue;
      final dailyPace = monthlyLimit / 30;
      if (todaySpent > dailyPace) {
        anyOverPace = true;
        cards.add(_InsightCard(
          icon: Icons.warning_amber_rounded,
          color: _red,
          title: '$cat: over daily pace',
          subtitle:
              'Rs ${NumberFormat('#,##0').format(todaySpent.round())} spent today — '
              'your pace is Rs ${NumberFormat('#,##0').format(dailyPace.round())}/day.',
        ));
      }
    }

    // Top category today
    if (_todayTopCategory != null &&
        _categoryBreakdown.containsKey(_todayTopCategory)) {
      final topSpent = _categoryBreakdown[_todayTopCategory!] ?? 0;
      final pct = _todayExpense > 0
          ? (topSpent / _todayExpense * 100).round()
          : 0;
      cards.add(_InsightCard(
        icon: Icons.bar_chart_rounded,
        color: _orange,
        title: '$_todayTopCategory led today\'s spending',
        subtitle:
            'Rs ${NumberFormat('#,##0').format(topSpent.round())} — '
            '$pct% of today\'s total.',
      ));
    }

    if (!anyOverPace) {
      cards.add(const _InsightCard(
        icon: Icons.check_circle_outline_rounded,
        color: _primary,
        title: 'Within daily pace today',
        subtitle: 'All categories are within their expected daily spend. 👍',
      ));
    }

    return _insightSection(cards);
  }

  // Week — compares the selected week's per-category spend against each
  // category's weekly pace (monthly budget ÷ 4).
  Widget _buildWeekInsights() {
    final cards    = <Widget>[];
    final weekData = _weekCategoryBreakdown(_selectedWeekIndex.clamp(0, 3));
    final weekTotal = weekData.values.fold(0.0, (a, b) => a + b);

    if (weekTotal == 0) {
      cards.add(_InsightCard(
        icon: Icons.check_circle_outline_rounded,
        color: _primary,
        title: 'No expenses in Week ${_selectedWeekIndex + 1}',
        subtitle: "Nothing logged in this week's window yet.",
      ));
      return _insightSection(cards);
    }

    bool anyOverPace = false;
    for (final entry in weekData.entries) {
      final cat       = entry.key;
      final weekSpent = entry.value;
      final rawInfo   = _categoryInsights[cat];
      final monthlyLimit = rawInfo != null
          ? ((rawInfo as Map)['limit'] as num?)?.toDouble() ?? 0.0
          : 0.0;
      if (monthlyLimit <= 0) continue;
      final weeklyPace = monthlyLimit / 4;
      if (weekSpent > weeklyPace) {
        anyOverPace = true;
        final overage = weekSpent - weeklyPace;
        cards.add(_InsightCard(
          icon: Icons.warning_amber_rounded,
          color: _red,
          title: '$cat: over weekly pace',
          subtitle:
              'Rs ${NumberFormat('#,##0').format(weekSpent.round())} this week — '
              'Rs ${NumberFormat('#,##0').format(overage.round())} over your '
              'Rs ${NumberFormat('#,##0').format(weeklyPace.round())}/week pace.',
        ));
      }
    }

    // Top category this week
    if (weekData.isNotEmpty) {
      final top = weekData.entries.reduce((a, b) => a.value > b.value ? a : b);
      final pct = weekTotal > 0 ? (top.value / weekTotal * 100).round() : 0;
      cards.add(_InsightCard(
        icon: Icons.bar_chart_rounded,
        color: _orange,
        title: '${top.key} led Week ${_selectedWeekIndex + 1}',
        subtitle:
            'Rs ${NumberFormat('#,##0').format(top.value.round())} — '
            '$pct% of this week\'s total.',
      ));
    }

    if (!anyOverPace) {
      cards.add(const _InsightCard(
        icon: Icons.check_circle_outline_rounded,
        color: _primary,
        title: 'On pace this week',
        subtitle: 'No category exceeded its weekly budget pace. Keep it up!',
      ));
    }

    return _insightSection(cards);
  }

  // Month — uses the backend-computed insights.categories (status per
  // category against the full monthly limit), the pre-computed
  // paceWarningText, and the survival budget per day.
  Widget _buildMonthInsights() {
    final cards = <Widget>[];

    // ① Over-budget categories (red)
    for (final entry in _categoryInsights.entries) {
      final info = entry.value as Map;
      if (info['status'] != 'overspent') continue;
      final spent = (info['spent'] as num?)?.toDouble() ?? 0;
      final limit = (info['limit'] as num?)?.toDouble() ?? 1;
      final pct   = limit > 0 ? (spent / limit * 100).round() : 0;
      cards.add(_InsightCard(
        icon: Icons.warning_rounded,
        color: _red,
        title: '${entry.key} is over budget ($pct%)',
        subtitle:
            'Rs ${NumberFormat('#,##0').format(spent.round())} spent of '
            'Rs ${NumberFormat('#,##0').format(limit.round())} limit — '
            'Rs ${NumberFormat('#,##0').format((spent - limit).round())} over.',
      ));
    }

    // ② Near-budget categories (orange) — "high" = 80–100%
    for (final entry in _categoryInsights.entries) {
      final info = entry.value as Map;
      if (info['status'] != 'high') continue;
      final spent     = (info['spent'] as num?)?.toDouble() ?? 0;
      final limit     = (info['limit'] as num?)?.toDouble() ?? 1;
      final remaining = (limit - spent).clamp(0.0, double.infinity);
      final pct       = limit > 0 ? (spent / limit * 100).round() : 0;
      cards.add(_InsightCard(
        icon: Icons.trending_up_rounded,
        color: _orange,
        title: '${entry.key} is at $pct% of budget',
        subtitle:
            'Only Rs ${NumberFormat('#,##0').format(remaining.round())} '
            'left for ${entry.key} this month.',
      ));
    }

    // ③ Pace warning (pre-computed by the backend)
    if (_paceWarningText != null && _paceWarningText!.isNotEmpty) {
      cards.add(_InsightCard(
        icon: Icons.speed_rounded,
        color: _orange,
        title: 'Spending faster than planned',
        subtitle: _paceWarningText!,
      ));
    }

    // ④ Daily survival budget
    if (_survivalBudgetPerDay > 0 && _daysRemaining > 0) {
      cards.add(_InsightCard(
        icon: Icons.calendar_today_rounded,
        color: _blue,
        title: 'Rs $_survivalBudgetPerDay/day to stay on track',
        subtitle:
            "That's your remaining budget spread over "
            '$_daysRemaining days left this month.',
      ));
    }

    // ⑤ All-clear if nothing is flagged
    if (cards.isEmpty) {
      cards.add(const _InsightCard(
        icon: Icons.check_circle_outline_rounded,
        color: _primary,
        title: 'All categories on track',
        subtitle: 'Every budget is within limit. Great financial month so far!',
      ));
    }

    return _insightSection(cards);
  }

  Widget _insightSection(List<Widget> cards) {
    if (cards.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 16,
              decoration: BoxDecoration(
                color: _primary,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            const Text(
              'Insights',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        ...cards.map(
          (c) => Padding(padding: const EdgeInsets.only(bottom: 8), child: c),
        ),
      ],
    );
  }

  // ── Build ─────────────────────────────────────────────────────────────────

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
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 8),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Explore Report',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
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
                          // ── View tabs ──────────────────────────────────────
                          Row(
                            children: [
                              Expanded(child: _TabChip(label: 'Today', selected: _selectedView == 'today', onTap: () => _setView('today'))),
                              const SizedBox(width: 8),
                              Expanded(child: _TabChip(label: 'Week',  selected: _selectedView == 'week',  onTap: () => _setView('week'))),
                              const SizedBox(width: 8),
                              Expanded(child: _TabChip(label: 'Month', selected: _selectedView == 'month', onTap: () => _setView('month'))),
                            ],
                          ),
                          const SizedBox(height: 16),

                          // ── Headline amount ────────────────────────────────
                          Text(
                            _selectedView == 'month'
                                ? 'Monthly Spending'
                                : _selectedView == 'week'
                                    ? 'Weekly Spending'
                                    : "Today's Spending",
                            style: TextStyle(
                              fontSize: 13,
                              color: Colors.grey.shade600,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'Rs ${NumberFormat('#,##0.00').format(_headlineAmount)}',
                            style: const TextStyle(
                              fontSize: 26,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          Text(
                            'Spending $_headlinePeriodLabel',
                            style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
                          ),
                          const SizedBox(height: 16),

                          // ── Chart / strip ──────────────────────────────────
                          if (_selectedView == 'month') ...[
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  '$_selectedYear',
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black87,
                                  ),
                                ),
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
                                      onPressed: _selectedYear >= DateTime.now().year
                                          ? null
                                          : _nextYear,
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
                                  style: const TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.black87,
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(Icons.chevron_right, size: 20),
                                  onPressed: (_currentMonth.year == DateTime.now().year &&
                                          _currentMonth.month == DateTime.now().month)
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

                          // ── Insights ───────────────────────────────────────
                          _buildInsightsSection(),
                          const SizedBox(height: 20),

                          // ── Category breakdown ─────────────────────────────
                          const Text(
                            'Categories',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          const SizedBox(height: 10),
                          CategoryBreakdownList(
                            categoryBreakdown: _categoryBreakdownForDisplay,
                          ),
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
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: child,
    );
  }
}

// ── Insight card ─────────────────────────────────────────────────────────────

class _InsightCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;

  const _InsightCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.22)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.13),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 18),
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
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey.shade600,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Tab chip ─────────────────────────────────────────────────────────────────

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
          border: Border.all(
            color: selected ? _primary : Colors.grey.shade300,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : Colors.grey.shade700,
          ),
        ),
      ),
    );
  }
}
