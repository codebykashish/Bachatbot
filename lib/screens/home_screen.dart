import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../api_service.dart';
import '../widgets/adaptive_report_chart.dart';
import '../widgets/balance_card.dart';
import '../services/health_theme_service.dart';
import '../theme/health_theme.dart';
import '../services/behavior_preview_service.dart';
import '../widgets/slide_up_route.dart';
import 'categories_screen.dart';
import 'activity_feed_screen.dart';
import 'reports_screen.dart';
import 'income_page.dart';
import 'health_screen.dart';

// State is public so MainScreen can call refresh() via GlobalKey
class HomeScreen extends StatefulWidget {
  final String firstName;
  final bool showTour;
  final VoidCallback? onSeeAllCategories;
  final VoidCallback? onViewFullReports;
  final VoidCallback? onAddCategory;
  final VoidCallback? onEyeTapped;

  const HomeScreen({
    super.key,
    required this.firstName,
    this.showTour = false,
    this.onSeeAllCategories,
    this.onViewFullReports,
    this.onAddCategory,
    this.onEyeTapped,
  });

  @override
  HomeScreenState createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  // Persists for the lifetime of the app process — HomeScreen is kept
  // alive in an IndexedStack, so initState only fires once per real app
  // launch. Ensures the "Yesterday" insight card shows once per fresh open.
  static bool _yesterdayInsightShown = false;

  // GlobalKey so MainScreen can locate the eye icon for the spotlight tour
  final GlobalKey eyeIconKey = GlobalKey();

  bool _isLoading = true;
  Map<String, dynamic>? _summary; // financialSummary — the only source of calculated values
  Map<String, dynamic>? _metrics; // financialMetrics — the Metrics Engine's read-only interpretations (Phase 2)
  Map<String, dynamic>? _overallHealth; // Health Engine's judgment (Phase 3.1) — status/confidence/reasons, never computed here
  Map<String, String> _categoryHealth = {}; // category -> green/amber/red, for the Today chart
  Map<String, dynamic>? _report;
  Map<String, double> _categoryBreakdown = {};

  bool _hideAmounts = true;
  String _selectedMonth = '';

  String _latestActivityText = '';

  // Latest first name fetched from profile — overrides widget.firstName when set
  String? _profileFirstName;

