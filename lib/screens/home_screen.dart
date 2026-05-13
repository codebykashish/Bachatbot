import 'dart:math';
import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../api_service.dart';
import 'categories_screen.dart';

// State is public so MainScreen can call refresh() via GlobalKey
class HomeScreen extends StatefulWidget {
  final String firstName;

  const HomeScreen({super.key, required this.firstName});

  @override
  HomeScreenState createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  List<dynamic> _budgets = [];
  Map<String, dynamic>? _report;
  List<dynamic> _trendData = [];

  bool _isIncomeFlipped = false;
  bool _isExpenseFlipped = false;
  String _selectedMonth = '';

  static const List<Map<String, dynamic>> _catMeta = [
    {'name': 'Food',          'icon': Icons.restaurant,        'color': Color(0xFF4A90E2)},
    {'name': 'Transport',     'icon': Icons.directions_car,    'color': Color(0xFF26A69A)},
    {'name': 'Rent',          'icon': Icons.home,              'color': Color(0xFFFFB74D)},
    {'name': 'Education',     'icon': Icons.school,            'color': Color(0xFF7E57C2)},
    {'name': 'Shopping',      'icon': Icons.shopping_bag,      'color': Color(0xFFAB47BC)},
    {'name': 'Health',        'icon': Icons.favorite,          'color': Color(0xFFEF5350)},
    {'name': 'Entertainment', 'icon': Icons.tv,                'color': Color(0xFF8D6E63)},
    {'name': 'Bills',         'icon': Icons.receipt_long,      'color': Color(0xFF78909C)},
    {'name': 'Salary',        'icon': Icons.account_balance_wallet, 'color': Color(0xFF66BB6A)},
    {'name': 'Other',         'icon': Icons.category,          'color': Color(0xFFFFCA28)},
  ];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    _fetchAll();
  }

  /// Called by MainScreen after a chat message is sent.
  /// Does NOT re-fetch profile (already cached).
  void refresh() => _refreshData();

  String get _monthLabel {
    final parts = _selectedMonth.split('-');
    if (parts.length != 2) return _selectedMonth;
    const months = [
      'Jan','Feb','Mar','Apr','May','Jun',
      'Jul','Aug','Sep','Oct','Nov','Dec'
    ];
    final m = int.tryParse(parts[1]);
    if (m == null || m < 1 || m > 12) return _selectedMonth;
    return '${months[m - 1]} ${parts[0]}';
  }

  // ── Data fetching ────────────────────────────────────────────────────────

  /// Full fetch including profile (called once on init)
  Future<void> _fetchAll() async {
    setState(() => _isLoading = true);
    try {
      final futures = <Future>[_fetchBudgets(), _fetchReport(), _fetchTrend()];
      await Future.wait(futures);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Data-only refresh (skips profile, used after chat)
  Future<void> _refreshData() async {
    // Don't set _isLoading = true so we don't flash '…' on cards
    try {
      await Future.wait([_fetchBudgets(), _fetchReport(), _fetchTrend()]);
    } catch (_) {}
  }



  Future<void> _fetchBudgets() async {
    try {
      final res = await ApiService.get('/budgets?monthKey=$_selectedMonth');
      if (!mounted) return;
      debugPrint('[HomeScreen] /budgets response keys: ${res.keys}');
      if (res['success'] == true) {
        setState(() => _budgets = res['data']?['budgets'] ?? []);
      }
    } catch (e) {
      debugPrint('[HomeScreen] /budgets error: $e');
    }
  }

  /// GET /monthly-report — source of truth for income & totalExpense & daily snapshot
  Future<void> _fetchReport() async {
    try {
      final res = await ApiService.get('/monthly-report?monthKey=$_selectedMonth');
      if (!mounted) return;
      debugPrint('[HomeScreen] /monthly-report response: $res');
      if (res['success'] == true) {
        setState(() {
          final data = res['data'];
          _report = data?['report'] ?? data;
        });
      }
    } catch (e) {
      debugPrint('[HomeScreen] /monthly-report error: $e');
    }
  }

  Future<void> _fetchTrend() async {
    try {
      final res = await ApiService.get('/daily-summary');
      if (!mounted) return;
      if (res['success'] == true) {
        final raw = res['data']?['days']
            ?? res['data']?['trend']
            ?? res['data']?['dailySummary']
            ?? [];
        setState(() => _trendData = raw);
      }
    } catch (_) {}
  }

  // ── Derived values ───────────────────────────────────────────────────────

  double get _totalIncome =>
      (_report?['totalIncome'] ?? _report?['income'] ?? 0).toDouble();

  double get _totalExpense =>
      (_report?['totalExpense'] ?? _report?['expense'] ?? 0).toDouble();

  // Daily snapshot fields from /monthly-report
  double get _todayTotalExpense =>
      (_report?['todayTotalExpense'] ?? 0).toDouble();

  String get _todayTopCategory =>
      (_report?['todayTopCategory'] ?? '').toString();

  String get _todaySummaryText =>
      (_report?['todaySummaryText'] ?? '').toString();

  String get _greetingName {
    // 1. Prioritize widget.firstName (from backend profile entered during signup)
    if (widget.firstName.trim().isNotEmpty && widget.firstName.trim() != 'User') {
      return widget.firstName.trim();
    }

    // 2. Try Firebase Display Name (saved during signup)
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && user.displayName != null && user.displayName!.trim().isNotEmpty) {
      return user.displayName!.trim();
    }
    
    // 3. Fallback
    return 'User';
  }

  // ── Flip card ────────────────────────────────────────────────────────────

  Widget _buildFlipCard({
    required String title,
    required IconData icon,
    required Color bgColor,
    required Color accentColor,
    required String amountText,
    required bool isFlipped,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(isFlipped ? pi : 0),
          transformAlignment: Alignment.center,
          child: Container(
            height: 90,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: accentColor.withValues(alpha: 0.3), width: 1.2),
            ),
            alignment: Alignment.center,
            child: isFlipped
                ? Transform(
                    transform: Matrix4.identity()..rotateY(pi),
                    alignment: Alignment.center,
                    child: Text(
                      amountText,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: accentColor,
                      ),
                    ),
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(6),
                        decoration: BoxDecoration(
                          color: accentColor.withValues(alpha: 0.15),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, color: accentColor, size: 20),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                          color: accentColor,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  // ── 7-day chart ──────────────────────────────────────────────────────────

  Widget _build7DayChart() {
    const labels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    List<double> amounts;

    if (_trendData.isNotEmpty) {
      amounts = _trendData
          .take(7)
          .map<double>((d) => (d['amount'] ?? d['total'] ?? 0).toDouble())
          .toList();
      while (amounts.length < 7) { amounts.add(0); }
    } else {
      amounts = [0, 0, 0, 0, 0, 0, 0];
    }

    final maxY = amounts.every((a) => a == 0)
        ? 100.0
        : (amounts.reduce(max) * 1.3)
            .ceilToDouble()
            .clamp(10, double.infinity)
            .toDouble();
    final spots = List.generate(
      amounts.length,
      (i) => FlSpot(i.toDouble(), amounts[i]),
    );

    return Container(
      height: 200,
      padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
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
          const Padding(
            padding: EdgeInsets.only(left: 8, bottom: 4),
            child: Text('Velocity View',
                style: TextStyle(fontSize: 11, color: Colors.grey)),
          ),
          Expanded(
            child: LineChart(
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
                      reservedSize: 36,
                      interval: maxY / 4,
                      getTitlesWidget: (v, _) => Text(
                        v.toInt().toString(),
                        style: const TextStyle(fontSize: 10, color: Colors.grey),
                      ),
                    ),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      getTitlesWidget: (v, _) {
                        final idx = v.toInt();
                        if (idx < 0 || idx >= labels.length) {
                          return const SizedBox.shrink();
                        }
                        return Text(labels[idx],
                            style: const TextStyle(
                                fontSize: 10, color: Colors.grey));
                      },
                    ),
                  ),
                  rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
                  topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false)),
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
            ),
          ),
        ],
      ),
    );
  }

  // ── Categories row (all 10, horizontally scrollable, tappable) ──────────

  Widget _buildCategoriesRow() {
    final Map<String, dynamic> budgetMap = {
      for (var b in _budgets) (b['category'] ?? ''): b
    };

    return Container(
      height: 120,
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _catMeta.length,
        separatorBuilder: (_, __) => const SizedBox(width: 14),
        itemBuilder: (ctx, i) {
          final meta = _catMeta[i];
          final name = meta['name'] as String;
          final budget = budgetMap[name];
          final spent = (budget?['spent'] ?? 0).toDouble();
          final color = meta['color'] as Color;
          final icon = meta['icon'] as IconData;

          return InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => const CategoriesScreen(showAppBar: true),
                ),
              );
            },
            child: Column(
              children: [
                Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(icon, color: Colors.white, size: 24),
                ),
                const SizedBox(height: 6),
                Text(name,
                    style: const TextStyle(
                        fontSize: 11, fontWeight: FontWeight.w600)),
                Text(
                  'Rs.${spent.toInt()}',
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ── Today's Snapshot (real backend data) ─────────────────────────────────

  Widget _buildSnapshot() {
    // Use backend todaySummaryText if available, else construct from fields
    String summaryText;
    if (_todaySummaryText.isNotEmpty) {
      summaryText = _todaySummaryText;
    } else if (_todayTotalExpense > 0 && _todayTopCategory.isNotEmpty) {
      summaryText = 'You spent Rs ${_todayTotalExpense.toInt()} on $_todayTopCategory today.';
    } else if (_todayTotalExpense > 0) {
      summaryText = 'You spent Rs ${_todayTotalExpense.toInt()} today.';
    } else {
      summaryText = 'No expenses recorded today.';
    }

    final isOnTrack = _totalExpense <= _totalIncome || _totalIncome == 0;

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          )
        ],
      ),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: const BoxDecoration(
          border: Border(left: BorderSide(color: _primary, width: 6)),
        ),
        child: Row(
          children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: _primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: const Icon(Icons.shopping_bag_outlined,
                color: _primary, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Daily Expense Summary',
                  style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                ),
                const SizedBox(height: 4),
                Text(
                  summaryText,
                  style: const TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: isOnTrack ? _primary.withValues(alpha: 0.1) : Colors.red.shade50,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              isOnTrack ? 'ON TRACK' : 'OVER',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: isOnTrack ? _primary : Colors.red,
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Show real values even while refreshing (don't flash '…')
    final showLoading = _isLoading && _report == null;

    return RefreshIndicator(
      color: _primary,
      onRefresh: _fetchAll,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Hello + month chip ────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Hello, $_greetingName!',
                        style: const TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 2),
                      const Text(
                        'Your financial health looks steady.',
                        style: TextStyle(fontSize: 13, color: Colors.grey),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: _primary),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _monthLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      color: _primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ── Income / Expense flip cards (real /monthly-report data) ───
            Row(
              children: [
                _buildFlipCard(
                  title: 'INCOME',
                  icon: Icons.north_east,
                  bgColor: const Color(0xFFF2FBF6),
                  accentColor: _primary,
                  amountText: showLoading ? '…' : 'Rs ${_totalIncome.toInt()}',
                  isFlipped: _isIncomeFlipped,
                  onTap: () =>
                      setState(() => _isIncomeFlipped = !_isIncomeFlipped),
                ),
                const SizedBox(width: 14),
                _buildFlipCard(
                  title: 'EXPENSE',
                  icon: Icons.south_east,
                  bgColor: const Color(0xFFFFF4F4),
                  accentColor: Colors.redAccent,
                  amountText:
                      showLoading ? '…' : 'Rs ${_totalExpense.toInt()}',
                  isFlipped: _isExpenseFlipped,
                  onTap: () =>
                      setState(() => _isExpenseFlipped = !_isExpenseFlipped),
                ),
              ],
            ),

            const SizedBox(height: 28),

            // ── Categories header + horizontal row ───────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Row(children: [
                  Icon(Icons.trending_up, color: _primary, size: 18),
                  SizedBox(width: 6),
                  Text('Categories',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                ]),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const CategoriesScreen(showAppBar: true),
                    ),
                  ),
                  child: const Text(
                    'See All',
                    style: TextStyle(
                        color: _primary,
                        fontWeight: FontWeight.bold,
                        fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            (showLoading)
                ? const SizedBox(
                    height: 100,
                    child:
                        Center(child: CircularProgressIndicator(color: _primary)))
                : _buildCategoriesRow(),

            const SizedBox(height: 28),

            // ── 7-day trend ───────────────────────────────────────────────
            const Text('7-Day Spending Trend',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _build7DayChart(),

            const SizedBox(height: 28),

            // ── Today's Snapshot ──────────────────────────────────────────
            const Text("Today's Snapshot",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _buildSnapshot(),
          ],
        ),
      ),
    );
  }
}
