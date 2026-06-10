import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../api_service.dart';
import '../widgets/shared_widgets.dart';
import '../widgets/chat_fab.dart';

class CategoryDetailPage extends StatefulWidget {
  final String category;
  final double budgetLimit;
  final double budgetSpent;

  const CategoryDetailPage({
    super.key,
    required this.category,
    this.budgetLimit = 0,
    this.budgetSpent = 0,
  });

  @override
  State<CategoryDetailPage> createState() => _CategoryDetailPageState();
}

class _CategoryDetailPageState extends State<CategoryDetailPage> {
  static const Color _primary = Color(0xFF2DBE7F);

  late double _budgetLimit;
  late double _budgetSpent;

  String _timeFilter = 'all';
  List<dynamic> _alerts = [];
  bool _isLoadingAlerts = false;
  bool _isSaving = false;
  bool _showBudgetError = false;

  final _amountController = TextEditingController();
  final _noteController = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  static const List<Map<String, String>> _timeFilters = [
    {'label': 'All Time',   'value': 'all'},
    {'label': 'Today',      'value': 'today'},
    {'label': 'Yesterday',  'value': 'yesterday'},
    {'label': 'This Week',  'value': 'week'},
  ];

  @override
  void initState() {
    super.initState();
    _budgetLimit = widget.budgetLimit;
    _budgetSpent = widget.budgetSpent;
    _fetchAlerts();
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  String _computeStatus() {
    if (_budgetLimit <= 0) return 'ok';
    final pct = _budgetSpent / _budgetLimit * 100;
    if (pct > 100) return 'overspent';
    if (pct >= 80) return 'warning';
    if (pct >= 50) return 'ok';
    return 'low';
  }

  Future<void> _fetchAlerts() async {
    setState(() => _isLoadingAlerts = true);
    try {
      final cat = Uri.encodeComponent(widget.category);
      final endpoint = '/alerts?type=expense&category=$cat'
          '${_timeFilter != 'all' ? '&dateRange=$_timeFilter' : ''}';
      final res = await ApiService.get(endpoint);
      if (!mounted) return;
      if (res['success'] == true) {
        final raw = res['data']?['alerts'] ?? res['data'] ?? [];
        final sorted = List<dynamic>.from(raw);
        sorted.sort((a, b) {
          final da = a['createdAt'] ?? a['date'] ?? '';
          final db = b['createdAt'] ?? b['date'] ?? '';
          return db.toString().compareTo(da.toString());
        });
        setState(() => _alerts = sorted);
      }
    } catch (e) {
      debugPrint('[CategoryDetailPage] fetchAlerts error: $e');
    } finally {
      if (mounted) setState(() => _isLoadingAlerts = false);
    }
  }

  Future<void> _saveExpense() async {
    if (_budgetLimit == 0) {
      setState(() => _showBudgetError = true);
      return;
    }

    setState(() => _showBudgetError = false);

    if (!_formKey.currentState!.validate()) return;
    FocusScope.of(context).unfocus();
    setState(() => _isSaving = true);

    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in');

      final amount = double.parse(_amountController.text.trim());
      final note = _noteController.text.trim();

      final res = await ApiService.post('/transactions/manual', {
        'category': widget.category,
        'amount': amount,
        if (note.isNotEmpty) 'note': note,
      });

      if (!mounted) return;

      if (res['success'] == true) {
        final budgetUpdate = res['data']?['budgetUpdate'];
        if (budgetUpdate != null) {
          setState(() {
            _budgetLimit = (budgetUpdate['limit'] ?? _budgetLimit).toDouble();
            _budgetSpent = (budgetUpdate['spent'] ?? _budgetSpent).toDouble();
          });
        } else {
          setState(() => _budgetSpent += amount);
        }
        _amountController.clear();
        _noteController.clear();
        await _fetchAlerts();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Rs ${amount.toInt()} added to ${widget.category}'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        final msg = res['message'] ?? res['detail']?['message'] ?? 'Failed to save';
        throw Exception(msg);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  void _showBudgetBottomSheet() {
    final controller = TextEditingController(
      text: _budgetLimit > 0 ? _budgetLimit.toInt().toString() : '',
    );
    final sheetFormKey = GlobalKey<FormState>();

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => Padding(
        padding: EdgeInsets.only(
          left: 16,
          right: 16,
          top: 16,
          bottom: MediaQuery.of(ctx).viewInsets.bottom + 24,
        ),
        child: StatefulBuilder(
          builder: (_, setSheet) {
            bool isSaving = false;
            return Form(
              key: sheetFormKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Center(
                    child: Container(
                      width: 40,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Set Budget — ${widget.category}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: 'Monthly Limit (Rs)',
                      prefixText: 'Rs ',
                      prefixStyle: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w500, fontSize: 15),
                      border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8)),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            const BorderSide(color: Colors.green, width: 2),
                      ),
                      filled: true,
                      fillColor: Colors.grey.shade50,
                    ),
                    validator: (v) {
                      final val = double.tryParse(v?.trim() ?? '');
                      if (val == null || val <= 0) {
                        return 'Enter a valid amount';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  StatefulBuilder(
                    builder: (_, setSaveBtn) => SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: isSaving
                            ? null
                            : () async {
                                if (!sheetFormKey.currentState!.validate()) {
                                  return;
                                }
                                setSaveBtn(() => isSaving = true);
                                try {
                                  final now = DateTime.now();
                                  final monthKey =
                                      '${now.year}-${now.month.toString().padLeft(2, '0')}';
                                  final newLimit = double.parse(
                                      controller.text.trim());
                                  final res = await ApiService.post(
                                    '/budgets',
                                    {
                                      'category': widget.category,
                                      'limit': newLimit,
                                      'monthKey': monthKey,
                                      'alertThreshold': 80,
                                    },
                                  );
                                  if (!ctx.mounted) return;
                                  if (res['success'] == true) {
                                    final bd = res['data']?['budget'] ??
                                        res['data'];
                                    setState(() {
                                      _budgetLimit = (bd?['limit'] ??
                                              newLimit)
                                          .toDouble();
                                      if (bd?['spent'] != null) {
                                        _budgetSpent =
                                            (bd['spent']).toDouble();
                                      }
                                      _showBudgetError = false;
                                    });
                                    Navigator.pop(ctx);
                                    if (mounted) {
                                      ScaffoldMessenger.of(context)
                                          .showSnackBar(SnackBar(
                                        content: Text(
                                            '${widget.category} budget set to Rs ${_budgetLimit.toInt()}'),
                                        backgroundColor: Colors.green,
                                      ));
                                    }
                                  } else {
                                    setSaveBtn(() => isSaving = false);
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                        SnackBar(
                                      content: Text(res['message'] ??
                                          'Failed to set budget'),
                                      backgroundColor: Colors.red,
                                    ));
                                  }
                                } catch (e) {
                                  setSaveBtn(() => isSaving = false);
                                  if (ctx.mounted) {
                                    ScaffoldMessenger.of(ctx).showSnackBar(
                                        SnackBar(
                                      content: Text('Error: $e'),
                                      backgroundColor: Colors.red,
                                    ));
                                  }
                                }
                              },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.green,
                          foregroundColor: Colors.white,
                          minimumSize: const Size(double.infinity, 48),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10)),
                          elevation: 0,
                        ),
                        child: isSaving
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              )
                            : const Text('Set Budget',
                                style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold)),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ── Sections ──────────────────────────────────────────────────────────────

  Widget _buildBudgetCard() {
    final pct = _budgetLimit > 0
        ? (_budgetSpent / _budgetLimit * 100).clamp(0, 999).toInt()
        : 0;
    final barValue = (pct / 100).clamp(0.0, 1.0);
    final status = _computeStatus();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Monthly Budget',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
              const Spacer(),
              TextButton(
                onPressed: _showBudgetBottomSheet,
                style: _showBudgetError
                    ? TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: Colors.green,
                        backgroundColor: Colors.green.shade50,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                          side: const BorderSide(color: Colors.green),
                        ),
                      )
                    : TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        foregroundColor: Colors.green,
                      ),
                child: Text(
                  _budgetLimit == 0 ? 'Set Budget' : 'Edit',
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (_budgetLimit > 0) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  'Rs ${_budgetSpent.toInt()}',
                  style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.bold,
                      color: Colors.grey.shade800),
                ),
                Text(
                  ' / Rs ${_budgetLimit.toInt()}',
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: barValue,
                minHeight: 8,
                backgroundColor: Colors.grey.shade100,
                valueColor:
                    AlwaysStoppedAnimation<Color>(progressColor(status)),
              ),
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                statusBadge(status),
                const Spacer(),
                Text(
                  '$pct% used',
                  style: TextStyle(
                      fontSize: 12, color: progressColor(status)),
                ),
              ],
            ),
          ] else ...[
            Row(
              children: [
                Icon(Icons.info_outline,
                    size: 16, color: Colors.grey.shade400),
                const SizedBox(width: 6),
                Text('No budget set',
                    style: TextStyle(
                        fontSize: 13, color: Colors.grey.shade400)),
                const Spacer(),
                TextButton(
                  onPressed: _showBudgetBottomSheet,
                  style: TextButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    foregroundColor: Colors.green,
                  ),
                  child: const Text('Set Budget',
                      style: TextStyle(fontSize: 13)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAddExpenseSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Add Expense',
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade200),
          ),
          child: Form(
            key: _formKey,
            child: Column(
              children: [
                // Amount field
                TextFormField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                      decimal: true),
                  decoration: InputDecoration(
                    labelText: 'Amount (Rs)',
                    prefixText: 'Rs ',
                    prefixStyle: TextStyle(color: Colors.grey.shade700, fontWeight: FontWeight.w500, fontSize: 15),
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Colors.grey.shade200)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Colors.grey.shade200)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Colors.green, width: 2)),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                  ),
                  validator: (v) {
                    final val = double.tryParse(v?.trim() ?? '');
                    if (val == null || val <= 0) {
                      return 'Enter a valid amount';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                // Note field
                TextFormField(
                  controller: _noteController,
                  maxLength: 100,
                  decoration: InputDecoration(
                    labelText: 'Note (optional)',
                    hintText: 'e.g. Lunch at canteen',
                    prefixIcon: const Icon(Icons.edit_note_outlined,
                        size: 18),
                    counterText: '',
                    border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Colors.grey.shade200)),
                    enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide:
                            BorderSide(color: Colors.grey.shade200)),
                    focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: const BorderSide(
                            color: Colors.green, width: 2)),
                    filled: true,
                    fillColor: Colors.grey.shade50,
                  ),
                ),
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _isSaving ? null : _saveExpense,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.green,
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 48),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                      elevation: 0,
                    ),
                    child: _isSaving
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2),
                          )
                        : const Text('Save Expense',
                            style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildRecentActivity() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent Activity',
          style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.grey.shade800),
        ),
        const SizedBox(height: 10),
        // Time filter chips
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: _timeFilters.map((f) {
              return Padding(
                padding: const EdgeInsets.only(right: 8),
                child: buildChoiceChip(
                  label: f['label']!,
                  selected: _timeFilter == f['value'],
                  onTap: () {
                    if (_timeFilter == f['value']!) return;
                    setState(() => _timeFilter = f['value']!);
                    _fetchAlerts();
                  },
                ),
              );
            }).toList(),
          ),
        ),
        const SizedBox(height: 12),
        if (_isLoadingAlerts)
          const Center(
              child: Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: CircularProgressIndicator(color: _primary),
          ))
        else if (_alerts.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 32),
              child: Column(
                children: [
                  Icon(categoryIcon(widget.category),
                      size: 48, color: Colors.grey.shade200),
                  const SizedBox(height: 8),
                  Text(
                    'No ${widget.category} expenses yet',
                    style: TextStyle(
                        fontSize: 14, color: Colors.grey.shade400),
                  ),
                ],
              ),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: _alerts.length,
            itemBuilder: (_, i) => AlertCard(
              alert: _alerts[i] as Map<String, dynamic>,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: Text(
          widget.category,
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        leading: Padding(
          padding: const EdgeInsets.all(8),
          child: CircleAvatar(
            backgroundColor: Colors.green.shade50,
            child: Icon(categoryIcon(widget.category),
                color: Colors.green, size: 20),
          ),
        ),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Divider(height: 1, color: Colors.grey.shade100),
        ),
      ),
      body: RefreshIndicator(
        color: _primary,
        onRefresh: _fetchAlerts,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildBudgetCard(),
              if (_showBudgetError) ...[
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.red.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.red.shade300, width: 1),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline_rounded, size: 16, color: Colors.red.shade600),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          "Please set a budget for ${widget.category} before "
                          "adding an expense.",
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.red.shade700,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 20),
              _buildAddExpenseSection(),
              const SizedBox(height: 24),
              _buildRecentActivity(),
            ],
          ),
        ),
      ),
      floatingActionButton: const ChatFab(),
    );
  }
}
