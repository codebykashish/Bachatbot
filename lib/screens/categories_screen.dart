import 'package:flutter/material.dart';
import '../api_service.dart';
import 'notification_screen.dart';

class CategoriesScreen extends StatefulWidget {
  final bool showAppBar;
  const CategoriesScreen({super.key, this.showAppBar = false});

  @override
  CategoriesScreenState createState() => CategoriesScreenState();
}

class CategoriesScreenState extends State<CategoriesScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  List<dynamic> _budgets = [];

  static const List<Map<String, dynamic>> _catMeta = [
    {'name': 'Food',          'icon': Icons.restaurant,        'color': Color(0xFFFF7043)},
    {'name': 'Transport',     'icon': Icons.directions_car,    'color': Color(0xFF42A5F5)},
    {'name': 'Rent',          'icon': Icons.home,              'color': Color(0xFF26A69A)},
    {'name': 'Education',     'icon': Icons.school,            'color': Color(0xFF7E57C2)},
    {'name': 'Shopping',      'icon': Icons.shopping_bag,      'color': Color(0xFFAB47BC)},
    {'name': 'Health',        'icon': Icons.favorite,          'color': Color(0xFFEF5350)},
    {'name': 'Entertainment', 'icon': Icons.tv,                'color': Color(0xFF8D6E63)},
    {'name': 'Bills',         'icon': Icons.receipt_long,      'color': Color(0xFF78909C)},
    // SALARY CATEGORY REMOVED:
    // Salary category has been excluded from the metadata list to completely remove
    // its card from all list views, grid alignments, and categories selector UI.
    {'name': 'Other',         'icon': Icons.category,          'color': Color(0xFFFFCA28)},
  ];

  @override
  void initState() {
    super.initState();
    _fetchBudgets();
  }

  /// Called by MainScreen after chat sends a message
  void refresh() => _fetchBudgets();

  Future<void> _fetchBudgets() async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final res = await ApiService.get('/budgets?monthKey=$monthKey');
      if (!mounted) return;
      if (res['success'] == true) {
        final budgetsList = (res['data']?['budgets'] as List? ?? []);
        setState(() {
          // SALARY DATA FILTERING:
          // We filter out the 'Salary' category budget at the data layer. This guarantees
          // that even if 'Salary' budget limits/spent data exists in the backend database,
          // it will be excluded from all dashboard metric aggregations and budget lists.
          _budgets = budgetsList
              .where((b) => b['category']?.toString().toLowerCase() != 'salary')
              .toList();
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

  void _showSetBudgetDialog(String category, double currentLimit) {
    final controller = TextEditingController(text: currentLimit > 0 ? currentLimit.toInt().toString() : '');
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text('Set Budget – $category'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(labelText: 'Monthly Limit (Rs)', prefixIcon: Icon(Icons.currency_rupee)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final v = int.tryParse(controller.text.trim());
              if (v == null || v <= 0) return;
              Navigator.pop(ctx);
              await _setBudget(category, v);
            },
            style: ElevatedButton.styleFrom(backgroundColor: _primary),
            child: const Text('Save', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _setBudget(String category, int limit) async {
    try {
      final now = DateTime.now();
      final monthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';
      final res = await ApiService.post('/budgets', {
        'category': category,
        'limit': limit,
        'monthKey': monthKey,
        'alertThreshold': 80,
      });
      if (!mounted) return;
      if (res['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$category budget set to Rs $limit'), backgroundColor: Colors.green),
        );
        _fetchBudgets();
      }
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to set budget.'), backgroundColor: Colors.red),
      );
    }
  }

  // ── build display list (10 defaults + existing merged) ────────────────────
  List<Map<String, dynamic>> _buildDisplayList() {
    final budgetMap = {for (var b in _budgets) (b['category'] ?? ''): b};
    final list = <Map<String, dynamic>>[];
    for (final meta in _catMeta) {
      final name = meta['name'] as String;
      if (budgetMap.containsKey(name)) {
        list.add(budgetMap[name]!);
      } else {
        list.add({'category': name, 'limit': 0, 'spent': 0, 'notSet': true});
      }
    }
    return list;
  }

  // ── budget summary stats ──────────────────────────────────────────────────
  double get _totalLimit => _budgets.fold(0.0, (s, b) => s + (b['limit'] ?? 0).toDouble());
  double get _totalSpent => _budgets.fold(0.0, (s, b) => s + (b['spent'] ?? 0).toDouble());
  double get _netSavings => (_totalLimit - _totalSpent).clamp(0.0, double.infinity);
  double get _spentPercent => _totalLimit > 0 ? (_totalSpent / _totalLimit * 100) : 0;

  @override
  Widget build(BuildContext context) {
    final displayList = _buildDisplayList();

    // pair items for 2-column grid
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
        child: _isLoading && displayList.isEmpty
            ? const Center(child: CircularProgressIndicator(color: Color(0xFF2DBE7F)))
            : SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Total Budget banner ─────────────────────────────────
                    Container(
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAFAF3),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text('TOTAL MONTHLY BUDGET',
                                    style: TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 0.5)),
                                const SizedBox(height: 6),
                                Row(
                                  children: [
                                    Text(
                                      'Rs ${_totalSpent.toInt()}',
                                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: Colors.black87),
                                    ),
                                    Text(
                                      ' / Rs ${_totalLimit.toInt()}',
                                      style: const TextStyle(fontSize: 16, color: Colors.grey),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(
                                      _spentPercent > 100 ? Icons.warning_amber : Icons.check_circle_outline,
                                      color: _spentPercent > 100 ? Colors.red : _primary,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      _totalLimit > 0
                                          ? '${_spentPercent.toInt()}% of budget used'
                                          : 'No budgets set yet',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: _spentPercent > 100 ? Colors.red : _primary,
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                          Container(
                            width: 44, height: 44,
                            decoration: BoxDecoration(color: _primary.withValues(alpha: 0.15), shape: BoxShape.circle),
                            child: const Icon(Icons.trending_up, color: _primary, size: 22),
                          ),
                        ],
                      ),
                    ),

                    const SizedBox(height: 20),

                    // ── Spending Buckets header ─────────────────────────────
                    const Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('Spending Buckets', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                      ],
                    ),

                    const SizedBox(height: 8),

                    // ── 2-column grid ───────────────────────────────────────
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

                    const SizedBox(height: 8),

                    // ── Savings banner ──────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFFEAFAF3),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 40, height: 40,
                            decoration: BoxDecoration(color: _primary.withValues(alpha: 0.15), shape: BoxShape.circle),
                            child: const Icon(Icons.trending_up, color: _primary, size: 20),
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
                ),
              ),
      ),
    );
  }

  Widget _buildBucketCard(Map<String, dynamic> item) {
    final category = item['category'] ?? 'Unknown';
    final spent = (item['spent'] ?? 0).toDouble();
    final limit = (item['limit'] ?? 0).toDouble();
    final isNotSet = item['notSet'] == true || limit == 0;
    final percent = isNotSet ? 0.0 : (spent / limit).clamp(0.0, 2.0);
    final isOver = !isNotSet && percent > 1.0;
    final displayPercent = isNotSet ? 0.0 : (spent / limit).clamp(0.0, 1.0);

    final color = _catColor(category);
    final icon = _catIcon(category);
    final barColor = isOver ? Colors.red : (percent > 0.7 ? Colors.orange : _primary);

    return GestureDetector(
      onTap: () => _showSetBudgetDialog(category, limit),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 3))],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(10)),
                  child: Icon(icon, color: color, size: 20),
                ),
                if (!isNotSet)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: isOver ? Colors.red : Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '${(percent * 100).toInt()}%',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: isOver ? Colors.white : Colors.black54),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Text(category, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
            const SizedBox(height: 2),
            Text(
              isNotSet ? 'Not set – tap to add' : 'Rs ${spent.toInt()} / Rs ${limit.toInt()}',
              style: TextStyle(fontSize: 11, color: isOver ? Colors.red : Colors.grey),
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: displayPercent,
                minHeight: 5,
                backgroundColor: Colors.grey.shade200,
                color: barColor,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
