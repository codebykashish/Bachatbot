import 'package:flutter/material.dart';
import '../api_service.dart';
import '../widgets/adaptive_report_chart.dart';
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

class ReportsScreenState extends State<ReportsScreen>
    with WidgetsBindingObserver {
  static const Color _primary = Color(0xFF2DBE7F);

  static const List<String> _categories = [
    'Food', 'Transport', 'Rent', 'Education', 'Shopping', 'Health', 'Entertainment', 'Other',
  ];

  bool _isLoading = true;
  String _selectedView = 'today'; // 'today' | 'week' | 'month'
  String? _selectedCategory; // null = "All"
  String _selectedMonthKey = '';
  late DateTime _currentMonth;

  // Report data
  double _totalExpense = 0;
  Map<String, double> _categoryBreakdown = {};
  List<dynamic> _dailyBreakdown = [];
  // Real Health Engine status (green/amber/red), not a local proxy --
  // Phase 13.8's own reconciliation, the same duplicate-signal problem
  // already found and fixed for the ambient overlay and Categories.
  String? _overallHealthStatus;
  Map<String, String> _categoryHealth = {}; // category -> green/amber/red
  List<Goal> _goals = [];
  Map<String, dynamic>? _projectedSavings; // Metrics Engine (Phase 2.7, Predictive) — null when no budgets exist

  // Guards against an out-of-order response overwriting fresher data --
  // _loadReport() can be triggered concurrently (refresh, view switch,
  // month navigation, lifecycle resume); without this, whichever
  // Future.wait resolves last wins the setState, even if it started
  // first and is now stale. Same root cause already found and fixed on
  // the Categories and Home screens.
  int _loadGeneration = 0;
  // Recommendation, Recovery Plan, and Risk Flags moved to HealthScreen
  // (Phase 13.4) — this screen stays focused on income/spending/savings;
  // "am I okay, what should I do" now lives in one place, not two.

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    final now = DateTime.now();
    _currentMonth = DateTime(now.year, now.month, 1);
    _selectedMonthKey = _formatMonthKey(_currentMonth);
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

  String _formatMonthLabel(DateTime date) {
    const months = [
      'January', 'February', 'March', 'April', 'May', 'June',
      'July', 'August', 'September', 'October', 'November', 'December',
    ];
    return '${months[date.month - 1]} ${date.year}';
  }

  void _setView(String view) {
    if (_selectedView == view) return;
    setState(() {
      _selectedView = view;
      _isLoading = true;
    });
    _loadReport();
  }

  void _setCategory(String? category) {
    if (_selectedCategory == category) return;
    // Category filter is applied client-side from already-fetched data —
    // no need to refetch, keeps the filter feeling instant.
    setState(() => _selectedCategory = category);
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
    if (_currentMonth.year == now.year && _currentMonth.month == now.month) return;
    final next = DateTime(_currentMonth.year, _currentMonth.month + 1);
    setState(() {
      _currentMonth = next;
      _selectedMonthKey = _formatMonthKey(next);
      _isLoading = true;
    });
    _loadReport();
  }

  Future<void> _loadReport() async {
    final myGen = ++_loadGeneration;
    try {
      final futures = await Future.wait([
        ApiService.get('/monthly-report?monthKey=$_selectedMonthKey&view=$_selectedView'),
        ApiService.get('/goals'),
        ApiService.get('/financial-metrics?monthKey=$_selectedMonthKey'),
        ApiService.get('/financial-health?monthKey=$_selectedMonthKey'),
      ]);
      final res = futures[0];
      final goalsRes = futures[1];
      final metricsRes = futures[2];
      final healthRes = futures[3];

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

        // Health Engine (Phase 3.1/3.2) — the real overall/category
        // status, read directly, never recomputed. Replaces the old
        // local overallStatus proxy (Phase 13.8's reconciliation).
        String? overallHealthStatus;
        Map<String, String> categoryHealth = {};
        if (healthRes['success'] == true) {
          overallHealthStatus = healthRes['data']?['overallHealth']?['status'] as String?;
          final rawCategoryHealth = healthRes['data']?['categoryHealth'] as Map?;
          if (rawCategoryHealth != null) {
            categoryHealth = rawCategoryHealth.map(
              (k, v) => MapEntry(k.toString(), (v as Map)['status'] as String? ?? 'green'),
            );
          }
        }

        setState(() {
          _totalExpense = (report?['totalExpense'] ?? 0).toDouble();
          _categoryBreakdown = _mapToDouble(report?['categoryBreakdown'] ?? {});
          _dailyBreakdown = report?['dailyBreakdown'] as List? ?? [];
          _overallHealthStatus = overallHealthStatus;
          _categoryHealth = categoryHealth;
          _goals = goals;
          _projectedSavings = projectedSavings;
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

  // ── Derived: the headline number for the current view + category ────────
  double get _headlineAmount {
    if (_selectedCategory == null) return _totalExpense;
    if (_selectedView == 'today') return _categoryBreakdown[_selectedCategory] ?? 0;
    double sum = 0;
    for (final raw in _dailyBreakdown) {
      final d = raw as Map<String, dynamic>;
      final categories = (d['categories'] as Map?)?.cast<String, dynamic>() ?? {};
      sum += (categories[_selectedCategory] as num?)?.toDouble() ?? 0;
    }
    return sum;
  }

  String get _headlinePeriodLabel {
    switch (_selectedView) {
      case 'today':
        return 'today';
      case 'week':
        return 'this week';
      default:
        return 'this month';
    }
  }

  void _openCategoryFilterSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (sheetContext) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Filter by Category', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _CategoryChip(
                    label: 'All',
                    selected: _selectedCategory == null,
                    onTap: () {
                      _setCategory(null);
                      Navigator.pop(sheetContext);
                    },
                  ),
                  ..._categories.map((c) => _CategoryChip(
                        label: c,
                        selected: _selectedCategory == c,
                        onTap: () {
                          _setCategory(c);
                          Navigator.pop(sheetContext);
                        },
                      )),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  // Top spending category this period -- the "good insight" asked for,
  // purely a client-side max() over data already fetched (no new
  // backend call, no new logic beyond finding the largest existing number).
  MapEntry<String, double>? get _topCategory {
    if (_categoryBreakdown.isEmpty) return null;
    final entries = _categoryBreakdown.entries.where((e) => e.value > 0).toList();
    if (entries.isEmpty) return null;
    entries.sort((a, b) => b.value.compareTo(a.value));
    return entries.first;
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
                    // ── Time range tabs + category filter icon ────────────
                    Row(
                      children: [
                        Expanded(child: _TabChip(label: 'Today', selected: _selectedView == 'today', onTap: () => _setView('today'))),
                        const SizedBox(width: 8),
                        Expanded(child: _TabChip(label: 'Week', selected: _selectedView == 'week', onTap: () => _setView('week'))),
                        const SizedBox(width: 8),
                        Expanded(child: _TabChip(label: 'Month', selected: _selectedView == 'month', onTap: () => _setView('month'))),
                        const SizedBox(width: 8),
                        Stack(
                          children: [
                            Container(
                              decoration: BoxDecoration(
                                color: Colors.white,
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(color: Colors.grey.shade300),
                              ),
                              child: IconButton(
                                icon: const Icon(Icons.tune_rounded, size: 20),
                                color: _selectedCategory != null ? _primary : Colors.grey.shade700,
                                tooltip: 'Filter by category',
                                onPressed: _openCategoryFilterSheet,
                              ),
                            ),
                            if (_selectedCategory != null)
                              Positioned(
                                right: 8,
                                top: 8,
                                child: Container(
                                  width: 8,
                                  height: 8,
                                  decoration: const BoxDecoration(color: _primary, shape: BoxShape.circle),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),

                    // ── Small month navigator (Month tab only) ────────────
                    if (_selectedView == 'month') ...[
                      const SizedBox(height: 10),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.chevron_left, size: 20),
                            onPressed: _previousMonth,
                            color: Colors.grey.shade600,
                            visualDensity: VisualDensity.compact,
                          ),
                          Text(
                            _formatMonthLabel(_currentMonth),
                            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.black87),
                          ),
                          IconButton(
                            icon: const Icon(Icons.chevron_right, size: 20),
                            onPressed: _currentMonth.year == DateTime.now().year && _currentMonth.month == DateTime.now().month
                                ? null
                                : _nextMonth,
                            color: Colors.grey.shade600,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ],

                    if (_selectedCategory != null) ...[
                      const SizedBox(height: 10),
                      Chip(
                        label: Text(_selectedCategory!, style: const TextStyle(fontSize: 12, color: _primary, fontWeight: FontWeight.w600)),
                        backgroundColor: _primary.withValues(alpha: 0.1),
                        deleteIcon: const Icon(Icons.close, size: 16, color: _primary),
                        onDeleted: () => _setCategory(null),
                        visualDensity: VisualDensity.compact,
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      ),
                    ],

                    const SizedBox(height: 16),

                    // ── The chart ──────────────────────────────────────────
                    AdaptiveReportChart(
                      mode: _selectedView,
                      categoryBreakdown: _categoryBreakdown,
                      dailyBreakdown: _dailyBreakdown,
                      selectedCategory: _selectedCategory,
                      categoryHealth: _categoryHealth,
                    ),

                    const SizedBox(height: 14),

                    // ── Headline stat line ─────────────────────────────────
                    Text(
                      _selectedCategory == null
                          ? 'Rs ${_headlineAmount.toInt()} total $_headlinePeriodLabel'
                          : 'Rs ${_headlineAmount.toInt()} on $_selectedCategory $_headlinePeriodLabel',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.black87),
                    ),

                    // ── Top category insight -- a plain max() over data
                    // already on screen, no new fetch, no new logic.
                    // Only shown unfiltered; picking one category out as
                    // "top" is meaningless once you're already looking at
                    // just that one category.
                    if (_selectedCategory == null && _topCategory != null) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Row(
                          children: [
                            Icon(Icons.insights_outlined, size: 18, color: Colors.grey.shade500),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                'You spent the most on ${_topCategory!.key}: Rs ${_topCategory!.value.toInt()}',
                                style: TextStyle(fontSize: 12.5, color: Colors.grey.shade700, fontWeight: FontWeight.w500),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],

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

  // Recommendation, Recovery Plan, and Risk Flags wording/cards moved to
  // HealthScreen (Phase 13.4).

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

class _CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _CategoryChip({required this.label, required this.selected, required this.onTap});

  static const Color _primary = Color(0xFF2DBE7F);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: selected ? _primary.withValues(alpha: 0.12) : Colors.white,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? _primary : Colors.grey.shade300),
        ),
        child: Text(
          label,
          style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: selected ? _primary : Colors.grey.shade700),
        ),
      ),
    );
  }
}
