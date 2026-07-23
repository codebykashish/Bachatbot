import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../api_service.dart';
import '../widgets/month_strip.dart';
import '../widgets/report_explorer_sheet.dart';
import '../models/goal.dart';
import '../theme/health_theme.dart';
import 'goals_screen.dart';

class ReportsScreen extends StatefulWidget {
  // Same pattern as CategoriesScreen -- false when embedded as a
  // MainScreen tab (which already has its own AppBar showing
  // "Reports"), true when pushed standalone from Home. Previously
  // always true regardless of context, which is exactly why the
  // "Reports" header showed twice.
  final bool showAppBar;

  const ReportsScreen({super.key, this.showAppBar = false});

  @override
  State<ReportsScreen> createState() => ReportsScreenState();
}

/// The main Reports page stays a simple, always-"this month, right now"
/// glance: a compact month graph, overall status, goals, projected
/// savings. Tapping the graph opens ReportExplorerSheet -- a
/// self-contained popup that owns all the actual exploration (Today/
/// Week/Month tabs, category filter, year/month navigation, the chart,
/// and the full category breakdown). Keeping that entirely separate
/// means this page never needs to re-fetch or re-render just because
/// someone browsed a different month inside the popup.
class ReportsScreenState extends State<ReportsScreen>
    with WidgetsBindingObserver {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  late DateTime _currentMonth;
  late String _selectedMonthKey;
  late int _selectedYear;

  double _totalExpense = 0;
  String? _overallHealthStatus;
  List<Goal> _goals = [];
  Map<String, dynamic>? _projectedSavings;
  Map<String, double> _yearMonthTotals = {};

  int _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final now = DateTime.now();
    _currentMonth = DateTime(now.year, now.month, 1);
    _selectedMonthKey = _formatMonthKey(_currentMonth);
    _selectedYear = now.year;
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

  String _formatMonthKey(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}';

  Future<void> _loadReport() async {
    final myGen = ++_loadGeneration;
    try {
      final futures = await Future.wait([
        ApiService.get('/monthly-report?monthKey=$_selectedMonthKey&view=month'),
        ApiService.get('/goals'),
        ApiService.get('/financial-metrics?monthKey=$_selectedMonthKey'),
        ApiService.get('/financial-health?monthKey=$_selectedMonthKey'),
        ApiService.get('/monthly-report/year-summary?year=$_selectedYear'),
      ]);
      final res = futures[0];
      final goalsRes = futures[1];
      final metricsRes = futures[2];
      final healthRes = futures[3];
      final yearRes = futures[4];

      if (!mounted || myGen != _loadGeneration) return;

      if (res['success'] == true) {
        final data = res['data'];
        final report = data?['report'] ?? data;

        List<Goal> goals = [];
        if (goalsRes['success'] == true) {
          goals = (goalsRes['data']?['goals'] as List? ?? [])
              .map((g) => Goal.fromJson(g as Map<String, dynamic>))
              .toList();
        }

        // Projected Savings (Phase 2.7) — read directly from the
        // Metrics Engine, never recomputed here. Null when no budgets
        // exist to project from.
        final projectedSavings = metricsRes['success'] == true
            ? (metricsRes['data']?['projectedSavings'] as Map<String, dynamic>?)
            : null;

        // Health Engine (Phase 3.1) — the real overall status, read
        // directly, never recomputed.
        final overallHealthStatus = healthRes['success'] == true
            ? (healthRes['data']?['overallHealth']?['status'] as String?)
            : null;

        final yearMonthTotals = yearRes['success'] == true
            ? _mapToDouble(yearRes['data']?['months'] ?? {})
            : <String, double>{};

        setState(() {
          _totalExpense = (report?['totalExpense'] ?? 0).toDouble();
          _overallHealthStatus = overallHealthStatus;
          _goals = goals;
          _projectedSavings = projectedSavings;
          _yearMonthTotals = yearMonthTotals;
          _isLoading = false;
        });
      } else if (myGen == _loadGeneration) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[ReportsScreen] Error loading report: $e');
      if (mounted && myGen == _loadGeneration) setState(() => _isLoading = false);
    }
  }

  Map<String, double> _mapToDouble(dynamic map) {
    if (map is! Map) return {};
    return map.map<String, double>((k, v) => MapEntry(k.toString(), (v ?? 0).toDouble()));
  }

  void _openExplorer() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => FractionallySizedBox(
        heightFactor: 0.92,
        child: ReportExplorerSheet(initialYear: _selectedYear, initialMonth: _currentMonth),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: widget.showAppBar
          ? AppBar(
              title: const Text('Reports', style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: Colors.white,
              foregroundColor: Colors.black87,
              elevation: 0.5,
            )
          : null,
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
                    // ── Headline: this month's total, always ────────────────
                    Text(
                      'Monthly Spending',
                      style: TextStyle(fontSize: 13, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Rs ${NumberFormat('#,##0.00').format(_totalExpense)}',
                      style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    Text(
                      'Spending this month',
                      style: TextStyle(fontSize: 12.5, color: Colors.grey.shade500),
                    ),

                    const SizedBox(height: 16),

                    // ── Tap to explore: opens ReportExplorerSheet with the
                    // full Today/Week/Month/category-filter/year-nav
                    // experience. The month pills here are non-interactive
                    // on purpose (onSelect is a no-op) -- any tap, pill or
                    // not, opens the popup instead of switching months here.
                    GestureDetector(
                      onTap: _openExplorer,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 3))],
                        ),
                        child: Column(
                          children: [
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 8),
                              child: MonthStrip(
                                year: _selectedYear,
                                selectedMonth: _currentMonth.month,
                                monthTotals: _yearMonthTotals,
                                onSelect: (_) {},
                              ),
                            ),
                            Divider(height: 1, indent: 16, endIndent: 16, color: Colors.grey.shade200),
                            Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                              child: Row(
                                children: [
                                  const Icon(Icons.bar_chart_rounded, size: 16, color: _primary),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      'Tap to explore by day, week, or category',
                                      style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                                    ),
                                  ),
                                  Icon(Icons.chevron_right, color: Colors.grey.shade400, size: 18),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                    const SizedBox(height: 20),

                    // ── Overall Status ────────────────────────────────────
                    _buildOverallStatusCard(),

                    // ── Savings Goals summary ─────────────────────────────
                    if (_goals.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _buildGoalsSummary(),
                    ],

                    // Recommendation, Recovery Plan, and Risk Flags moved
                    // to HealthScreen (Phase 13.4) — see that screen for
                    // "what should I do" / "am I okay."

                    // Projected Savings (Phase 2.7, Predictive) — one simple
                    // card, not flashy. The ≈ symbol is the visual cue that
                    // this is a forecast, never a fact.
                    if (_projectedSavings != null) ...[
                      const SizedBox(height: 16),
                      _buildProjectedSavingsCard(),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  // Phase 13.8 -- driven by the real Health Engine status
  // (_overallHealthStatus, from /financial-health) instead of the old
  // local "low/ok/high/overspent" proxy derived from /monthly-report's
  // insights.overallStatus. Same reconciliation already applied to the
  // ambient overlay and Categories cards.
  Widget _buildOverallStatusCard() {
    final theme = HealthTheme.forStatus(_overallHealthStatus);
    String statusText;
    IconData statusIcon;

    switch (_overallHealthStatus) {
      case 'amber':
        statusText = 'Stable but needs attention';
        statusIcon = Icons.warning_amber;
        break;
      case 'red':
        statusText = 'Needs attention now';
        statusIcon = Icons.warning_amber;
        break;
      default:
        statusText = 'Looking good';
        statusIcon = Icons.check_circle;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: theme.cardTint,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: theme.statusColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(statusText, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.statusColor)),
          ),
        ],
      ),
    );
  }

  // Projected Savings (Phase 2.7) — a forecast, never a fact, still
  // named honestly with "≈". Made bigger and bolder per feedback that
  // the old plain card was easy to miss; sign-aware color (a negative
  // projection is a warning, not more good news in green) using the
  // same HealthTheme lookup the rest of the app already uses.
  Widget _buildProjectedSavingsCard() {
    final projection = _projectedSavings!;
    final value = (projection['value'] as num?)?.round() ?? 0;
    final theme = value < 0 ? HealthTheme.forStatus('red') : HealthTheme.forStatus('green');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(color: theme.accent.withValues(alpha: 0.15), shape: BoxShape.circle),
            child: Icon(Icons.savings_outlined, color: theme.accent, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Projected savings',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600, fontWeight: FontWeight.w600),
                ),
                Text(
                  '≈ Rs $value',
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: theme.statusColor),
                ),
              ],
            ),
          ),
        ],
      ),
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
              Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(color: _primary.withValues(alpha: 0.12), shape: BoxShape.circle),
                    child: const Icon(Icons.flag_outlined, color: _primary, size: 16),
                  ),
                  const SizedBox(width: 8),
                  const Text('Goals', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
                ],
              ),
              TextButton(
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const GoalsScreen())),
                style: TextButton.styleFrom(padding: EdgeInsets.zero, minimumSize: const Size(0, 0)),
                child: const Text('View all', style: TextStyle(color: _primary, fontSize: 12, fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ...(_goals.take(3).map((g) {
            final progress = (g.percentComplete / 100).clamp(0.0, 1.0);
            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
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
                        '${(progress * 100).toInt()}%',
                        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: _primary),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(value: progress, minHeight: 7, backgroundColor: Colors.grey.shade200, color: _primary),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    'Rs ${g.savedSoFar.toInt()} of Rs ${g.targetAmount.toInt()}',
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                  ),
                ],
              ),
            );
          })),
        ],
      ),
    );
  }
}
