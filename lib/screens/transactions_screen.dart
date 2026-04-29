import 'package:flutter/material.dart';
import '../api_service.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  List<dynamic> _transactions = [];
  bool _isLoading = true;
  String _selectedType = 'all';

  // Get current month key e.g. "2026-04"
  String get _currentMonthKey {
    final now = DateTime.now();
    return '${now.year}-${now.month.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _isLoading = true);
    try {
      String endpoint = '/transactions?monthKey=$_currentMonthKey';
      if (_selectedType != 'all') {
        endpoint += '&type=$_selectedType';
      }

      final response = await ApiService.get(endpoint);
      if (!mounted) return;

      setState(() {
        _transactions =
            response['data']?['transactions'] as List? ?? [];
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Failed to load transactions: $e'),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _deleteTransaction(String id, int index) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Transaction'),
        content:
            const Text('Are you sure you want to delete this transaction?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ApiService.delete('/transactions/$id');
      if (!mounted) return;
      setState(() => _transactions.removeAt(index));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Transaction deleted'),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e')),
      );
    }
  }

  // Summary calculations
  double get _totalExpense => _transactions
      .where((t) =>
          t['type'] == 'expense' && t['status'] == 'confirmed')
      .fold(0.0, (sum, t) => sum + (t['amount'] ?? 0));

  double get _totalIncome => _transactions
      .where((t) =>
          t['type'] == 'income' && t['status'] == 'confirmed')
      .fold(0.0, (sum, t) => sum + (t['amount'] ?? 0));

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _load,
      child: CustomScrollView(
        slivers: [
          // Summary Card
          SliverToBoxAdapter(
            child: _buildSummaryCard(),
          ),

          // Filter Row
          SliverToBoxAdapter(
            child: _buildFilterRow(),
          ),

          // Transactions List
          if (_isLoading)
            const SliverFillRemaining(
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_transactions.isEmpty)
            SliverFillRemaining(
              child: _buildEmptyState(),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) {
                  final t = _transactions[index];
                  return _buildTransactionItem(t, index);
                },
                childCount: _transactions.length,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard() {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2E7D32), Color(0xFF43A047)],
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This Month',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Income',
                      style:
                          TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      'Rs ${_totalIncome.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Expense',
                      style:
                          TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      'Rs ${_totalExpense.toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Savings',
                      style:
                          TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    Text(
                      'Rs ${(_totalIncome - _totalExpense).toStringAsFixed(0)}',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFilterRow() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          const Text(
            'Transactions',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 16,
            ),
          ),
          const Spacer(),
          _filterChip('all', 'All'),
          const SizedBox(width: 8),
          _filterChip('expense', 'Expense'),
          const SizedBox(width: 8),
          _filterChip('income', 'Income'),
        ],
      ),
    );
  }

  Widget _filterChip(String value, String label) {
    final isSelected = _selectedType == value;
    return GestureDetector(
      onTap: () {
        if (_selectedType != value) {
          setState(() => _selectedType = value);
          _load();
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF2E7D32)
              : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.white : Colors.grey.shade700,
            fontSize: 12,
            fontWeight:
                isSelected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  Widget _buildTransactionItem(Map<String, dynamic> t, int index) {
    final isExpense = t['type'] == 'expense';
    final isPending = t['status'] == 'pending';
    final amount = t['amount'] ?? 0;
    final category = t['category'] ?? '';
    final description = t['description'] ?? '';
    final source = t['source'] ?? '';
    final id = t['id'] ?? '';

    return Dismissible(
      key: Key(id),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.red.shade100,
        child: const Icon(Icons.delete, color: Colors.red),
      ),
      confirmDismiss: (direction) async {
        await _deleteTransaction(id, index);
        return false; // We handle removal manually
      },
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: isExpense
              ? Colors.red.shade50
              : Colors.green.shade50,
          child: Icon(
            isExpense ? Icons.arrow_downward : Icons.arrow_upward,
            color: isExpense ? Colors.red : Colors.green,
            size: 20,
          ),
        ),
        title: Row(
          children: [
            Text(
              category,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            if (isPending) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.orange.shade100,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Pending',
                  style: TextStyle(
                    fontSize: 10,
                    color: Colors.orange,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
            if (source == 'notification') ...[
              const SizedBox(width: 4),
              Icon(
                Icons.notifications_outlined,
                size: 14,
                color: Colors.blue.shade300,
              ),
            ],
          ],
        ),
        subtitle: Text(
          description,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              '${isExpense ? '-' : '+'}Rs $amount',
              style: TextStyle(
                color: isExpense ? Colors.red : Colors.green,
                fontWeight: FontWeight.bold,
                fontSize: 15,
              ),
            ),
          ],
        ),
        onLongPress: () => _deleteTransaction(id, index),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.receipt_long_outlined,
              size: 72, color: Colors.grey.shade300),
          const SizedBox(height: 16),
          const Text(
            'No transactions yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: Colors.grey,
            ),
          ),
          const Text(
            'Start chatting to log your expenses!',
            style: TextStyle(color: Colors.grey),
          ),
        ],
      ),
    );
  }
}