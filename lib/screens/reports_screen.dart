import 'package:flutter/material.dart';
import '../api_service.dart';
import '../widgets/adaptive_report_chart.dart';
import '../models/goal.dart';
import 'goals_screen.dart';

class ReportsScreen extends StatefulWidget {
  const ReportsScreen({super.key});

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
  String _selectedView = 'week'; // 'today' | 'week' | 'month'
  String? _selectedCategory; // null = "All"
  String _selectedMonthKey = '';
  late DateTime _currentMonth;

  // Report data
  double _totalExpense = 0;
  Map<String, double> _categoryBreakdown = {};
  List<dynamic> _dailyBreakdown = [];
  String _overallStatus = 'ok';
  List<Goal> _goals = [];

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
    try {
      final futures = await Future.wait([
        ApiService.get('/monthly-report?monthKey=$_selectedMonthKey&view=$_selectedView'),
        ApiService.get('/goals'),
      ]);
      final res = futures[0];
      final goalsRes = futures[1];

      if (!mounted) return;

      if (res['success'] == true) {
        final data = res['data'];
        final report = data?['report'] ?? data;

        List<Goal> goals = [];
        if (goalsRes['success'] == true) {
          goals = (goalsRes['data']?['goals'] as List? ?? [])
              .map((g) => Goal.fromJson(g as Map<String, dynamic>))
              .toList();
        }

        setState(() {
          _totalExpense = (report?['totalExpense'] ?? 0).toDouble();
          _categoryBreakdown = _mapToDouble(report?['categoryBreakdown'] ?? {});
          _dailyBreakdown = report?['dailyBreakdown'] as List? ?? [];
          _overallStatus = report?['insights']?['overallStatus'] ?? 'ok';
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Reports', style: TextStyle(fontWeight: FontWeight.bold)),
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
                    // ── Time range tabs ───────────────────────────────────
                    Row(
                      children: [
                        Expanded(child: _TabChip(label: 'Today', selected: _selectedView == 'today', onTap: () => _setView('today'))),
                        const SizedBox(width: 8),
                        Expanded(child: _TabChip(label: 'Week', selected: _selectedView == 'week', onTap: () => _setView('week'))),
                        const SizedBox(width: 8),
                        Expanded(child: _TabChip(label: 'Month', selected: _selectedView == 'month', onTap: () => _setView('month'))),
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

                    const SizedBox(height: 16),

                    // ── Category filter chips ─────────────────────────────
                    SizedBox(
                      height: 34,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        children: [
                          _CategoryChip(label: 'All', selected: _selectedCategory == null, onTap: () => _setCategory(null)),
                          ..._categories.map((c) => Padding(
                                padding: const EdgeInsets.only(left: 8),
                                child: _CategoryChip(label: c, selected: _selectedCategory == c, onTap: () => _setCategory(c)),
                              )),
                        ],
                      ),
                    ),

                    const SizedBox(height: 16),

                    // ── The chart ──────────────────────────────────────────
                    AdaptiveReportChart(
                      mode: _selectedView,
                      categoryBreakdown: _categoryBreakdown,
                      dailyBreakdown: _dailyBreakdown,
                      selectedCategory: _selectedCategory,
                    ),

                    const SizedBox(height: 14),

                    // ── Headline stat line ─────────────────────────────────
                    Text(
                      _selectedCategory == null
                          ? 'Rs ${_headlineAmount.toInt()} total $_headlinePeriodLabel'
                          : 'Rs ${_headlineAmount.toInt()} on $_selectedCategory $_headlinePeriodLabel',
                      style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.black87),
                    ),

                    const SizedBox(height: 20),

                    // ── Overall Status ────────────────────────────────────
                    _buildOverallStatusCard(),

                    // ── Savings Goals summary ─────────────────────────────
                    if (_goals.isNotEmpty) ...[
                      const SizedBox(height: 16),
                      _buildGoalsSummary(),
                    ],

                    // Reserved spot for future "suggestions/alerts" teaser —
                    // add it here as a single collapsed entry point once that
                    // feature exists, not stacked content on this screen.
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildOverallStatusCard() {
    String statusText;
    Color statusColor;
    IconData statusIcon;

    switch (_overallStatus.toLowerCase()) {
      case 'low':
      case 'ok':
        statusText = 'Low spending — on budget';
        statusColor = _primary;
        statusIcon = Icons.check_circle;
        break;
      case 'high':
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
        statusText = 'On track';
        statusColor = _primary;
        statusIcon = Icons.check_circle;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: statusColor.withValues(alpha: 0.25)),
      ),
      child: Row(
        children: [
          Icon(statusIcon, color: statusColor, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(statusText, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: statusColor)),
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
              const Text('Savings Goals', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
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
                      Text('Rs ${g.savedSoFar.toInt()} / Rs ${g.targetAmount.toInt()}', style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
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
