import 'package:flutter/material.dart';
import '../api_service.dart';
import '../widgets/report_chart.dart';
import 'notification_screen.dart';

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
  double _totalIncome = 0;
  double _netSavings = 0;
  Map<String, double> _categoryBreakdown = {};
  Map<String, dynamic> _categoryInsights = {};
  String _overallStatus = 'ok';

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
      final res = await ApiService.get(
        '/monthly-report?monthKey=$_selectedMonthKey&view=$_selectedView',
      );

      if (!mounted) return;

      if (res['success'] == true) {
        final data = res['data'];
        final report = data?['report'] ?? data;

        setState(() {
          _totalExpense = (report?['totalExpense'] ?? 0).toDouble();
          _totalIncome = (report?['totalIncome'] ?? 0).toDouble();
          _netSavings = (report?['netSavings'] ?? 0).toDouble();
          _categoryBreakdown = _mapToDouble(report?['categoryBreakdown'] ?? {});
          _overallStatus = report?['insights']?['overallStatus'] ?? 'ok';
          _categoryInsights = report?['insights']?['categories'] ?? {};
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

  // ── Category insight helpers ─────────────────────────────────────────────

  IconData _insightIcon(String? category) {
    switch (category?.toLowerCase()) {
      case 'food':          return Icons.restaurant_outlined;
      case 'transport':     return Icons.directions_bus_outlined;
      case 'rent':          return Icons.home_outlined;
      case 'shopping':      return Icons.shopping_bag_outlined;
      case 'health':        return Icons.local_hospital_outlined;
      case 'education':     return Icons.school_outlined;
      case 'bills':         return Icons.receipt_long_outlined;
      case 'entertainment': return Icons.movie_outlined;
      default:              return Icons.category_outlined;
    }
  }

  Color _progressColor(String status) {
    switch (status.toLowerCase()) {
      case 'low':     return Colors.blue.shade400;
      case 'warning': return Colors.amber.shade600;
      case 'high':
      case 'danger':
      case 'overspent': return Colors.red.shade500;
      default:        return Colors.green;
    }
  }

  Widget _statusBadge(String status) {
    final Color bg;
    final Color fg;
    final String label;
    switch (status.toLowerCase()) {
      case 'low':
        bg = Colors.blue.shade50; fg = Colors.blue.shade700; label = 'LOW';
        break;
      case 'warning':
        bg = Colors.amber.shade50; fg = Colors.amber.shade800; label = 'WARNING';
        break;
      case 'high':
      case 'danger':
      case 'overspent':
        bg = Colors.red.shade50; fg = Colors.red.shade700; label = 'HIGH';
        break;
      case 'ok':
      case 'exact':
        bg = Colors.green.shade50; fg = Colors.green.shade700; label = 'OK';
        break;
      default:
        bg = Colors.grey.shade100;
        fg = Colors.grey.shade600;
        label = status.toUpperCase();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: fg,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  Widget _buildOverallStatusCard() {
    String statusText;
    Color statusColor;

    switch (_overallStatus.toLowerCase()) {
      case 'overspent':
        statusText = 'Overspent this month';
        statusColor = Colors.red;
        break;
      case 'on track':
        statusText = 'On track this month';
        statusColor = _primary;
        break;
      default:
        statusText = 'Overall Status: $_overallStatus';
        statusColor = _primary;
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
              _overallStatus.toLowerCase() == 'overspent'
                  ? Icons.warning_amber
                  : Icons.check_circle,
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
                      'Income: Rs ${_totalIncome.toInt()}',
                      style: const TextStyle(
                        fontSize: 12,
                        color: Colors.grey,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Savings: Rs ${_netSavings.toInt()}',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _netSavings >= 0 ? _primary : Colors.red,
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
            final barColor = _progressColor(status);

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
                        Icon(_insightIcon(category),
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
                        _statusBadge(status),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        title: const Text(
          'Monthly Report',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.black87,
            fontSize: 20,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
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
                    // ── View selector and month navigation ──────────────────
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: Colors.grey.shade200,
                                width: 1,
                              ),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<String>(
                                value: _selectedView,
                                isExpanded: true,
                                items: const [
                                  DropdownMenuItem(
                                    value: 'month',
                                    child: Text('Monthly View'),
                                  ),
                                  DropdownMenuItem(
                                    value: 'week',
                                    child: Text('Weekly View'),
                                  ),
                                ],
                                onChanged: (value) {
                                  if (value != null && value != _selectedView) {
                                    setState(() {
                                      _selectedView = value;
                                      _isLoading = true;
                                    });
                                    _loadReport();
                                  }
                                },
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 12),

                    // ── Month navigation ──────────────────────────────────
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

                    const SizedBox(height: 20),

                    // ── Total Spending Card ───────────────────────────────
                    _buildTotalSpendingCard(),

                    const SizedBox(height: 20),

                    // ── Category Breakdown Chart ──────────────────────────
                    _buildCategoryChart(),

                    const SizedBox(height: 20),

                    // ── Category Insights ─────────────────────────────────
                    _buildCategoryInsights(),

                    const SizedBox(height: 20),
                  ],
                ),
              ),
      ),
    );
  }
}
