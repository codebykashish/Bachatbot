import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import 'category_detail_page.dart';
import 'income_page.dart';
import 'notification_screen.dart';

class CategoriesScreen extends StatefulWidget {
  final bool showAppBar;
  const CategoriesScreen({super.key, this.showAppBar = false});

  @override
  CategoriesScreenState createState() => CategoriesScreenState();
}

class CategoriesScreenState extends State<CategoriesScreen>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  List<dynamic> _budgets = [];
  double _declaredIncome = 0;
  double _savingsPool = 0; // summary.savingsPool — never recomputed locally
  double _remainingBudget = 0; // summary.remainingBudget — never recomputed locally
  // Category Pressure (Phase 2.6) — the shared ranking every category
  // list should sort by, not alphabetically or by budget size. Empty
  // when categoryPressure is null (no budgets at all).
  List<String> _priorityOrder = [];
  final Set<String> _deletingCategories = {};

  late final AnimationController _shakeCtrl;
  late final Animation<double> _shakeAnim;

  static const List<Map<String, dynamic>> _catMeta = [
    {'name': 'Food',          'icon': Icons.restaurant,        'color': Color(0xFFFF7043)},
    {'name': 'Transport',     'icon': Icons.directions_car,    'color': Color(0xFF42A5F5)},
    {'name': 'Rent',          'icon': Icons.home,              'color': Color(0xFF26A69A)},
    {'name': 'Education',     'icon': Icons.school,            'color': Color(0xFF7E57C2)},
    {'name': 'Shopping',      'icon': Icons.shopping_bag,      'color': Color(0xFFAB47BC)},
    {'name': 'Health',        'icon': Icons.favorite,          'color': Color(0xFFEF5350)},
    {'name': 'Entertainment', 'icon': Icons.tv,                'color': Color(0xFF8D6E63)},
    {'name': 'Other',         'icon': Icons.category,          'color': Color(0xFFFFCA28)},
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 480),
    );
    _shakeAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -10.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -10.0, end: 10.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 10.0, end: -8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: 0.0), weight: 1),
    ]).animate(CurvedAnimation(parent: _shakeCtrl, curve: Curves.easeInOut));
    _fetchFinancialSummary();
  }

  @override
  void dispose() {
    _shakeCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _shakeIncomeCard() {
    _shakeCtrl.reset();
    _shakeCtrl.forward();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _fetchFinancialSummary();
  }

  void refresh() => _fetchFinancialSummary();

  void openAddSheet() => _showAddCategorySheet();

  // The only financial request this screen makes. `_budgets` is rebuilt
  // from `categoryRemaining` (already-computed per-category limit/spent/
  // remaining) so every renderer below keeps its existing map shape —
  // nothing downstream needed to change, only where the numbers came from.
  Future<void> _fetchFinancialSummary() async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      // Metrics Engine (Phase 2.2) call runs alongside the summary call —
      // budgetUtilization is a read-only interpretation of categoryRemaining,
      // never recomputed here.
      final results = await Future.wait([
        ApiService.get('/financial-summary?monthKey=$monthKey'),
        ApiService.get('/financial-metrics?monthKey=$monthKey'),
        ApiService.get('/financial-health?monthKey=$monthKey'),
      ]);
      final res = results[0];
      final metricsRes = results[1];
      final healthRes = results[2];
      if (!mounted) return;
      if (res['success'] == true) {
        final summary = res['data'] as Map<String, dynamic>? ?? {};
        final categoryRemaining = (summary['categoryRemaining'] as Map?)?.cast<String, dynamic>() ?? {};
        final budgetUtilization = metricsRes['success'] == true
            ? ((metricsRes['data']?['budgetUtilization'] as Map?)?.cast<String, dynamic>() ?? {})
            : <String, dynamic>{};
        // Category Pressure (Phase 2.6) — read directly, never recomputed
        // here. Null (categoryPressure absent) means no budgets exist yet;
        // both maps stay empty and every category falls back to the
        // curated _catMeta order in _buildDisplayList.
        final categoryPressure = metricsRes['success'] == true
            ? (metricsRes['data']?['categoryPressure'] as Map?)
            : null;
        final pressureByCategory =
            (categoryPressure?['byCategory'] as Map?)?.cast<String, dynamic>() ?? {};
        final priorityOrder =
            (categoryPressure?['priorityOrder'] as List?)?.cast<String>() ?? [];
        // Category Health (Phase 3.2) — read directly, never recomputed
        // here. Null (categoryHealth absent) means no budgets exist yet.
        final categoryHealth = healthRes['success'] == true
            ? (healthRes['data']?['categoryHealth'] as Map?)?.cast<String, dynamic>()
            : null;
        setState(() {
          _budgets = categoryRemaining.entries
              .where((e) => e.key.toLowerCase() != 'salary' && (e.value['limit'] ?? 0) > 0)
              .map((e) => {
                    'category': e.key,
                    'limit': e.value['limit'],
                    'spent': e.value['spent'],
                    'remaining': e.value['remaining'],
                    'utilization': (budgetUtilization[e.key]?['utilization'] ?? 0).toDouble(),
                    'pressureStatus': pressureByCategory[e.key]?['status'] as String?,
                    'healthStatus': categoryHealth?[e.key]?['status'] as String?,
                  })
              .toList();
          _declaredIncome = (summary['income'] ?? 0).toDouble();
          _savingsPool = (summary['savingsPool'] ?? 0).toDouble();
          _remainingBudget = (summary['remainingBudget'] ?? 0).toDouble();
          _priorityOrder = priorityOrder;
        });
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to load budgets.'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Color _catColor(String name) {
    try { return _catMeta.firstWhere((c) => c['name'] == name)['color'] as Color; }
    catch (_) { return _primary; }
  }

  IconData _catIcon(String name) {
    try { return _catMeta.firstWhere((c) => c['name'] == name)['icon'] as IconData; }
    catch (_) { return Icons.category; }
  }

  // Sorted by Category Pressure's priorityOrder (highest pressure first)
  // — not alphabetically, not by budget size. Falls back to the curated
  // _catMeta order for any budgeted category priorityOrder doesn't cover
  // (e.g. categoryPressure is null because no budgets exist at all), so
  // a category never silently disappears from the list.
  List<Map<String, dynamic>> _buildDisplayList() {
    final budgetedNames = _budgets.map((b) => b['category'] as String).toSet();
    final ordered = <Map<String, dynamic>>[];
    for (final cat in _priorityOrder) {
      if (budgetedNames.contains(cat)) {
        ordered.add(_budgets.firstWhere((b) => b['category'] == cat));
      }
    }
    for (final meta in _catMeta) {
      final name = meta['name'] as String;
      if (budgetedNames.contains(name) && !ordered.any((b) => b['category'] == name)) {
        ordered.add(_budgets.firstWhere((b) => b['category'] == name));
      }
    }
    return ordered;
  }

  // _totalLimit aggregates already-Engine-given per-category limits — not a
  // new formula, just a total of numbers the Engine already reported. Kept
  // local only because it feeds `_spentPercent`, a presentation-only ratio
  // the Engine doesn't expose yet (noted below, Phase 3 territory).
  double get _totalLimit => _budgets.fold(0.0, (s, b) => s + (b['limit'] ?? 0).toDouble());
  double get _totalSpent => _budgets.fold(0.0, (s, b) => s + (b['spent'] ?? 0).toDouble());
  // Unused budget already allocated to other categories — this is exactly
  // categoryRemaining[cat].remaining per category (the Engine already
  // computed limit-spent, floored at 0); summed here, never re-derived.
  double get _totalBuffer => _budgets.fold(0.0, (s, b) => s + (b['remaining'] ?? 0).toDouble());
  // Total savings = savingsPool + remainingBudget — both read directly from
  // the Engine, zero subtraction happening in Flutter. Algebraically
  // identical to the old "income − actual spend" formula (proven equal:
  // savingsPool + remainingBudget = (income−limit) + (limit−spent) =
  // income−spent), but now it's a sum of two Engine outputs, not a
  // Flutter-side derivation.
  double get _netSavings => _savingsPool + _remainingBudget;
  // Presentation-only percentage — the Engine doesn't expose this as a
  // field yet (belongs in the Engine once Phase 3 / Health adds it), so
  // this one ratio is left local, computed from already-summary-sourced
  // totals rather than a separately-fetched list.
  double get _spentPercent => _totalLimit > 0 ? (_totalSpent / _totalLimit * 100) : 0;

  // ── Add Category ──────────────────────────────────────────────────────────

  Future<void> _showAddCategorySheet() async {
    // Income must be set before budgeting
    if (_declaredIncome == 0) {
      _shakeIncomeCard();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Set your income first to start budgeting'),
          backgroundColor: Colors.orange.shade700,
          behavior: SnackBarBehavior.floating,
          action: SnackBarAction(
            label: 'Add Income',
            textColor: Colors.white,
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const IncomePage()),
            ).then((_) => _fetchFinancialSummary()),
          ),
        ),
      );
      return;
    }

    final budgetedNames = _budgets.map((b) => b['category'] as String).toSet();
    final available = _catMeta.where((m) => !budgetedNames.contains(m['name'])).toList();

    if (available.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All categories are already added.')),
      );
      return;
    }

    // Pre-compute height using the screen's context, NOT the sheet's ctx.
    // Using MediaQuery.of(ctx) inside the builder registers ctx as a MediaQuery
    // dependent. When the sheet closes and the budget dialog's autofocus opens
    // the keyboard, MediaQuery.viewInsets changes and Flutter tries to notify
    // the already-deactivating ctx → _dependents.isEmpty crash.
    final sheetMaxHeight = MediaQuery.of(context).size.height * 0.65;

    final selected = await showModalBottomSheet<Map<String, dynamic>>(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: sheetMaxHeight),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Padding(
                padding: EdgeInsets.fromLTRB(20, 20, 20, 12),
                child: Text('Add Category', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
              ),
              Flexible(
                child: SingleChildScrollView(
                  child: Column(
                    children: [
                      ...available.map((cat) {
                        final color = cat['color'] as Color;
                        final icon = cat['icon'] as IconData;
                        return ListTile(
                          leading: Container(
                            width: 38, height: 38,
                            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                            child: Icon(icon, color: color, size: 20),
                          ),
                          title: Text(cat['name'] as String, style: const TextStyle(fontWeight: FontWeight.w600)),
                          onTap: () => Navigator.pop(ctx, cat),
                        );
                      }),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (selected == null || !mounted) return;
    // Yield one frame so the sheet's dismiss animation and context cleanup
    // finish before the budget dialog opens and triggers keyboard/MediaQuery changes.
    await Future.delayed(Duration.zero);
    if (!mounted) return;
    _showSetBudgetDialog(selected);
  }

  Future<void> _showSetBudgetDialog(Map<String, dynamic> catMeta) async {
    final catName   = catMeta['name']  as String;
    final catColor  = catMeta['color'] as Color;
    final catIcon   = catMeta['icon']  as IconData;
    // Available = Savings Pool (already the Engine's unallocated-income
    // figure) + unused buffer sitting in other categories. The backend
    // auto-rebalances from that buffer when needed, so it must count as
    // available here too — otherwise the dialog wrongly blocks additions
    // the backend would allow. Both terms are direct Engine reads now.
    final available = _declaredIncome > 0
        ? _savingsPool + _totalBuffer
        : double.infinity;

    // Use a proper StatefulWidget for the dialog so Flutter manages
    // FocusNode / TextEditingController lifecycle correctly and the
    // _dependents.isEmpty assertion never fires on dismiss.
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (_) => _BudgetDialogContent(
        catName: catName,
        catColor: catColor,
        catIcon: catIcon,
        available: available,
        declaredIncome: _declaredIncome,
        onSaved: () {
          if (mounted) _fetchFinancialSummary();
        },
        onError: (msg) {
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(msg), backgroundColor: Colors.red),
            );
          }
        },
      ),
    );
  }

  // ── Delete Category ───────────────────────────────────────────────────────

  Future<void> _deleteCategory(Map<String, dynamic> item) async {
    final category = item['category'] as String;
    final spent = (item['spent'] ?? 0).toDouble();

    // Guard against a second tap firing while the first delete is still
    // in-flight — that raced request hits a 404 (already deleted) and
    // showed an error even though the removal itself had succeeded.
    if (_deletingCategories.contains(category)) return;

    if (spent > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Cannot remove $category: Rs ${spent.toInt()} already tracked this month.'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    final limit = (item['limit'] ?? 0).toDouble();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Remove $category?'),
        content: Text(
          limit > 0
              ? 'This removes the Rs ${limit.toInt()} budget. That amount will be freed from your income allocation.'
              : 'Remove this category?',
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    _deletingCategories.add(category);
    try {
      final now = DateTime.now();
      final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      await ApiService.delete('/budgets/$category?monthKey=$monthKey');
      _fetchFinancialSummary();
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().contains('HAS_TRACKED_EXPENSES')
          ? 'Cannot remove $category: expenses already tracked.'
          : 'Failed to remove: $e';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(msg), backgroundColor: Colors.red),
      );
    } finally {
      _deletingCategories.remove(category);
    }
  }

  @override
  Widget build(BuildContext context) {
    final displayList = _buildDisplayList();

    final pairs = <List<Map<String, dynamic>>>[];
    for (int i = 0; i < displayList.length; i += 2) {
      pairs.add([
        displayList[i],
        if (i + 1 < displayList.length) displayList[i + 1],
      ]);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: widget.showAppBar
          ? AppBar(
              title: const Text('Categories', style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              elevation: 0,
              actions: [
                IconButton(
                  icon: ValueListenableBuilder<int>(
                    valueListenable: NotificationScreen.unreadCount,
                    builder: (context, count, child) {
                      return Badge(
                        isLabelVisible: count > 0,
                        label: Text(count > 99 ? '99+' : count.toString()),
                        child: const Icon(Icons.notifications_none),
                      );
                    },
                  ),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const NotificationScreen()),
                  ),
                ),
              ],
            )
          : null,
      body: RefreshIndicator(
        color: _primary,
        onRefresh: _fetchFinancialSummary,
        child: _isLoading && _budgets.isEmpty
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF2DBE7F)))
            : SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Total Budget banner ──────────────────────────────────
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            _spentPercent > 100
                                ? const Color(0xFFE53935)
                                : const Color(0xFF2DBE7F),
                            _spentPercent > 100
                                ? const Color(0xFFC62828)
                                : const Color(0xFF1DA870),
                          ],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'TOTAL MONTHLY BUDGET',
                                  style: TextStyle(
                                    fontSize: 11,
                                    color: Colors.white.withValues(alpha: 0.75),
                                    letterSpacing: 0.8,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Row(
                                  crossAxisAlignment: CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Text(
                                      'Rs ${_totalSpent.toInt()}',
                                      style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold, color: Colors.white),
                                    ),
                                    Text(
                                      ' / Rs ${_totalLimit.toInt()}',
                                      style: TextStyle(fontSize: 15, color: Colors.white.withValues(alpha: 0.75)),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(
                                      _spentPercent > 100 ? Icons.warning_amber_rounded : Icons.check_circle_outline_rounded,
                                      color: Colors.white,
                                      size: 14,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _totalLimit > 0
                                          ? '${_spentPercent.toInt()}% of budget used'
                                          : 'No budgets set yet',
                                      style: const TextStyle(fontSize: 12, color: Colors.white),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Container(
                            width: 44, height: 44,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.18),
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(Icons.trending_up_rounded, color: Colors.white, size: 22),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 12),

                    // ── Income card ───────────────────────────────────────────
                    AnimatedBuilder(
                      animation: _shakeAnim,
                      builder: (_, child) => Transform.translate(
                        offset: Offset(_shakeAnim.value, 0),
                        child: child,
                      ),
                      child: _declaredIncome == 0
                          ? GestureDetector(
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const IncomePage()),
                              ).then((_) => _fetchFinancialSummary()),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 18, vertical: 16),
                                decoration: BoxDecoration(
                                  color: Colors.orange.shade50,
                                  borderRadius: BorderRadius.circular(14),
                                  border: Border.all(
                                      color: Colors.orange.shade200),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 42,
                                      height: 42,
                                      decoration: BoxDecoration(
                                        color: Colors.orange.shade100,
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                          Icons
                                              .account_balance_wallet_outlined,
                                          color: Colors.orange.shade700,
                                          size: 22),
                                    ),
                                    const SizedBox(width: 14),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            'Set Your Monthly Income',
                                            style: TextStyle(
                                              fontSize: 14,
                                              fontWeight: FontWeight.w700,
                                              color:
                                                  Colors.orange.shade800,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            'Required to add budgets and track savings',
                                            style: TextStyle(
                                                fontSize: 11.5,
                                                color:
                                                    Colors.orange.shade600),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(Icons.arrow_forward_ios_rounded,
                                        size: 14,
                                        color: Colors.orange.shade400),
                                  ],
                                ),
                              ),
                            )
                          : GestureDetector(
                              onTap: () => Navigator.push(
                                context,
                                MaterialPageRoute(
                                    builder: (_) => const IncomePage()),
                              ).then((_) => _fetchFinancialSummary()),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 11),
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                      color: _primary.withValues(alpha: 0.2)),
                                ),
                                child: Row(
                                  children: [
                                    Container(
                                      width: 32,
                                      height: 32,
                                      decoration: BoxDecoration(
                                        color:
                                            _primary.withValues(alpha: 0.1),
                                        shape: BoxShape.circle,
                                      ),
                                      child: Icon(
                                          Icons.attach_money_rounded,
                                          color: _primary,
                                          size: 18),
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          const Text('Monthly Income',
                                              style: TextStyle(
                                                  fontSize: 11,
                                                  color: Colors.grey)),
                                          Text(
                                            'Rs ${_declaredIncome.toInt()}',
                                            style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.bold,
                                                color: Colors.black87),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Text('Edit',
                                        style: TextStyle(
                                            fontSize: 12,
                                            color: _primary,
                                            fontWeight: FontWeight.w600)),
                                  ],
                                ),
                              ),
                            ),
                    ),

                    const SizedBox(height: 16),

                    // ── Spending Buckets header with Add button ───────────────
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        const Text('Spending Buckets', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                        TextButton.icon(
                          onPressed: _showAddCategorySheet,
                          icon: const Icon(Icons.add, size: 18, color: Color(0xFF2DBE7F)),
                          label: const Text('Add', style: TextStyle(color: Color(0xFF2DBE7F), fontWeight: FontWeight.w600)),
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            backgroundColor: const Color(0xFF2DBE7F).withValues(alpha: 0.08),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
                          ),
                        ),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // ── Empty state ──────────────────────────────────────────
                    if (displayList.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 32),
                        child: Center(
                          child: Column(
                            children: [
                              Icon(Icons.category_outlined, size: 56, color: Colors.grey.shade300),
                              const SizedBox(height: 14),
                              const Text('No categories yet', style: TextStyle(fontSize: 15, color: Colors.grey)),
                              const SizedBox(height: 6),
                              const Text(
                                'Tap "+ Add" above to set spending categories',
                                style: TextStyle(fontSize: 12, color: Colors.grey),
                                textAlign: TextAlign.center,
                              ),
                            ],
                          ),
                        ),
                      ),

                    // ── 2-column grid ────────────────────────────────────────
                    ...pairs.map((pair) => Padding(
                          padding: const EdgeInsets.only(bottom: 14),
                          child: Row(
                            children: [
                              Expanded(child: _buildBucketCard(pair[0])),
                              const SizedBox(width: 14),
                              pair.length > 1
                                  ? Expanded(child: _buildBucketCard(pair[1]))
                                  : const Expanded(child: SizedBox()),
                            ],
                          ),
                        )),

                    if (displayList.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      // ── Savings banner ──────────────────────────────────────
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(color: Colors.grey.shade100),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 40, height: 40,
                              decoration: const BoxDecoration(color: _primary, shape: BoxShape.circle),
                              child: const Icon(Icons.trending_up_rounded, color: Colors.white, size: 20),
                            ),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _totalLimit > 0
                                        ? 'You saved Rs ${_netSavings.toInt()} this month!'
                                        : 'Set budgets to track your savings.',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: Colors.black87),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    _totalLimit > 0
                                        ? 'Keep it up to reach your savings goal.'
                                        : 'Tap any category above to set a budget limit.',
                                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ],
                ),
              ),
      ),
    );
  }

  // Category Health (Phase 3.2) — status label only, never a reason code
  // or raw pressure value shown to the user. "green" shows no chip, to
  // avoid labeling every unremarkable category (same restraint Category
  // Pressure's chip already used in Phase 2.6 — this replaces it, since
  // Category Health is the more authoritative judgment layer built
  // directly on top of Category Pressure + Recovery Plan).
  String? _healthChipLabel(String? status) {
    switch (status) {
      case 'red':
        return 'Critical';
      case 'amber':
        return 'Needs Attention';
      default:
        return null;
    }
  }

  Color _healthChipColor(String? status) {
    switch (status) {
      case 'red':
        return const Color(0xFFE0223B);
      case 'amber':
        return Colors.orange.shade700;
      default:
        return _primary;
    }
  }

  Widget _buildHealthChip(String? status) {
    final label = _healthChipLabel(status)!;
    final color = _healthChipColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700, color: color),
      ),
    );
  }

  Widget _buildBucketCard(Map<String, dynamic> item) {
    final category = item['category'] ?? 'Unknown';
    final spent = (item['spent'] ?? 0).toDouble();
    final limit = (item['limit'] ?? 0).toDouble();
    final isNotSet = limit == 0;
    // utilization comes from the Metrics Engine's budgetUtilization (Phase
    // 2.2) — already spent/limit*100, unclamped. /100 here is a unit
    // conversion for the progress-bar widget, not a re-derivation of the
    // ratio itself; the 0.0-2.0 and 0.0-1.0 clamps below are this screen's
    // own display thresholds (badge/bar bounds), same as before.
    final utilization = (item['utilization'] ?? 0).toDouble();
    final percent = isNotSet ? 0.0 : (utilization / 100).clamp(0.0, 2.0);
    final isOver = !isNotSet && percent > 1.0;
    // Fully used (100%+) — this is the "spending too much" state, whole
    // card turns red so it's impossible to miss while scrolling categories.
    final isCritical = !isNotSet && percent >= 1.0;
    final displayPercent = isNotSet ? 0.0 : (utilization / 100).clamp(0.0, 1.0);

    final color = _catColor(category);
    final icon = _catIcon(category);
    final barColor = isCritical || isOver
        ? const Color(0xFFE0223B)
        : (percent > 0.7 ? Colors.orange : _primary);

    return Stack(
      children: [
        InkWell(
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(
              builder: (_) => CategoryDetailPage(
                category: category,
                budgetLimit: limit,
                budgetSpent: spent,
              ),
            ),
          ).then((_) => _fetchFinancialSummary()),
          borderRadius: BorderRadius.circular(16),
          child: Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: isCritical ? const Color(0xFFE0223B).withValues(alpha: 0.07) : Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: isCritical
                  ? Border.all(color: const Color(0xFFE0223B).withValues(alpha: 0.4), width: 1.3)
                  : null,
              boxShadow: [
                BoxShadow(
                  color: isCritical
                      ? const Color(0xFFE0223B).withValues(alpha: 0.15)
                      : Colors.black.withValues(alpha: 0.05),
                  blurRadius: 8,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(10)),
                      child: Icon(icon, color: Colors.white, size: 20),
                    ),
                    if (!isNotSet)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isCritical ? const Color(0xFFE0223B) : (isOver ? Colors.red : Colors.grey.shade100),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          '${(percent * 100).toInt()}%',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: isCritical || isOver ? Colors.white : Colors.black54,
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Text(
                      category,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: isCritical ? const Color(0xFFE0223B) : Colors.black87,
                      ),
                    ),
                    if (isCritical) ...[
                      const SizedBox(width: 5),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE0223B),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Text(
                          'OVER',
                          style: TextStyle(fontSize: 8, fontWeight: FontWeight.w800, color: Colors.white, letterSpacing: 0.3),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  isNotSet ? 'Tap to set budget' : 'Rs ${spent.toInt()} / Rs ${limit.toInt()}',
                  style: TextStyle(
                    fontSize: 11,
                    color: isCritical ? const Color(0xFFE0223B) : (isOver ? Colors.red : Colors.grey),
                  ),
                ),
                const SizedBox(height: 8),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: displayPercent,
                    minHeight: 5,
                    backgroundColor: isCritical ? const Color(0xFFE0223B).withValues(alpha: 0.15) : Colors.grey.shade200,
                    color: barColor,
                  ),
                ),
                if (_healthChipLabel(item['healthStatus'] as String?) != null) ...[
                  const SizedBox(height: 6),
                  _buildHealthChip(item['healthStatus'] as String?),
                ],
              ],
            ),
          ),
        ),
        // ── Delete button ──────────────────────────────────────────────────
        Positioned(
          top: 2,
          right: 2,
          child: GestureDetector(
            onTap: () => _deleteCategory(item),
            child: Padding(
              padding: const EdgeInsets.all(5),
              child: Icon(Icons.remove, size: 16, color: Colors.red.shade400),
            ),
          ),
        ),
      ],
    );
  }
}

