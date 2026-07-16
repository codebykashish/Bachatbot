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
    _fetchBudgets();
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
    if (state == AppLifecycleState.resumed) _fetchBudgets();
  }

  void refresh() => _fetchBudgets();

  void openAddSheet() => _showAddCategorySheet();

  Future<void> _fetchBudgets() async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final results = await Future.wait([
        ApiService.get('/budgets?monthKey=$monthKey'),
        ApiService.get('/income'),
      ]);
      if (!mounted) return;
      final budgetRes = results[0];
      final incomeRes = results[1];
      if (budgetRes['success'] == true) {
        final budgetsList = (budgetRes['data']?['budgets'] as List? ?? []);
        setState(() {
          _budgets = budgetsList
              .where((b) =>
                  b['category']?.toString().toLowerCase() != 'salary' &&
                  (b['limit'] ?? 0) > 0)
              .toList();
          if (incomeRes['success'] == true) {
            _declaredIncome = (incomeRes['data']?['total'] ?? 0).toDouble();
          }
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

  List<Map<String, dynamic>> _buildDisplayList() {
    final budgetedNames = _budgets.map((b) => b['category'] as String).toSet();
    final ordered = <Map<String, dynamic>>[];
    for (final meta in _catMeta) {
      if (budgetedNames.contains(meta['name'])) {
        ordered.add(_budgets.firstWhere((b) => b['category'] == meta['name']));
      }
    }
    return ordered;
  }

  double get _totalLimit => _budgets.fold(0.0, (s, b) => s + (b['limit'] ?? 0).toDouble());
  double get _totalSpent => _budgets.fold(0.0, (s, b) => s + (b['spent'] ?? 0).toDouble());
  // Unused budget already allocated to other categories (limit - spent, per
  // category, floored at 0). The backend can auto-rebalance this into a new
  // or increased category budget, so it counts as available too.
  double get _totalBuffer => _budgets.fold(0.0, (s, b) {
        final limit = (b['limit'] ?? 0).toDouble();
        final spent = (b['spent'] ?? 0).toDouble();
        return s + (limit - spent).clamp(0.0, double.infinity);
      });
  // Total savings = income − what was actually spent (not just unspent budget)
  double get _netSavings => _declaredIncome > 0
      ? (_declaredIncome - _totalSpent).clamp(0.0, double.infinity)
      : (_totalLimit - _totalSpent).clamp(0.0, double.infinity);
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
            ).then((_) => _fetchBudgets()),
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
    // Available = unallocated income + unused buffer sitting in other
    // categories (limit - spent). The backend auto-rebalances from that
    // buffer when needed, so it must count as available here too —
    // otherwise the dialog wrongly blocks additions the backend would allow.
    final available = _declaredIncome > 0
        ? (_declaredIncome - _totalLimit).clamp(0.0, double.infinity) + _totalBuffer
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
          if (mounted) _fetchBudgets();
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
      _fetchBudgets();
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
        onRefresh: _fetchBudgets,
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
                              ).then((_) => _fetchBudgets()),
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
                              ).then((_) => _fetchBudgets()),
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

  Widget _buildBucketCard(Map<String, dynamic> item) {
    final category = item['category'] ?? 'Unknown';
    final spent = (item['spent'] ?? 0).toDouble();
    final limit = (item['limit'] ?? 0).toDouble();
    final isNotSet = limit == 0;
    final percent = isNotSet ? 0.0 : (spent / limit).clamp(0.0, 2.0);
    final isOver = !isNotSet && percent > 1.0;
    // Fully used (100%+) — this is the "spending too much" state, whole
    // card turns red so it's impossible to miss while scrolling categories.
    final isCritical = !isNotSet && percent >= 1.0;
    final displayPercent = isNotSet ? 0.0 : (spent / limit).clamp(0.0, 1.0);

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
          ).then((_) => _fetchBudgets()),
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
