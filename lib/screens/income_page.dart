import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../api_service.dart';
import '../widgets/shared_widgets.dart';
import 'activity_feed_screen.dart';

class IncomePage extends StatefulWidget {
  const IncomePage({super.key});

  @override
  State<IncomePage> createState() => _IncomePageState();
}

class _IncomePageState extends State<IncomePage> {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _isLoading = true;
  double _inHand = 0;
  double _inBank = 0;
  double _onlineBanking = 0;
  double _totalBudgeted = 0;

  // Edit mode for each source
  bool _editingInHand = false;
  bool _editingInBank = false;
  bool _editingOnline = false;

  final _inHandCtrl = TextEditingController();
  final _inBankCtrl = TextEditingController();
  final _onlineCtrl = TextEditingController();

  // Add income panel
  String _addSource = 'inHand';
  final _addAmountCtrl = TextEditingController();
  bool _isAdding = false;

  double _totalSpent = 0;

  // Income history
  List<dynamic> _incomeAlerts = [];
  bool _isLoadingHistory = false;

  double get _total => _inHand + _inBank + _onlineBanking;
  double get _unallocated => _total - _totalBudgeted;

  @override
  void initState() {
    super.initState();
    _fetchData();
  }

  @override
  void dispose() {
    _inHandCtrl.dispose();
    _inBankCtrl.dispose();
    _onlineCtrl.dispose();
    _addAmountCtrl.dispose();
    super.dispose();
  }

