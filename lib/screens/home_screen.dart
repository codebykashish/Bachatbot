import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../api_service.dart';
import '../widgets/report_chart.dart';
import '../widgets/balance_card.dart';
import '../widgets/app_tour_overlay.dart';
import 'categories_screen.dart';
import 'notification_screen.dart';
import 'reports_screen.dart';
import 'income_page.dart';

// State is public so MainScreen can call refresh() via GlobalKey
class HomeScreen extends StatefulWidget {
  final String firstName;
  final bool showTour;

  const HomeScreen({super.key, required this.firstName, this.showTour = false});

  @override
  HomeScreenState createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  List<dynamic> _budgets = [];
  Map<String, dynamic>? _report;
  Map<String, double> _categoryBreakdown = {};

  bool _hideAmounts = true;
  String _selectedMonth = '';

  // Declared income (from /income endpoint)
  double _declaredIncome = 0;

  static const List<Map<String, dynamic>> _catMeta = [
    {'name': 'Food', 'icon': Icons.restaurant, 'color': Color(0xFF4A90E2)},
    {'name': 'Transport', 'icon': Icons.directions_car, 'color': Color(0xFF26A69A)},
    {'name': 'Rent', 'icon': Icons.home, 'color': Color(0xFFFFB74D)},
    {'name': 'Education', 'icon': Icons.school, 'color': Color(0xFF7E57C2)},
    {'name': 'Shopping', 'icon': Icons.shopping_bag, 'color': Color(0xFFAB47BC)},
    {'name': 'Health', 'icon': Icons.favorite, 'color': Color(0xFFEF5350)},
    {'name': 'Entertainment', 'icon': Icons.tv, 'color': Color(0xFF8D6E63)},
    {'name': 'Other', 'icon': Icons.category, 'color': Color(0xFFFFCA28)},
  ];

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _selectedMonth = '${now.year}-${now.month.toString().padLeft(2, '0')}';
    _fetchAll();
  }

  void refresh() => _refreshData();

  String get _monthLabel {
    final parts = _selectedMonth.split('-');
    if (parts.length != 2) return _selectedMonth;
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final m = int.tryParse(parts[1]);
    if (m == null || m < 1 || m > 12) return _selectedMonth;
    return '${months[m - 1]} ${parts[0]}';
  }

  // ── Data fetching ────────────────────────────────────────────────────────

  Future<void> _fetchAll() async {
    setState(() => _isLoading = true);
    try {
      await Future.wait([_fetchBudgets(), _fetchReport(), _fetchTrend(), _fetchIncome()]);
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _refreshData() async {
    try {
      await Future.wait([_fetchBudgets(), _fetchReport(), _fetchTrend(), _fetchIncome()]);
    } catch (_) {}
  }

  Future<void> _fetchBudgets() async {
    try {
      final res = await ApiService.get('/budgets?monthKey=$_selectedMonth');
      if (!mounted) return;
      if (res['success'] == true) {
        final budgetsList = (res['data']?['budgets'] as List? ?? []);
        setState(() {
          _budgets = budgetsList
              .where((b) => b['category']?.toString().toLowerCase() != 'salary')
              .toList();
        });
      }
    } catch (e) {
      debugPrint('[HomeScreen] /budgets error: $e');
    }
  }

  Future<void> _fetchReport() async {
    try {
      final res = await ApiService.get('/monthly-report?monthKey=$_selectedMonth');
      if (!mounted) return;
      if (res['success'] == true) {
        setState(() {
          final data = res['data'];
          _report = data?['report'] ?? data;
          _categoryBreakdown = _mapToDouble(_report?['categoryBreakdown'] ?? {});
        });
      }
    } catch (e) {
      debugPrint('[HomeScreen] /monthly-report error: $e');
    }
  }

  Future<void> _fetchTrend() async {
    try {
      await ApiService.get('/daily-summary');
    } catch (_) {}
  }

  Future<void> _fetchIncome() async {
    try {
      final res = await ApiService.get('/income');
      if (!mounted) return;
      if (res['success'] == true) {
        final d = res['data'];
        setState(() {
          _declaredIncome = (d['total'] ?? 0).toDouble();
        });
      }
    } catch (e) {
      debugPrint('[HomeScreen] /income error: $e');
    }
  }

  Map<String, double> _mapToDouble(dynamic map) {
    if (map is! Map) return {};
    return map.map<String, double>((k, v) => MapEntry(k.toString(), (v ?? 0).toDouble()));
  }

  // ── Derived values ───────────────────────────────────────────────────────

  double get _totalExpense =>
      (_report?['totalExpense'] ?? _report?['expense'] ?? 0).toDouble();

  // For the income card: use declared income if set, else fall back to transaction income
  double get _incomeForCard {
    if (_declaredIncome > 0) return _declaredIncome;
    return (_report?['incomeCardValue'] ?? _report?['totalIncome'] ?? _report?['income'] ?? 0).toDouble();
  }

  // Savings = income - total expense
  double get _savings => _incomeForCard - _totalExpense;

  double get _todayTotalExpense => (_report?['todayTotalExpense'] ?? 0).toDouble();
  String get _todayTopCategory => (_report?['todayTopCategory'] ?? '').toString();
  String get _todaySummaryText => (_report?['todaySummaryText'] ?? '').toString();

  String get _greetingName {
    if (widget.firstName.trim().isNotEmpty && widget.firstName.trim() != 'User') {
      return widget.firstName.trim();
    }
    final user = FirebaseAuth.instance.currentUser;
    if (user != null && user.displayName != null && user.displayName!.trim().isNotEmpty) {
      return user.displayName!.trim();
    }
    return 'User';
  }

  // ── Summary Cards ─────────────────────────────────────────────────────────

  Widget _buildSummaryCards() {
    return BalanceCard(
      savings: _savings,
      spendingThisMonth: _totalExpense,
      incomeThisMonth: _incomeForCard,
      hideAmounts: _hideAmounts,
      onExpenseTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const NotificationScreen(initialType: 'expense')),
      ),
      onIncomeTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const IncomePage()),
      ),
    );
  }

  // ── Categories row ────────────────────────────────────────────────────────

  Widget _buildCategoriesRow() {
    final Map<String, dynamic> budgetMap = {
      for (var b in _budgets) (b['category'] ?? ''): b
    };

    return Container(
      height: 148,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: _catMeta.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (ctx, i) {
          final meta = _catMeta[i];
          final name = meta['name'] as String;
          final budget = budgetMap[name];
          final spent = (budget?['spent'] ?? 0).toDouble();
          final color = meta['color'] as Color;
          final icon = meta['icon'] as IconData;

          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: InkWell(
              borderRadius: BorderRadius.circular(16),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const CategoriesScreen(showAppBar: true)),
                );
              },
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Container(
                    width: 60,
                    height: 60,
                    decoration: BoxDecoration(
                      color: color,
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(icon, color: Colors.white, size: 28),
                  ),
                  const SizedBox(height: 6),
                  SizedBox(
                    width: 60,
                    child: Text(
                      name,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 2),
                  SizedBox(
                    width: 60,
                    child: Text(
                      'Rs ${spent.toInt()}',
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 9, color: Colors.grey),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Today's Snapshot ──────────────────────────────────────────────────────

  Widget _buildSnapshot() {
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

    final isOnTrack = _totalExpense <= _incomeForCard || _incomeForCard == 0;

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
          ),
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
              width: 44, height: 44,
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: const Icon(Icons.shopping_bag_outlined, color: _primary, size: 22),
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

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final showLoading = _isLoading && _report == null;

    final content = RefreshIndicator(
      color: _primary,
      onRefresh: _fetchAll,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Hello + month chip ───────────────────────────────────────
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
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    border: Border.all(color: _primary),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    _monthLabel,
                    style: const TextStyle(fontSize: 12, color: _primary, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),

            const SizedBox(height: 20),

            // ── Financial Summary + eye toggle ───────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Financial Summary',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
                IconButton(
                  icon: Icon(
                    _hideAmounts ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    color: Colors.grey[700],
                    size: 22,
                  ),
                  onPressed: () => setState(() => _hideAmounts = !_hideAmounts),
                ),
              ],
            ),
            const SizedBox(height: 12),
            showLoading
                ? const SizedBox(height: 200, child: Center(child: CircularProgressIndicator(color: _primary)))
                : _buildSummaryCards(),

            const SizedBox(height: 28),

            // ── Categories ───────────────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'Categories',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CategoriesScreen(showAppBar: true)),
                  ),
                  child: const Text('See All', style: TextStyle(color: _primary, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            showLoading
                ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator(color: _primary)))
                : _buildCategoriesRow(),

            const SizedBox(height: 28),

            // ── Monthly Report Chart ─────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text('Monthly Report', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ReportsScreen()),
                  ),
                  child: const Text('View Full', style: TextStyle(color: _primary, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            showLoading
                ? const SizedBox(height: 200, child: Center(child: CircularProgressIndicator(color: _primary)))
                : GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const ReportsScreen()),
                    ),
                    child: ReportChart(
                      categoryBreakdown: _categoryBreakdown,
                      isCompact: false,
                      useLineChart: false,
                    ),
                  ),

            const SizedBox(height: 28),

            // ── Today's Snapshot ─────────────────────────────────────────
            const Text("Today's Snapshot", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            _buildSnapshot(),
          ],
        ),
      ),
    );

    // Wrap with the first-time tour overlay
    return AppTourOverlay(
      showTour: widget.showTour,
      child: content,
    );
  }
}