// ── Budget Dialog ─────────────────────────────────────────────────────────────
// A dedicated StatefulWidget for the "Set Budget" dialog.
// Using a real StatefulWidget (instead of StatefulBuilder) is critical:
// StatefulBuilder re-runs its builder on every setState call, which was
// re-registering addPostFrameCallback each time and creating a race where
// Flutter tried to notify an already-deactivating dialog context of
// MediaQuery changes → '_dependents.isEmpty' red crash screen.
// With a proper StatefulWidget, initState runs exactly once, the FocusNode
// is requested once, and dispose() cleans up before the context is torn down.
class _BudgetDialogContent extends StatefulWidget {
  final String   catName;
  final Color    catColor;
  final IconData catIcon;
  final double   available;
  final double   declaredIncome;
  final VoidCallback        onSaved;
  final void Function(String) onError;

  const _BudgetDialogContent({
    required this.catName,
    required this.catColor,
    required this.catIcon,
    required this.available,
    required this.declaredIncome,
    required this.onSaved,
    required this.onError,
  });

  @override
  State<_BudgetDialogContent> createState() => _BudgetDialogContentState();
}

class _BudgetDialogContentState extends State<_BudgetDialogContent> {
  static const Color _primary = Color(0xFF2DBE7F);

  late final TextEditingController _controller;
  late final FocusNode             _focusNode;
  bool    _isSaving   = false;
  String? _inlineError;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focusNode  = FocusNode();
    // Request focus once, after the first frame, so the keyboard opens after
    // the dialog context is fully registered with the widget tree.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _focusNode.canRequestFocus) {
        _focusNode.requestFocus();
      }
    });
  }

  @override
  void dispose() {
    // dispose() is called by Flutter before the element is removed from the
    // tree, so the FocusNode unfocus + disposal happens at the right time and
    // never races with MediaQuery notifications.
    _focusNode.unfocus();
    _focusNode.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _handleCancel() {
    // Unfocus before popping so the keyboard hides before the context is
    // deactivated, preventing MediaQuery.viewInsets from changing mid-teardown.
    _focusNode.unfocus();
    if (mounted) Navigator.of(context).pop();
  }

  Future<bool> _confirmRebalance(List<dynamic> plan) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Adjust other budgets?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Not enough available to save. To fit this budget, unused '
              'amounts will be taken from:',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            ...plan.map((p) {
              final cat = p['category'] as String;
              final taken = (p['amountTaken'] as num).toInt();
              final oldLimitRaw = p['oldLimit'] as num?;
              final newLimitRaw = p['newLimit'] as num?;
              final affectsGoals = (p['affectsGoals'] as List?)?.cast<String>() ?? [];
              final isAlarming = cat == 'Savings' && affectsGoals.isNotEmpty;

              if (isAlarming) {
                final goalsList = affectsGoals.join(', ');
                return Container(
                  margin: const EdgeInsets.only(bottom: 8),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.red.shade200),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.warning_amber_rounded, color: Colors.red.shade700, size: 18),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Rs $taken would come from your Savings — money currently counted toward: $goalsList',
                          style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700, color: Colors.red.shade800),
                        ),
                      ),
                    ],
                  ),
                );
              }

              // "Savings" is unallocated income, not a category budget —
              // it has no old/new limit to show, just the amount used.
              final text = oldLimitRaw == null || newLimitRaw == null
                  ? '• $cat: Rs $taken taken'
                  : '• $cat: Rs ${oldLimitRaw.toInt()} → Rs ${newLimitRaw.toInt()}  (Rs $taken taken)';

              return Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  text,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              );
            }),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: ElevatedButton.styleFrom(
              backgroundColor: _primary,
              foregroundColor: Colors.white,
            ),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  Future<void> _handleAdd() async {
    final v = double.tryParse(_controller.text);
    if (v == null || v <= 0) return;
    if (widget.available != double.infinity && v > widget.available) {
      setState(() => _inlineError = 'Exceeds available Rs ${widget.available.toInt()}');
      return;
    }
    setState(() => _isSaving = true);
    try {
      // Preview first — no writes happen for a dry run. If it would take
      // budget from other categories, ask the user to confirm exactly
      // which categories and how much before committing anything.
      final preview = await ApiService.post('/budgets', {
        'category': widget.catName,
        'limit': v,
        'dryRun': true,
      });

      final previewData = preview['data'] as Map<String, dynamic>?;
      final requiresRebalance = previewData?['requiresRebalance'] == true;

      if (requiresRebalance) {
        final plan = previewData?['rebalancePlan'] as List<dynamic>? ?? [];
        final confirmed = await _confirmRebalance(plan);
        if (!confirmed) {
          if (mounted) setState(() => _isSaving = false);
          return;
        }
      }

      await ApiService.post('/budgets', {'category': widget.catName, 'limit': v});
      widget.onSaved();
      _focusNode.unfocus();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) setState(() => _isSaving = false);
      widget.onError('Failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: widget.catColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(widget.catIcon, color: widget.catColor, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text('Budget for ${widget.catName}')),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.declaredIncome > 0)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: Row(
                children: [
                  Icon(
                    Icons.account_balance_wallet_outlined,
                    size: 14,
                    color: widget.available > 0 ? _primary : Colors.orange,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    widget.available > 0
                        ? 'Rs ${widget.available.toInt()} available to allocate'
                        : 'No budget available — add income or free up another category',
                    style: TextStyle(
                      fontSize: 12,
                      color: widget.available > 0 ? _primary : Colors.orange,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: false,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(7),
            ],
            onChanged: (val) {
              if (!mounted) return;
              final v = double.tryParse(val);
              if (widget.available != double.infinity && v != null && v > widget.available) {
                setState(() => _inlineError = 'Exceeds available Rs ${widget.available.toInt()}');
              } else {
                setState(() => _inlineError = null);
              }
            },
            decoration: InputDecoration(
              prefixText: 'Rs  ',
              hintText: 'e.g. 5000',
              border: const OutlineInputBorder(),
              errorText: _inlineError,
              errorStyle: const TextStyle(fontSize: 11),
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : _handleCancel,
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSaving || _inlineError != null ? null : _handleAdd,
          style: ElevatedButton.styleFrom(
            backgroundColor: _primary,
            foregroundColor: Colors.white,
          ),
          child: _isSaving
              ? const SizedBox(
                  width: 16, height: 16,
                  child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                )
              : const Text('Add'),
        ),
      ],
    );
  }
}