  Future<void> _fetchData() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        ApiService.get('/income'),
        ApiService.get('/budgets?monthKey=${_currentMonthKey()}'),
        ApiService.get('/monthly-report?monthKey=${_currentMonthKey()}'),
      ]);

      final incomeRes = results[0];
      final budgetRes = results[1];
      final reportRes = results[2];

      if (!mounted) return;
      setState(() {
        if (incomeRes['success'] == true) {
          final d = incomeRes['data'];
          _inHand = (d['inHand'] ?? 0).toDouble();
          _inBank = (d['inBank'] ?? 0).toDouble();
          _onlineBanking = (d['onlineBanking'] ?? 0).toDouble();
        }
        if (budgetRes['success'] == true) {
          final budgets = (budgetRes['data']?['budgets'] as List? ?? []);
          _totalBudgeted = budgets.fold(
            0.0,
            (sum, b) => sum + (b['limit'] ?? 0).toDouble(),
          );
        }
        if (reportRes['success'] == true) {
          final d = reportRes['data'];
          _totalSpent = ((d?['totalExpense'] ?? d?['expense'] ?? 0)).toDouble();
        }
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Failed to load income data.'), behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
    await _fetchIncomeHistory();
  }

  Future<void> _fetchIncomeHistory() async {
    setState(() => _isLoadingHistory = true);
    try {
      final res = await ApiService.get('/alerts?type=income');
      if (!mounted) return;
      if (res['success'] == true) {
        final raw = List<dynamic>.from(res['data']?['alerts'] ?? []);
        raw.sort((a, b) {
          final da = (a['createdAt'] ?? '').toString();
          final db = (b['createdAt'] ?? '').toString();
          return db.compareTo(da);
        });
        setState(() => _incomeAlerts = raw);
      }
    } catch (e) {
      debugPrint('[IncomePage] fetchIncomeHistory error: $e');
    } finally {
      if (mounted) setState(() => _isLoadingHistory = false);
    }
  }

  Future<void> _undoIncomeAlert(Map<String, dynamic> alert) async {
    final id = (alert['id'] ?? '') as String;
    if (id.isEmpty) return;
    final delta = (alert['incomeDelta'] as num?)?.toDouble() ??
        (alert['amount'] as num?)?.toDouble() ?? 0;
    final source = (alert['incomeSource'] as String?) ?? '';

    // Optimistic update
    setState(() {
      _incomeAlerts.remove(alert);
      if (source == 'inHand') _inHand = (_inHand - delta).clamp(0, double.infinity);
      if (source == 'inBank') _inBank = (_inBank - delta).clamp(0, double.infinity);
      if (source == 'onlineBanking') _onlineBanking = (_onlineBanking - delta).clamp(0, double.infinity);
    });

    try {
      final res = await ApiService.post('/alerts/$id/undo', {});
      if (mounted) {
        final msg = (res['message'] as String?) ?? 'Income entry reversed.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: Colors.orange.shade700,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      debugPrint('[IncomePage] undo error: $e');
      await _fetchData();
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

  String _currentMonthKey() {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  Future<void> _saveSource(String field, double newValue) async {
    final newInHand = field == 'inHand' ? newValue : _inHand;
    final newInBank = field == 'inBank' ? newValue : _inBank;
    final newOnline = field == 'onlineBanking' ? newValue : _onlineBanking;
    final newTotal = newInHand + newInBank + newOnline;

    if (_totalBudgeted > 0 && newTotal < _totalBudgeted) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Your total budget allocation is Rs ${_totalBudgeted.toInt()}. Cannot decrease income below that. Remove or reduce a category budget first.',
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return;
    }

    if (_totalSpent > 0 && newTotal < _totalSpent) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'You have already spent Rs ${_totalSpent.toInt()} this month. Income cannot be set below that amount.',
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 4),
          ),
        );
      }
      return;
    }

    try {
      await ApiService.post('/income', {field: newValue});
      await _fetchData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Income updated.'),
            backgroundColor: _primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Update failed: $e'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating),
        );
      }
    }
  }

  Future<void> _addIncome() async {
    final amount = double.tryParse(_addAmountCtrl.text.trim()) ?? 0;
    if (amount <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please enter a valid amount greater than 0.'),
          backgroundColor: Colors.redAccent,
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    setState(() => _isAdding = true);
    try {
      double newInHand = _inHand;
      double newInBank = _inBank;
      double newOnline = _onlineBanking;

      switch (_addSource) {
        case 'inHand':
          newInHand += amount;
          break;
        case 'inBank':
          newInBank += amount;
          break;
        case 'onlineBanking':
          newOnline += amount;
          break;
      }

      await ApiService.post('/income', {
        'inHand': newInHand,
        'inBank': newInBank,
        'onlineBanking': newOnline,
      });
      _addAmountCtrl.clear();
      await _fetchData();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Rs ${amount.toInt()} added to ${_sourceLabel(_addSource)}.'),
            backgroundColor: _primary,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: $e'), backgroundColor: Colors.red, behavior: SnackBarBehavior.floating),
        );
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

  String _sourceLabel(String key) {
    switch (key) {
      case 'inHand':
        return 'In Hand';
      case 'inBank':
        return 'In Bank';
      case 'onlineBanking':
        return 'Online Banking';
      default:
        return key;
    }
  }

  Widget _buildIncomeHistory() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Income History',
          style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
        ),
        const SizedBox(height: 12),
        if (_isLoadingHistory)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: CircularProgressIndicator(color: _primary),
            ),
          )
        else if (_incomeAlerts.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 28),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.grey.shade100),
            ),
            child: Column(
              children: [
                Icon(Icons.account_balance_wallet_outlined, size: 40, color: Colors.grey.shade200),
                const SizedBox(height: 8),
                Text(
                  'No income entries yet',
                  style: TextStyle(fontSize: 14, color: Colors.grey.shade400),
                ),
              ],
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: _incomeAlerts.length,
            itemBuilder: (_, i) {
              final alert = _incomeAlerts[i] as Map<String, dynamic>;
              final incomeDelta = (alert['incomeDelta'] as num?)?.toDouble() ?? 0;
              return TransactionCard(
                item: alert,
                isIncome: true,
                onUndo: (i == 0 && incomeDelta > 0) ? () => _undoIncomeAlert(alert) : null,
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
        title: const Text('My Income', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0.5,
        actions: [
          IconButton(
            icon: const Icon(Icons.notifications_none),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const ActivityFeedScreen(initialFilter: 'transactions')),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator(color: _primary))
          : RefreshIndicator(
              color: _primary,
              onRefresh: _fetchData,
              child: SingleChildScrollView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Total income summary card ────────────────────────
                    _buildTotalCard(),
                    const SizedBox(height: 20),

                    // ── Source breakdown ────────────────────────────────
                    const Text(
                      'Income Sources',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.black87),
                    ),
                    const SizedBox(height: 12),
                    _sourceCard(
                      label: 'Cash in Hand',
                      value: _inHand,
                      icon: Icons.wallet_outlined,
                      color: const Color(0xFF2DBE7F),
                      field: 'inHand',
                      isEditing: _editingInHand,
                      ctrl: _inHandCtrl,
                      onEdit: () => setState(() {
                        _editingInHand = true;
                        _inHandCtrl.text = _inHand.toInt().toString();
                      }),
                      onSave: () async {
                        final v = double.tryParse(_inHandCtrl.text) ?? _inHand;
                        setState(() => _editingInHand = false);
                        await _saveSource('inHand', v);
                      },
                      onCancel: () => setState(() => _editingInHand = false),
                    ),
                    const SizedBox(height: 10),
                    _sourceCard(
                      label: 'In Bank Account',
                      value: _inBank,
                      icon: Icons.account_balance_outlined,
                      color: const Color(0xFF1B8B8E),
                      field: 'inBank',
                      isEditing: _editingInBank,
                      ctrl: _inBankCtrl,
                      onEdit: () => setState(() {
                        _editingInBank = true;
                        _inBankCtrl.text = _inBank.toInt().toString();
                      }),
                      onSave: () async {
                        final v = double.tryParse(_inBankCtrl.text) ?? _inBank;
                        setState(() => _editingInBank = false);
                        await _saveSource('inBank', v);
                      },
                      onCancel: () => setState(() => _editingInBank = false),
                    ),
                    const SizedBox(height: 10),
                    _sourceCard(
                      label: 'Online Banking (eSewa / Khalti)',
                      value: _onlineBanking,
                      icon: Icons.phone_android_outlined,
                      color: const Color(0xFF7E57C2),
                      field: 'onlineBanking',
                      isEditing: _editingOnline,
                      ctrl: _onlineCtrl,
                      onEdit: () => setState(() {
                        _editingOnline = true;
                        _onlineCtrl.text = _onlineBanking.toInt().toString();
                      }),
                      onSave: () async {
                        final v = double.tryParse(_onlineCtrl.text) ?? _onlineBanking;
                        setState(() => _editingOnline = false);
                        await _saveSource('onlineBanking', v);
                      },
                      onCancel: () => setState(() => _editingOnline = false),
                    ),

                    const SizedBox(height: 24),

                    // ── Add income section ──────────────────────────────
                    _buildAddIncomeSection(),
                    const SizedBox(height: 24),

                    // ── Income history ───────────────────────────────────
                    _buildIncomeHistory(),
                  ],
                ),
              ),
            ),
    );
  }

  Widget _buildTotalCard() {
    final unalloc = _unallocated;
    final isFullyAllocated = _total > 0 && unalloc <= 0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF1B8B8E), Color(0xFF2DBE7F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Total Income',
            style: TextStyle(color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 10),
          Text(
            'Rs ${_total.toInt()}',
            style: const TextStyle(color: Colors.white, fontSize: 34, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  isFullyAllocated ? Icons.check_circle_outline : Icons.savings_outlined,
                  color: Colors.white,
                  size: 16,
                ),
                const SizedBox(width: 6),
                Text(
                  isFullyAllocated
                      ? 'All income allocated to budgets'
                      : 'Rs ${unalloc.toInt()} available to save',
                  style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sourceCard({
    required String label,
    required double value,
    required IconData icon,
    required Color color,
    required String field,
    required bool isEditing,
    required TextEditingController ctrl,
    required VoidCallback onEdit,
    required Future<void> Function() onSave,
    required VoidCallback onCancel,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 8, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: [
          Container(
            width: 44, height: 44,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(11)),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                const SizedBox(height: 4),
                isEditing
                    ? SizedBox(
                        height: 36,
                        child: TextField(
                          controller: ctrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          autofocus: true,
                          inputFormatters: [
                            FilteringTextInputFormatter.digitsOnly,
                            LengthLimitingTextInputFormatter(7),
                          ],
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                          decoration: InputDecoration(
                            prefixText: 'Rs ',
                            contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                            focusedBorder: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(8),
                              borderSide: BorderSide(color: color, width: 1.5),
                            ),
                          ),
                        ),
                      )
                    : Text(
                        'Rs ${value.toInt()}',
                        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Colors.black87),
                      ),
              ],
            ),
          ),
          if (isEditing) ...[
            IconButton(
              icon: const Icon(Icons.check_circle, color: _primary, size: 26),
              onPressed: onSave,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 6),
            IconButton(
              icon: Icon(Icons.cancel_outlined, color: Colors.grey.shade400, size: 24),
              onPressed: onCancel,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
          ] else
            IconButton(
              icon: Icon(Icons.edit_outlined, color: Colors.grey.shade400, size: 20),
              onPressed: onEdit,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
        ],
      ),
    );
  }

  Widget _buildAddIncomeSection() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 10, offset: const Offset(0, 3))],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.add_circle_outline, color: _primary, size: 20),
              SizedBox(width: 8),
              Text('Add Income', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold, color: Colors.black87)),
            ],
          ),
          const SizedBox(height: 4),
          const Text(
            'Add money received to a specific source.',
            style: TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 16),

          // Source selector
          Row(
            children: [
              _sourceChip('inHand', 'In Hand', const Color(0xFF2DBE7F)),
              const SizedBox(width: 8),
              _sourceChip('inBank', 'In Bank', const Color(0xFF1B8B8E)),
              const SizedBox(width: 8),
              _sourceChip('onlineBanking', 'Online', const Color(0xFF7E57C2)),
            ],
          ),
          const SizedBox(height: 14),

          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _addAmountCtrl,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(7),
                  ],
                  decoration: InputDecoration(
                    prefixText: 'Rs  ',
                    hintText: 'Amount',
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(color: Colors.grey.shade200),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: const BorderSide(color: _primary, width: 1.5),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              SizedBox(
                height: 48,
                child: ElevatedButton(
                  onPressed: _isAdding ? null : _addIncome,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _primary,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                  ),
                  child: _isAdding
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                      : const Text('Add', style: TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _sourceChip(String value, String label, Color color) {
    final selected = _addSource == value;
    return GestureDetector(
      onTap: () => setState(() => _addSource = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: 0.12) : Colors.grey.shade100,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: selected ? color : Colors.grey.shade200, width: selected ? 1.5 : 1),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? color : Colors.grey.shade600,
          ),
        ),
      ),
    );
  }
}
