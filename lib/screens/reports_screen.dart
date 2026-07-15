import 'package:flutter/material.dart';
import '../api_service.dart';
import '../widgets/report_chart.dart';
import '../widgets/shared_widgets.dart';
import '../models/goal.dart';
import 'notification_screen.dart';
import 'weekly_report_screen.dart';
import 'goals_screen.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

  @override
  State<ReportsScreen> createState() => ReportsScreenState();
}

class ReportsScreenState extends State<ReportsScreen>
    with WidgetsBindingObserver {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  String _selectedView = 'month'; // 'month' or 'week'
  String _selectedMonthKey = '';

  // Report data
  double _totalExpense = 0;
  double _declaredIncome = 0; // From /income endpoint (declared, not transaction)
  Map<String, double> _categoryBreakdown = {};
  Map<String, dynamic> _categoryInsights = {};
  String _overallStatus = 'ok';
  List<dynamic> _weeklyBreakdown = [];
  List<Goal> _goals = [];

  // Months for navigation
  late DateTime _currentMonth;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final now = DateTime.now();
    _currentMonth = DateTime(now.year, now.month, 1);
    _selectedMonthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    _loadReport();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadReport();
  }

  void refresh() => _loadReport();

  String _formatMonthKey(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}';
  }

  String _formatMonthLabel(DateTime date) {
    const months = [
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December'
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  void _previousMonth() {
    final prev = DateTime(_currentMonth.year, _currentMonth.month - 1);
    setState(() {
      _currentMonth = prev;
      _selectedMonthKey = _formatMonthKey(prev);
      _isLoading = true;
    });
    _loadReport();
  }

  void _setView(String view) {
    if (_selectedView == view) return;
    setState(() {
      _selectedView = view;
      _isLoading = true;
    });
    _loadReport();
  }

  void _nextMonth() {
    final now = DateTime.now();
    if (_currentMonth.year == now.year && _currentMonth.month == now.month) {
      return; // Don't allow future months
    }
    final next = DateTime(_currentMonth.year, _currentMonth.month + 1);
    setState(() {
      _currentMonth = next;
      _selectedMonthKey = _formatMonthKey(next);
      _isLoading = true;
    });
    _loadReport();
  }

  Future<void> _loadReport() async {
    try {
      final futures = await Future.wait([
        ApiService.get('/monthly-report?monthKey=$_selectedMonthKey&view=$_selectedView'),
        ApiService.get('/income'),
        ApiService.get('/goals'),
      ]);
      final res = futures[0];
      final incomeRes = futures[1];
      final goalsRes = futures[2];

      if (!mounted) return;

      if (res['success'] == true) {
        final data = res['data'];
        final report = data?['report'] ?? data;

        double declared = 0;
        if (incomeRes['success'] == true) {
          declared = (incomeRes['data']?['total'] ?? 0).toDouble();
        }

        List<Goal> goals = [];
        if (goalsRes['success'] == true) {
          goals = (goalsRes['data']?['goals'] as List? ?? [])
              .map((g) => Goal.fromJson(g as Map<String, dynamic>))
              .toList();
        }

        setState(() {
          _totalExpense = (report?['totalExpense'] ?? 0).toDouble();
          _declaredIncome = declared;
          _categoryBreakdown = _mapToDouble(report?['categoryBreakdown'] ?? {});
          _overallStatus = report?['insights']?['overallStatus'] ?? 'ok';
          _categoryInsights = report?['insights']?['categories'] ?? {};
          _weeklyBreakdown = report?['weeklyBreakdown'] as List? ?? [];
          _goals = goals;
          _isLoading = false;
        });
      } else {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[ReportsScreen] Error loading report: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Map<String, double> _mapToDouble(dynamic map) {
    if (map is! Map) return {};
    return map.map<String, double>(
      (k, v) => MapEntry(k.toString(), (v ?? 0).toDouble()),
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
        statusText = 'Overspent this month';
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
            child: Icon(
              statusIcon,
              color: statusColor,
              size: 24,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Overall Status',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  statusText,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: statusColor,
                  ),
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
          const Text(
            'Total Spending',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Text(
                'Rs ${_totalExpense.toInt()}',
                style: const TextStyle(
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Income: Rs ${_declaredIncome.toInt()}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Savings: Rs ${(_declaredIncome - _totalExpense).toInt()}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: (_declaredIncome - _totalExpense) >= 0 ? _primary : Colors.red,
                      ),
                    ),
                  ],
                ),
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
    if (_categoryInsights.isEmpty) {
      return const SizedBox.shrink();
    }

    final sortedCategories = _categoryInsights.keys.cast<String>().toList()
      ..sort();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Category Insights',
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
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
            final pct = limit > 0
                ? (spent / limit * 100).clamp(0, 999).toInt()
                : 0;
            final barValue = (pct / 100).clamp(0.0, 1.0);
            final barColor = progressColor(status);

            return InkWell(
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => NotificationScreen(
                    initialType: 'expense',
                    initialCategory: category,
                    initialDateRange: 'month',
                  ),
                ),
              ),
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade200),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Row 1: icon + name + badge + chevron
                    Row(
                      children: [
                        Icon(categoryIcon(category),
                            size: 18, color: Colors.grey.shade600),
                        const SizedBox(width: 8),
                        Text(
                          category,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade800,
                          ),
                        ),
                        const Spacer(),
                        statusBadge(status),
                        const SizedBox(width: 6),
                        Icon(Icons.chevron_right,
                            size: 16, color: Colors.grey.shade400),
                      ],
                    ),
                    const SizedBox(height: 8),
                    // Row 2: progress bar
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: barValue,
                        minHeight: 6,
                        backgroundColor: Colors.grey.shade100,
                        valueColor:
                            AlwaysStoppedAnimation<Color>(barColor),
                      ),
                    ),
                    const SizedBox(height: 6),
                    // Row 3: spent / budget + percentage
                    Row(
                      children: [
                        Text(
                          'Rs $spent',
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.grey.shade800,
                          ),
                        ),
                        Text(
                          ' / Rs $limit',
                          style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade400),
                        ),
                        const Spacer(),
                        Text(
                          '$pct%',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: barColor,
                          ),
                        ),
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

  Widget _buildWeeklyBreakdown() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Weekly Breakdown',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        const SizedBox(height: 12),
        ListView.separated(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: _weeklyBreakdown.length,
          separatorBuilder: (_, __) => const SizedBox(height: 8),
          itemBuilder: (context, index) {
            final week = _weeklyBreakdown[index] as Map<String, dynamic>;
            final label = week['label'] as String? ?? 'Week ${index + 1}';
            final dateRange = week['dateRange'] as String? ?? '';
            final expense = (week['totalExpense'] ?? 0).toDouble().toInt();

            // Highlight whichever week bucket contains today, when viewing
            // the current month — makes "where am I right now" obvious.
            final now = DateTime.now();
            final isCurrentMonth = _currentMonth.year == now.year && _currentMonth.month == now.month;
            final isCurrentWeek = isCurrentMonth && (index == ((now.day - 1) ~/ 7).clamp(0, 3));

            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => WeeklyReportScreen(
                    monthKey: _selectedMonthKey,
                    monthLabel: _formatMonthLabel(_currentMonth),
                    initialWeek: index + 1,
                  ),
                ),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: BoxDecoration(
                  color: isCurrentWeek ? _primary.withValues(alpha: 0.06) : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: isCurrentWeek ? _primary.withValues(alpha: 0.4) : Colors.grey.shade200),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: isCurrentWeek ? _primary : Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Text(
                        '${index + 1}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                          color: isCurrentWeek ? Colors.white : Colors.grey.shade600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            label,
                            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.black87),
                          ),
                          if (dateRange.isNotEmpty)
                            Text(
                              dateRange,
                              style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                            ),
                        ],
                      ),
                    ),
                    Text(
                      'Rs $expense',
                      style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFFD85E5E)),
                    ),
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right, size: 16, color: Colors.grey.shade400),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildGoalsSummary() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.06), blurRadius: 12, offset: const Offset(0, 4))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Savings Goals', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87)),
              TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GoalsScreen())),
                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                child: const Text('View all', style: TextStyle(color: _primary, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 12),
          ...(_goals.take(3).map((g) {
            final progress = (g.percentComplete / 100).clamp(0.0, 1.0);
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Expanded(
                        child: Text(g.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis),
                      ),
                      Text(
                        'Rs ${g.savedSoFar.toInt()} / Rs ${g.targetAmount.toInt()}',
                        style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: progress, minHeight: 6, backgroundColor: Colors.grey.shade200, color: _primary),
                  ),
                ],
              ),
            );
          })),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      body: RefreshIndicator(
        color: _primary,
        onRefresh: _loadReport,
        child: _isLoading
            ? const Center(
                child: CircularProgressIndicator(color: _primary),
              )
            : SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Month / Week toggle ───────────────────────────────
                    Row(
                      children: [
                        Expanded(
                          child: _ViewToggleChip(
                            label: 'This Month',
                            selected: _selectedView == 'month',
                            onTap: () => _setView('month'),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _ViewToggleChip(
                            label: 'Last 7 Days',
                            selected: _selectedView == 'week',
                            onTap: () => _setView('week'),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 16),

                    // ── Month navigation (month view only — week view is
                    // always "the last 7 days from today", not a
                    // navigable calendar month) ───────────────────────────
                    if (_selectedView == 'week')
                      const Text(
                        'Last 7 Days',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                      )
                    else
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left),
                            onPressed: _previousMonth,
                            color: _primary,
                          ),
                          Text(
                            _formatMonthLabel(_currentMonth),
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.black87,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right),
                            onPressed: _currentMonth.year ==
                                        DateTime.now().year &&
                                    _currentMonth.month == DateTime.now().month
                                ? null
                                : _nextMonth,
                            color: _currentMonth.year == DateTime.now().year &&
                                    _currentMonth.month == DateTime.now().month
                                ? Colors.grey.shade300
                                : _primary,
                          ),
                        ],
                      ),

                    const SizedBox(height: 24),

                    // ── Overall Status Card ───────────────────────────────
                    _buildOverallStatusCard(),

                    // ── Savings Goals summary ─────────────────────────────
                    if (_goals.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _buildGoalsSummary(),
                    ],

                    const SizedBox(height: 20),

                    // ── Total Spending Card ───────────────────────────────
                    _buildTotalSpendingCard(),

                    const SizedBox(height: 16),

                    // ── Category Breakdown Chart ──────────────────────────
                    _buildCategoryChart(),

                    const SizedBox(height: 20),

                    // ── Category Insights ─────────────────────────────────
                    _buildCategoryInsights(),

                    // ── Weekly Breakdown (month view only) ────────────────
                    if (_selectedView == 'month' && _weeklyBreakdown.isNotEmpty) ...[
                      const SizedBox(height: 20),
                      _buildWeeklyBreakdown(),
                    ],

                    const SizedBox(height: 20),
                  ],
                ),
              ),
      ),
    );
  }
}

class _ViewToggleChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ViewToggleChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

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