  // Guards against an out-of-order response overwriting fresher data.
  // _fetchAll()/_refreshData()/refresh() can overlap (e.g. a transaction's
  // own refresh trigger racing a rebalance-confirm's refresh trigger
  // moments later) -- without this, whichever response's setState runs
  // last wins, even if it's the older one. Incremented once per fetch
  // batch; each sub-fetch below captures it at its own start and only
  // applies its result if no newer batch has started since. Found via
  // real usage: a category's numbers got stuck mid-rebalance on Home,
  // same root cause already found and fixed on the Categories screen.
  int _fetchGeneration = 0;

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
    _fetchGeneration++;
    setState(() => _isLoading = true);
    try {
      await Future.wait([_fetchFinancialSummary(), _fetchFinancialMetrics(), _fetchOverallHealth(), _fetchReport(), _fetchTrend(), _fetchLatestActivity(), _fetchProfileName(), _fetchBehaviorPreview()]);
      _maybeShowYesterdayInsight();
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  static const _lastInsightShownKey = 'yesterday_insight_last_shown_date';

  Future<void> _maybeShowYesterdayInsight() async {
    if (_yesterdayInsightShown || !mounted || _report == null) return;

    // Persisted across app restarts — only the FIRST open of a given day
    // shows the card, not every time the app is reopened that same day.
    final today = DateTime.now();
    final todayKey = '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}';

    final prefs = await SharedPreferences.getInstance();
    final lastShown = prefs.getString(_lastInsightShownKey);
    if (lastShown == todayKey) return;

    _yesterdayInsightShown = true;

    final yesterdayExpense = (_report?['yesterdayTotalExpense'] ?? 0).toDouble();
    final yesterdayIncome = (_report?['yesterdayTotalIncome'] ?? 0).toDouble();
    final summaryText = (_report?['yesterdaySummaryText'] ?? '').toString();
    final paceWarning = _report?['paceWarningText'] as String?;

    // Nothing worth interrupting the user for.
    if (summaryText.isEmpty && paceWarning == null) return;

    await prefs.setString(_lastInsightShownKey, todayKey);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      showModalBottomSheet(
        context: context,
        backgroundColor: Colors.transparent,
        isScrollControlled: true,
        builder: (ctx) => _YesterdayInsightCard(
          summaryText: summaryText,
          yesterdayExpense: yesterdayExpense,
          yesterdayIncome: yesterdayIncome,
          paceWarning: paceWarning,
        ),
      );
    });
  }

  Future<void> _refreshData() async {
    _fetchGeneration++;
    try {
      await Future.wait([_fetchFinancialSummary(), _fetchFinancialMetrics(), _fetchOverallHealth(), _fetchReport(), _fetchTrend(), _fetchLatestActivity(), _fetchProfileName(), _fetchBehaviorPreview()]);
    } catch (_) {}
  }

  Future<void> _fetchProfileName() async {
    final myGen = _fetchGeneration;
    try {
      final res = await ApiService.get('/profile');
      if (!mounted || myGen != _fetchGeneration) return;
      final name = res['data']?['firstName'] as String?;
      if (name != null && name.trim().isNotEmpty) {
        setState(() => _profileFirstName = name.trim());
      }
    } catch (_) {}
  }

  // The only place Home reads calculated financial values from — no local
  // formulas (remaining/savings/over-budget math) live in this screen
  // anymore, they all come from financial_engine.py via this one endpoint.
  Future<void> _fetchFinancialSummary() async {
    final myGen = _fetchGeneration;
    try {
      final res = await ApiService.get('/financial-summary?monthKey=$_selectedMonth');
      if (!mounted || myGen != _fetchGeneration) return;
      if (res['success'] == true) {
        setState(() {
          _summary = res['data'] as Map<String, dynamic>?;
        });
      }
    } catch (e) {
      debugPrint('[HomeScreen] /financial-summary error: $e');
    }
  }

  // Metrics Engine (Phase 2.1) — read-only interpretations of financialSummary.
  // Never a formula computed here; daysRemaining comes straight from the endpoint.
  Future<void> _fetchFinancialMetrics() async {
    final myGen = _fetchGeneration;
    try {
      final res = await ApiService.get('/financial-metrics?monthKey=$_selectedMonth');
      if (!mounted || myGen != _fetchGeneration) return;
      if (res['success'] == true) {
        setState(() {
          _metrics = res['data'] as Map<String, dynamic>?;
        });
      }
    } catch (e) {
      debugPrint('[HomeScreen] /financial-metrics error: $e');
    }
  }

  // Health Engine (Phase 3.1) — judgment layer, read-only. Only
  // `overallHealth.status` is surfaced in the UI; reasons/trace stay
  // backend-only until Chat (Phase 6) has an Explainer to word them.
  Future<void> _fetchOverallHealth() async {
    final myGen = _fetchGeneration;
    try {
      final res = await ApiService.get('/financial-health?monthKey=$_selectedMonth');
      if (!mounted || myGen != _fetchGeneration) return;
      if (res['success'] == true) {
        final overallHealth = res['data']?['overallHealth'] as Map<String, dynamic>?;
        // Category Health (Phase 13.12) -- same map Reports already
        // uses to color its Today chart. Fetched here too so Home's
        // own Today chart can use the identical AdaptiveReportChart
        // widget Reports does, instead of the separate, plain-green
        // ReportChart widget it used before -- two different widgets
        // rendering "today's categories" had quietly drifted apart
        // (no health coloring, different sort order, different style).
        final rawCategoryHealth = res['data']?['categoryHealth'] as Map?;
        final categoryHealth = rawCategoryHealth == null
            ? <String, String>{}
            : rawCategoryHealth.map(
                (k, v) => MapEntry(k.toString(), (v as Map)['status'] as String? ?? 'green'),
              );
        setState(() {
          _overallHealth = overallHealth;
          _categoryHealth = categoryHealth;
        });
        // Phase 13.5 — the one real signal the app-wide Health Theme
        // hangs off. Pushed here rather than fetched again by a separate
        // service, since this call already has it.
        HealthThemeService.updateFromStatus(overallHealth?['status'] as String?);
      }
    } catch (e) {
      debugPrint('[HomeScreen] /financial-health error: $e');
    }
  }

  // The streak badge itself now lives in MainScreen's AppBar (Phase
  // 13.3 — "I want it above," per real feedback), backed by
  // BehaviorPreviewService rather than local state here. Still
  // refreshed on every Home fetch so logging a transaction updates the
  // badge promptly rather than waiting for its own next refresh.
  Future<void> _fetchBehaviorPreview() => BehaviorPreviewService.refresh();

  Future<void> _fetchReport() async {
    final myGen = _fetchGeneration;
    try {
      // Home screen shows today's view -- the most immediately relevant
      // slice, per real feedback. Budgets (Unused Budget / Savings card)
      // are unaffected; they come from /budgets separately and stay
      // monthly, as budgets are inherently a monthly allocation.
      final res = await ApiService.get('/monthly-report?monthKey=$_selectedMonth&view=today');
      if (!mounted || myGen != _fetchGeneration) return;
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

  Future<void> _fetchLatestActivity() async {
    final myGen = _fetchGeneration;
    try {
      final res = await ApiService.get('/alerts?limit=1');
      if (!mounted || myGen != _fetchGeneration) return;
      if (res['success'] == true) {
        final alerts = res['data']?['alerts'] as List? ?? [];
        if (alerts.isNotEmpty) {
          setState(() {
            _latestActivityText = alerts[0]['message']?.toString() ?? '';
          });
        }
      }
    } catch (_) {}
  }

  Map<String, double> _mapToDouble(dynamic map) {
    if (map is! Map) return {};
    return map.map<String, double>((k, v) => MapEntry(k.toString(), (v ?? 0).toDouble()));
  }

  // ── Derived values ───────────────────────────────────────────────────────

  double get _totalExpense =>
      (_report?['totalExpense'] ?? _report?['expense'] ?? 0).toDouble();

  Map<String, dynamic> get _categoryRemaining =>
      (_summary?['categoryRemaining'] as Map?)?.cast<String, dynamic>() ?? {};

  // For the income card: use the Engine's declared income if set, else fall
  // back to transaction income from the weekly report.
  double get _incomeForCard {
    final declared = (_summary?['income'] ?? 0).toDouble();
    if (declared > 0) return declared;
    return (_report?['incomeCardValue'] ?? _report?['totalIncome'] ?? _report?['income'] ?? 0).toDouble();
  }

  // Category limits aren't a formula — they're raw per-category values the
  // Engine already reports; this just totals them for the health-status
  // threshold below (Phase 3 will replace this once the Engine exposes a
  // health flag directly).
  double get _totalBudgetLimit => _categoryRemaining.values
      .fold(0.0, (s, c) => s + ((c as Map)['limit'] ?? 0).toDouble());

  // Unused Budget — read directly from the Engine, never recomputed here.
  double get _unusedBudget => (_summary?['remainingBudget'] ?? 0).toDouble();

  // Savings Pool — read directly from the Engine, never recomputed here.
  double get _pureSavings => (_summary?['savingsPool'] ?? 0).toDouble();

  // Days Remaining — read directly from the Metrics Engine (Phase 2.1),
  // never recomputed here.
  int get _daysRemaining => (_metrics?['daysRemaining'] ?? 0) as int;

  // Recommended Daily Spend — Advisory metric (Phase 2.3), read directly
  // from the Metrics Engine. Null when no budgets exist yet — that case
  // is not faked as 0, so the UI must hide the line rather than show
  // "Rs 0" (see spec: Phase 2.3 Design, the null-vs-fabricated-number rule).
  double? get _recommendedDailySpend {
    final rds = _metrics?['recommendedDailySpend'];
    if (rds == null) return null;
    return (rds['value'] as num?)?.toDouble();
  }

  // Spending Pace — Analytical metric (Phase 2.4), read directly from the
  // Metrics Engine. Only the status label is surfaced in the UI, never the
  // raw difference — this metric describes, it doesn't recommend.
  String? get _spendingPaceStatus =>
      (_metrics?['spendingPace']?['status'] as String?);

  // Overall Health — Health Engine judgment (Phase 3.1), read directly.
  // Only the status is surfaced; reasons/decisionTrace stay backend-only
  // until Phase 6's Explainer exists to word them for the user.
  String? get _overallHealthStatus => (_overallHealth?['status'] as String?);

  // Previously a hardcoded "Your financial health looks steady." string
  // that never actually reflected the real Health Engine status --
  // found from real feedback ("dashboard badge is red but the greeting
  // still says steady"). Now driven by the same _overallHealthStatus
  // the badge below already uses.
  String get _greetingSubtitle {
    switch (_overallHealthStatus) {
      case 'red':
        return 'Your financial health needs attention.';
      case 'amber':
        return 'Your financial health needs a little care.';
      case 'green':
        return 'Your financial health looks good.';
      default:
        return "Let's take a look at your finances.";
    }
  }

  // Was `_totalBudgetSpent > _totalBudgetLimit`, which stayed false at
  // exactly 100% used (spent == limit) -- a fully exhausted budget
  // showed as "Unused Budget" in green. Rethreshold to `<= 0` on
  // Engine-sourced `_unusedBudget` (never a local subtraction) -- the
  // same "remaining <= 0" convention compute_recovery_plan() already
  // uses to decide a category is exhausted, so this card now agrees
  // with the real backend threshold instead of inventing its own.
  bool get _isOverAllocatedBudget => _totalBudgetLimit > 0 && _unusedBudget <= 0;

  double get _todayTotalExpense => (_report?['todayTotalExpense'] ?? 0).toDouble();
  String get _todayTopCategory => (_report?['todayTopCategory'] ?? '').toString();
  String get _todaySummaryText => (_report?['todaySummaryText'] ?? '').toString();

  String get _greetingName {
    // Fresh API name takes priority so profile edits reflect immediately
    if (_profileFirstName != null && _profileFirstName!.trim().isNotEmpty) {
      return _profileFirstName!.trim();
    }
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
      unusedBudget: _unusedBudget,
      pureSavings: _pureSavings,
      isOverBudget: _isOverAllocatedBudget,
      spendingThisMonth: _totalExpense,
      incomeThisMonth: _incomeForCard,
      daysRemaining: _daysRemaining,
      recommendedDailySpend: _recommendedDailySpend,
      spendingPaceStatus: _spendingPaceStatus,
      hideAmounts: _hideAmounts,
      onExpenseTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ActivityFeedScreen(initialFilter: 'transactions')),
      ),
      // Phase 13.13 -- previously had no refresh callback at all, unlike
      // every other sub-screen push on this file (onExpenseTap included).
      // Editing income on IncomePage refreshed IncomePage's own state
      // fine, but returning to Home left the balance card, health
      // badge, and chart all showing stale numbers until the next
      // pull-to-refresh or app reopen.
      onIncomeTap: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const IncomePage()),
      ).then((_) => _fetchAll()),
    );
  }

  // Overall Health (Phase 3.1) — one simple badge, no gauge, no score.
  // Status only; reasons stay backend-only until Phase 6's Explainer
  // exists to word them for the user.
  Widget _buildHealthBadge() {
    final status = _overallHealthStatus;
    if (status == null) return const SizedBox.shrink();

    String emoji;
    String label;
    switch (status) {
      case 'green':
        emoji = '🟢';
        label = 'Looking good';
        break;
      case 'red':
        emoji = '🔴';
        label = 'Needs attention now';
        break;
      default:
        emoji = '🟡';
        label = 'Stable but needs attention';
    }

    final theme = HealthTheme.forStatus(status);

    return GestureDetector(
      onTap: () => Navigator.push(context, slideUpRoute(const HealthScreen())),
      child: Container(
        margin: const EdgeInsets.only(top: 12),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: theme.cardTint,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: theme.accent.withValues(alpha: 0.25)),
        ),
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 16)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Overall Financial Health',
                    style: TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500),
                  ),
                  Text(
                    label,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: theme.statusColor),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.grey.shade400, size: 18),
          ],
        ),
      ),
    );
  }

  // ── Categories row ────────────────────────────────────────────────────────

  Widget _buildCategoriesRow() {
    final budgetMap = _categoryRemaining;
    final filtered = _catMeta.where((m) => budgetMap.containsKey(m['name'])).toList();

    if (filtered.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
        decoration: BoxDecoration(
          color: const Color(0xFFF6F7F9),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Center(
          child: Text(
            'No categories set yet. Go to Categories to add some.',
            style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }

    return Container(
      height: 148,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF6F7F9),
        borderRadius: BorderRadius.circular(16),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: filtered.length + 1,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (ctx, i) {
          // Last item: "+" add category button
          if (i == filtered.length) {
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              child: InkWell(
                borderRadius: BorderRadius.circular(16),
                onTap: () {
                  if (widget.onAddCategory != null) {
                    widget.onAddCategory!();
                  } else if (widget.onSeeAllCategories != null) {
                    widget.onSeeAllCategories!();
                  } else {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const CategoriesScreen(showAppBar: true)),
                    );
                  }
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade100,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: Colors.grey.shade300, width: 1.5),
                      ),
                      child: Icon(Icons.add_rounded, color: Colors.grey.shade500, size: 28),
                    ),
                    const SizedBox(height: 6),
                    SizedBox(
                      width: 60,
                      child: Text(
                        'Add',
                        textAlign: TextAlign.center,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey.shade600),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: 2),
                    const SizedBox(height: 14),
                  ],
                ),
              ),
            );
          }

          final meta = filtered[i];
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
                if (widget.onSeeAllCategories != null) {
                  widget.onSeeAllCategories!();
                } else {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const CategoriesScreen(showAppBar: true)),
                  );
                }
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
    if (_latestActivityText.isNotEmpty) {
      summaryText = _latestActivityText;
    } else if (_todaySummaryText.isNotEmpty) {
      summaryText = _todaySummaryText;
    } else if (_todayTotalExpense > 0 && _todayTopCategory.isNotEmpty) {
      summaryText = 'You spent Rs ${_todayTotalExpense.toInt()} on $_todayTopCategory today.';
    } else if (_todayTotalExpense > 0) {
      summaryText = 'You spent Rs ${_todayTotalExpense.toInt()} today.';
    } else {
      summaryText = 'No activity recorded today.';
    }

    // Reads the same real backend signal as the Health badge (Health
    // Engine's overallHealth.status) instead of a local income-vs-spend
    // guess -- that local guess previously said "ON TRACK" whenever
    // totalExpense <= income, even with every category budget fully
    // exhausted, since unallocated income (savingsPool) was never part
    // of that comparison. Same "duplicate signal" bug already fixed 4
    // times elsewhere (ambient overlay, Categories, Reports, Health
    // screen) -- this was the 5th instance.
    final badgeTheme = HealthTheme.forStatus(_overallHealthStatus);
    final badgeLabel = switch (_overallHealthStatus) {
      'red' => 'OVER',
      'amber' => 'WATCH',
      _ => 'ON TRACK',
    };

    return GestureDetector(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => const ActivityFeedScreen(initialDateFilter: 'today'),
        ),
      ),
      child: Container(
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
                      'Latest Activity',
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
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: badgeTheme.cardTint,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      badgeLabel,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: badgeTheme.statusColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.chevron_right, size: 16, color: Colors.grey.shade400),
                ],
              ),
            ],
          ),
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
                      Text(
                        _greetingSubtitle,
                        style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
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
                  "This Week's Summary",
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                ),
                IconButton(
                  key: eyeIconKey,
                  icon: Icon(
                    _hideAmounts ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                    color: Colors.grey[700],
                    size: 22,
                  ),
                  onPressed: () {
                    setState(() => _hideAmounts = !_hideAmounts);
                    widget.onEyeTapped?.call();
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            showLoading
                ? const SizedBox(height: 200, child: Center(child: CircularProgressIndicator(color: _primary)))
                : Column(
                    children: [
                      _buildSummaryCards(),
                      _buildHealthBadge(),
                    ],
                  ),

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
                  onPressed: () {
                    if (widget.onSeeAllCategories != null) {
                      widget.onSeeAllCategories!();
                    } else {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const CategoriesScreen(showAppBar: true)),
                      );
                    }
                  },
                  child: const Text('See All', style: TextStyle(color: _primary, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 8),
            showLoading
                ? const SizedBox(height: 100, child: Center(child: CircularProgressIndicator(color: _primary)))
                : _buildCategoriesRow(),

            const SizedBox(height: 28),

            // ── Today's Spending Chart ────────────────────────────────────
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text("Today's Spending", style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                TextButton(
                  onPressed: () {
                    if (widget.onViewFullReports != null) {
                      widget.onViewFullReports!();
                    } else {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const ReportsScreen(showAppBar: true)),
                      );
                    }
                  },
                  child: const Text('View Full', style: TextStyle(color: _primary, fontWeight: FontWeight.bold, fontSize: 13)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            showLoading
                ? const SizedBox(height: 200, child: Center(child: CircularProgressIndicator(color: _primary)))
                : GestureDetector(
                    onTap: () {
                        if (widget.onViewFullReports != null) {
                          widget.onViewFullReports!();
                        } else {
                          Navigator.push(
                            context,
                            MaterialPageRoute(builder: (_) => const ReportsScreen(showAppBar: true)),
                          );
                        }
                      },
                    child: AdaptiveReportChart(
                      mode: 'today',
                      categoryBreakdown: _categoryBreakdown,
                      categoryHealth: _categoryHealth,
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

    return content;
  }
}

// ── Yesterday Insight Card ───────────────────────────────────────────────────
// Shown once per fresh app open — quick-scan summary of yesterday's activity,
// plus a scary pace warning if spending is outrunning the days left.
class _YesterdayInsightCard extends StatelessWidget {
  final String summaryText;
  final double yesterdayExpense;
  final double yesterdayIncome;
  final String? paceWarning;

  const _YesterdayInsightCard({
    required this.summaryText,
    required this.yesterdayExpense,
    required this.yesterdayIncome,
    required this.paceWarning,
  });

  @override
  Widget build(BuildContext context) {
    final netSaved = yesterdayIncome - yesterdayExpense;

    return SafeArea(
      child: Container(
        margin: const EdgeInsets.all(16),
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            BoxShadow(color: Colors.black.withValues(alpha: 0.15), blurRadius: 20, offset: const Offset(0, 6)),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF2DBE7F).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(Icons.wb_twilight_rounded, color: Color(0xFF2DBE7F), size: 20),
                ),
                const SizedBox(width: 10),
                const Text('Yesterday', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const Spacer(),
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: const Icon(Icons.close, size: 20, color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              summaryText.isNotEmpty ? summaryText : 'No activity yesterday.',
              style: const TextStyle(fontSize: 14, height: 1.4, color: Colors.black87),
            ),
            if (netSaved > 0) ...[
              const SizedBox(height: 6),
              Text(
                'You saved Rs ${netSaved.toInt()} yesterday.',
                style: const TextStyle(fontSize: 13, color: Color(0xFF2DBE7F), fontWeight: FontWeight.w600),
              ),
            ],
            if (paceWarning != null) ...[
              const SizedBox(height: 16),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFE0223B).withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFE0223B).withValues(alpha: 0.3)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.warning_amber_rounded, color: Color(0xFFE0223B), size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        paceWarning!,
                        style: const TextStyle(
                          fontSize: 13,
                          color: Color(0xFFE0223B),
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(),
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2DBE7F),
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
                child: const Text('Got it', style: TextStyle(fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
