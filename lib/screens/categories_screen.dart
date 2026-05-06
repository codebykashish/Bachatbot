import 'package:flutter/material.dart';
import '../api_service.dart';

class CategoriesScreen extends StatefulWidget {
  final bool showAppBar;
  const CategoriesScreen({super.key, this.showAppBar = false});

  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}

class _CategoriesScreenState extends State<CategoriesScreen> {
  bool _isLoading = true;
  List<dynamic> _budgets = [];

  final List<String> _defaultCategories = [
    "Food", "Transport", "Rent", "Education", "Shopping", 
    "Health", "Entertainment", "Bills", "Other"
  ];

  @override
  void initState() {
    super.initState();
    _fetchBudgets();
  }

  Future<void> _fetchBudgets() async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      final monthKey = "${now.year}-${now.month.toString().padLeft(2, '0')}";
      final response = await ApiService.get('/budgets?monthKey=$monthKey');
      if (!mounted) return;
      if (response['success'] == true) {
        setState(() {
          _budgets = response['data']?['budgets'] ?? [];
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

  IconData _getIconForCategory(String category) {
    switch (category) {
      case "Food": return Icons.fastfood;
      case "Transport": return Icons.directions_car;
      case "Rent": return Icons.home;
      case "Education": return Icons.school;
      case "Shopping": return Icons.shopping_bag;
      case "Health": return Icons.medical_services;
      case "Entertainment": return Icons.movie;
      case "Bills": return Icons.receipt;
      default: return Icons.category;
    }
  }

  void _showSetBudgetDialog(String category, double currentLimit) {
    final controller = TextEditingController(text: currentLimit > 0 ? currentLimit.toInt().toString() : "");

    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: Text('Set Budget for $category'),
          content: TextField(
            controller: controller,
            keyboardType: TextInputType.number,
            decoration: const InputDecoration(
              labelText: 'Monthly Limit (Rs)',
              prefixIcon: Icon(Icons.currency_rupee),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final limitStr = controller.text.trim();
                if (limitStr.isEmpty) return;
                final limit = int.tryParse(limitStr);
                if (limit == null || limit <= 0) return;

                Navigator.pop(context); // close dialog
                await _setBudget(category, limit);
              },
              style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF2DBE7F)),
              child: const Text('Save', style: TextStyle(color: Colors.white)),
            ),
          ],
        );
      },
    );
  }

  Future<void> _setBudget(String category, int limit) async {
    setState(() => _isLoading = true);
    try {
      final now = DateTime.now();
      final monthKey = "${now.year}-${now.month.toString().padLeft(2, '0')}";
      
      final response = await ApiService.post('/budgets', {
        'category': category,
        'limit': limit,
        'monthKey': monthKey,
        'alertThreshold': 80,
      });

      if (!mounted) return;
      if (response['success'] == true) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('$category budget set to Rs $limit'), backgroundColor: Colors.green),
        );
        _fetchBudgets();
      } else {
        throw Exception();
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Failed to set budget.'), backgroundColor: Colors.red),
      );
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Map existing budgets by category
    final Map<String, dynamic> budgetMap = {
      for (var b in _budgets) b['category']: b
    };

    // Prepare list to show
    final List<Map<String, dynamic>> displayList = [];
    
    // Add existing budgets
    for (var b in _budgets) {
      displayList.add(b);
    }

    // Add defaults if they don't exist
    for (var cat in _defaultCategories) {
      if (!budgetMap.containsKey(cat)) {
        displayList.add({
          'category': cat,
          'limit': 0,
          'spent': 0,
          'notSet': true,
        });
      }
    }

    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(
              title: const Text('Categories & Budgets', style: TextStyle(fontWeight: FontWeight.bold)),
              backgroundColor: Colors.white,
              foregroundColor: Colors.black,
              elevation: 0,
            )
          : null,
      backgroundColor: const Color(0xFFF6F7F9),
      body: RefreshIndicator(
        onRefresh: _fetchBudgets,
        child: _isLoading && displayList.isEmpty
            ? const Center(child: CircularProgressIndicator())
            : ListView.builder(
                padding: const EdgeInsets.all(16.0),
                itemCount: displayList.length,
                itemBuilder: (context, index) {
                  final item = displayList[index];
                  final category = item['category'] ?? 'Unknown';
                  final spent = (item['spent'] ?? 0).toDouble();
                  final limit = (item['limit'] ?? 0).toDouble();
                  final isNotSet = item['notSet'] == true || limit == 0;
                  final percent = isNotSet ? 0.0 : (spent / limit).clamp(0.0, 1.0);

                  return Card(
                    elevation: 1,
                    margin: const EdgeInsets.only(bottom: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(16),
                      onTap: () => _showSetBudgetDialog(category, limit),
                      child: Padding(
                        padding: const EdgeInsets.all(16.0),
                        child: Row(
                          children: [
                            Container(
                              width: 50,
                              height: 50,
                              decoration: BoxDecoration(
                                color: const Color(0xFFE8F8F1),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Icon(_getIconForCategory(category), color: const Color(0xFF2DBE7F)),
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    category,
                                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    isNotSet ? "Not set" : "Rs ${spent.toInt()} / Rs ${limit.toInt()}",
                                    style: TextStyle(
                                      fontSize: 14, 
                                      color: isNotSet ? Colors.orange : Colors.grey,
                                      fontWeight: isNotSet ? FontWeight.bold : FontWeight.normal,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (!isNotSet)
                              SizedBox(
                                width: 40,
                                height: 40,
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    CircularProgressIndicator(
                                      value: percent,
                                      strokeWidth: 4,
                                      backgroundColor: Colors.grey.shade200,
                                      color: percent > 0.9
                                          ? Colors.red
                                          : (percent > 0.7 ? Colors.orange : const Color(0xFF2DBE7F)),
                                    ),
                                    Center(
                                      child: Text(
                                        "${(percent * 100).toInt()}%",
                                        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
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
                },
              ),
      ),
    );
  }
}
