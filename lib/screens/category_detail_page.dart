import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  double _declaredIncome = 0.0;
  double _totalAllocated = 0.0;
  double _otherUnspentBuffer = 0.0;

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
    _fetchBudgetMeta();
  }

  Future<void> _fetchBudgetMeta() async {
    try {
      final results = await Future.wait([
        ApiService.get('/income'),
        ApiService.get('/budgets'),
      ]);
      if (!mounted) return;
      final incomeData = results[0];
      final budgetsData = results[1];
      if (incomeData['success'] == true) {
        final d = incomeData['data'] as Map<String, dynamic>? ?? {};
        final income = (d['inHand'] ?? 0).toDouble() +
            (d['inBank'] ?? 0).toDouble() +
            (d['onlineBanking'] ?? 0).toDouble();
        final budgets = (budgetsData['data']?['budgets'] as List<dynamic>?) ?? [];
        double totalAllocated = 0;
        double otherBuffer = 0;
        Map<String, dynamic>? thisBudget;
        for (final b in budgets) {
          final bLimit = (b['limit'] ?? 0).toDouble();
          totalAllocated += bLimit;
          if ((b['category'] as String?) == widget.category) {
            thisBudget = b as Map<String, dynamic>;
          } else {
            final bSpent = (b['spent'] ?? 0).toDouble();
            otherBuffer += (bLimit - bSpent).clamp(0.0, double.infinity);
          }
        }
        setState(() {
          _declaredIncome = income;
          _totalAllocated = totalAllocated;
          _otherUnspentBuffer = otherBuffer;
          // Update limit/spent from API so navigation from any screen works correctly
          if (thisBudget != null) {
            _budgetLimit = (thisBudget['limit'] ?? _budgetLimit).toDouble();
            _budgetSpent = (thisBudget['spent'] ?? _budgetSpent).toDouble();
          }
        });
      }
    } catch (_) {}
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

    final rawAmount = double.tryParse(_amountController.text.trim()) ?? 0;
    if (rawAmount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid amount (greater than 0).'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

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

  Future<void> _undoAlert(Map<String, dynamic> alert) async {
    final id = (alert['id'] ?? '') as String;
    if (id.isEmpty) return;
    final amount = (alert['amount'] as num?)?.toDouble() ?? 0;

    // Optimistic update
    setState(() {
      _alerts.remove(alert);
      _budgetSpent = (_budgetSpent - amount).clamp(0, double.infinity);
    });

    try {
      final res = await ApiService.post('/alerts/$id/undo', {});
      if (mounted) {
        final msg = (res['message'] as String?) ?? 'Expense removed.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.orange.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[CategoryDetailPage] undo error: $e');
      await Future.wait([_fetchAlerts(), _fetchBudgetMeta()]);
      if (mounted) {
        final errorStr = e.toString();
        String displayMsg = 'Undo failed. Please try again.';
        try {
          final match = RegExp(r'"message"\s*:\s*"([^"]+)"').firstMatch(errorStr);
          if (match != null) displayMsg = match.group(1)!;
        } catch (_) {}
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(displayMsg),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    }
  }

  Future<void> _showBudgetBottomSheet() async {
    // If income data hasn't loaded yet, wait for it now so the hint is always visible
    if (_declaredIncome == 0) {
      await _fetchBudgetMeta();
    }
    if (!mounted) return;

    final controller = TextEditingController(
      text: _budgetLimit > 0 ? _budgetLimit.toInt().toString() : '',
    );
    final sheetFormKey = GlobalKey<FormState>();
    // When editing, the current category's budget is freed up → add it back to available.
    // Also include unused buffer from other categories (backend can rebalance them).
    final available = _declaredIncome > 0
        ? (_declaredIncome - _totalAllocated + _budgetLimit + _otherUnspentBuffer).clamp(0.0, double.infinity)
        : double.infinity;

    // Declare outside StatefulBuilder so they survive rebuilds
    bool isSaving = false;
    String? inlineError;

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
                    '${_budgetLimit > 0 ? 'Edit' : 'Set'} Budget — ${widget.category}',
                    style: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  if (available != double.infinity) ...[
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Icon(
                          Icons.account_balance_wallet_outlined,
                          size: 14,
                          color: available > 0 ? _primary : Colors.orange,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            available <= 0
                                ? 'No budget available to allocate'
                                : _otherUnspentBuffer > 0
                                    ? 'Up to Rs ${available.toInt()} available (incl. Rs ${_otherUnspentBuffer.toInt()} unused from other categories)'
                                    : 'Rs ${available.toInt()} unallocated',
                            style: TextStyle(
                              fontSize: 12,
                              color: available > 0 ? _primary : Colors.orange,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: controller,
                    keyboardType: TextInputType.number,
                    autofocus: true,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(7),
                    ],
                    onChanged: (val) {
                      final v = double.tryParse(val);
                      if (v != null && _budgetSpent > 0 && v < _budgetSpent) {
                        setSheet(() => inlineError =
                            'Cannot be less than amount already spent (Rs ${_budgetSpent.toInt()})');
                      } else if (available != double.infinity && v != null && v > available) {
                        setSheet(() => inlineError = 'Exceeds available Rs ${available.toInt()}');
                      } else {
                        setSheet(() => inlineError = null);
                      }
                    },
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
                      errorText: inlineError,
                      errorStyle: const TextStyle(fontSize: 11),
                    ),
                    validator: (v) {
                      final val = double.tryParse(v?.trim() ?? '');
                      if (val == null || val <= 0) {
                        return 'Enter a valid amount';
                      }
                      if (_budgetSpent > 0 && val < _budgetSpent) {
                        return 'Cannot be less than amount already spent (Rs ${_budgetSpent.toInt()})';
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  StatefulBuilder(
                    builder: (_, setSaveBtn) => SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: isSaving || inlineError != null
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
                                    final rebalanced = (res['data']?['rebalanced'] as List?) ?? [];
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
                                    _fetchBudgetMeta();
                                    if (mounted) {
                                      if (rebalanced.isNotEmpty) {
                                        final cats = rebalanced
                                            .map((r) => r['category'])
                                            .join(', ');
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(SnackBar(
                                          content: Text(
                                              '${widget.category} budget set. Other budgets adjusted to fit: $cats.'),
                                          backgroundColor: Colors.orange.shade700,
                                          duration: const Duration(seconds: 4),
                                          behavior: SnackBarBehavior.floating,
                                        ));
                                      } else {
                                        ScaffoldMessenger.of(context)
                                            .showSnackBar(SnackBar(
                                          content: Text(
                                              '${widget.category} budget set to Rs ${_budgetLimit.toInt()}'),
                                          backgroundColor: Colors.green,
                                        ));
                                      }
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
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.grey.shade100),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 8, offset: const Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Monthly Budget',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade500, fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              // Prominent pill button — visible even on first open
              GestureDetector(
                onTap: _showBudgetBottomSheet,
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _primary.withValues(alpha: 0.25)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.edit_outlined, size: 12, color: _primary),
                      const SizedBox(width: 4),
                      Text(
                        _budgetLimit == 0 ? 'Set Budget' : 'Edit',
                        style: TextStyle(fontSize: 12, color: _primary, fontWeight: FontWeight.w600),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (_budgetLimit > 0) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  'Rs ${_budgetSpent.toInt()}',
                  style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: progressColor(status)),
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
                minHeight: 7,
                backgroundColor: Colors.grey.shade100,
                valueColor: AlwaysStoppedAnimation<Color>(progressColor(status)),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                statusBadge(status),
                const Spacer(),
                Text(
                  '$pct% used',
                  style: TextStyle(fontSize: 12, color: progressColor(status)),
                ),
              ],
            ),
          ] else ...[
            // "No budget set" — clear, tappable CTA so first-time users know what to do
            GestureDetector(
              onTap: _showBudgetBottomSheet,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 14),
                decoration: BoxDecoration(
                  color: _primary.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _primary.withValues(alpha: 0.20), width: 1),
                ),
                child: Column(
                  children: [
                    Icon(Icons.add_circle_outline_rounded, size: 24, color: _primary),
                    const SizedBox(height: 6),
                    Text(
                      'Set a monthly budget limit',
                      style: TextStyle(fontSize: 13, color: _primary, fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Track how much you spend on ${widget.category}',
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildAddExpenseSection() {
    final inputBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: Colors.grey.shade200),
    );
    const focusedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.all(Radius.circular(10)),
      borderSide: BorderSide(color: _primary, width: 1.5),
    );

    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Add Expense',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: Colors.grey.shade800),
          ),
          const SizedBox(height: 12),
          // Amount field — large, prominent, no redundant label
          TextFormField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
              LengthLimitingTextInputFormatter(9),
            ],
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            decoration: InputDecoration(
              hintText: 'e.g. 250',
              hintStyle: TextStyle(fontSize: 16, color: Colors.grey.shade300, fontWeight: FontWeight.w600),
              prefixText: 'Rs  ',
              prefixStyle: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Colors.grey.shade700),
              suffixText: 'NPR',
              suffixStyle: TextStyle(fontSize: 12, color: Colors.grey.shade400),
              filled: true,
              fillColor: Colors.grey.shade50,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              border: inputBorder,
              enabledBorder: inputBorder,
              focusedBorder: focusedBorder,
              errorStyle: const TextStyle(fontSize: 11),
            ),
            validator: (v) {
              final val = double.tryParse(v?.trim() ?? '');
              if (val == null || val <= 0) return 'Enter a valid amount';
              return null;
            },
          ),
          const SizedBox(height: 10),
          // Note field — compact, subtle
          TextFormField(
            controller: _noteController,
            maxLength: 100,
            style: TextStyle(fontSize: 14, color: Colors.grey.shade800),
            decoration: InputDecoration(
              hintText: 'Add a note  (optional)',
              hintStyle: TextStyle(fontSize: 13, color: Colors.grey.shade400),
              prefixIcon: Icon(Icons.notes_outlined, size: 16, color: Colors.grey.shade400),
              counterText: '',
              filled: true,
              fillColor: Colors.grey.shade50,
              contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
              border: inputBorder,
              enabledBorder: inputBorder,
              focusedBorder: focusedBorder,
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isSaving ? null : _saveExpense,
              style: ElevatedButton.styleFrom(
                backgroundColor: _primary,
                foregroundColor: Colors.white,
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 0,
              ),
              child: _isSaving
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                  : const Text('Save Expense', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
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
            itemBuilder: (_, i) {
              final alert = _alerts[i] as Map<String, dynamic>;
              return TransactionCard(
                item: alert,
                isIncome: false,
                onUndo: i == 0 ? () => _undoAlert(alert) : null,
              );
            },
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 30, height: 30,
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(categoryIcon(widget.category), color: Colors.green, size: 16),
            ),
            const SizedBox(width: 10),
            Text(widget.category, style: const TextStyle(fontWeight: FontWeight.bold)),
          ],
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
