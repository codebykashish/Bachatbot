import 'dart:math';
import 'package:flutter/material.dart';
import '../api_service.dart';
import 'categories_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isLoading = true;
  List<dynamic> _budgets = [];
  bool _isIncomeFlipped = false;
  bool _isExpenseFlipped = false;

  @override
  void initState() {
    super.initState();
    _fetchBudgets();
  }

  Future<void> _fetchBudgets() async {
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
      // Ignore or show error
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Widget _buildFlipCard({
    required String title,
    required IconData icon,
    required Color color,
    required String amountText,
    required bool isFlipped,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 400),
          transform: Matrix4.identity()
            ..setEntry(3, 2, 0.001)
            ..rotateY(isFlipped ? pi : 0),
          transformAlignment: Alignment.center,
          child: Container(
            height: 100,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: color.withOpacity(0.3)),
              boxShadow: [
                BoxShadow(
                  color: color.withOpacity(0.1),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            alignment: Alignment.center,
            child: isFlipped
                ? Transform(
                    transform: Matrix4.identity()..rotateY(pi),
                    alignment: Alignment.center,
                    child: Text(
                      amountText,
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  )
                : Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(icon, color: color, size: 32),
                      const SizedBox(height: 8),
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: color,
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: _fetchBudgets,
      child: SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              "Overview",
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _buildFlipCard(
                  title: "INCOME",
                  icon: Icons.arrow_upward,
                  color: const Color(0xFF2DBE7F),
                  amountText: "Rs 45,000",
                  isFlipped: _isIncomeFlipped,
                  onTap: () => setState(() => _isIncomeFlipped = !_isIncomeFlipped),
                ),
                const SizedBox(width: 16),
                _buildFlipCard(
                  title: "EXPENSE",
                  icon: Icons.arrow_downward,
                  color: Colors.redAccent,
                  amountText: "Rs 5,000",
                  isFlipped: _isExpenseFlipped,
                  onTap: () => setState(() => _isExpenseFlipped = !_isExpenseFlipped),
                ),
              ],
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  "Top Categories",
                  style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const CategoriesScreen(showAppBar: true)),
                    );
                  },
                  child: const Text(
                    "See All",
                    style: TextStyle(color: Color(0xFF2DBE7F), fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _budgets.isEmpty
                    ? const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16.0),
                          child: Text("No budgets set yet. Tap 'See All' to create one.", style: TextStyle(color: Colors.grey)),
                        ),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: _budgets.length > 5 ? 5 : _budgets.length,
                        itemBuilder: (context, index) {
                          final budget = _budgets[index];
                          final category = budget['category'] ?? 'Unknown';
                          final spent = (budget['spent'] ?? 0).toDouble();
                          final limit = (budget['limit'] ?? 1).toDouble();
                          final percent = (spent / limit).clamp(0.0, 1.0);

                          return Card(
                            elevation: 1,
                            margin: const EdgeInsets.only(bottom: 12),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                            child: Padding(
                              padding: const EdgeInsets.all(16.0),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                    children: [
                                      Text(
                                        category,
                                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                      ),
                                      Text(
                                        "Rs ${spent.toInt()} / Rs ${limit.toInt()}",
                                        style: const TextStyle(color: Colors.grey, fontSize: 14),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  LinearProgressIndicator(
                                    value: percent,
                                    backgroundColor: Colors.grey.shade200,
                                    color: percent > 0.9
                                        ? Colors.red
                                        : (percent > 0.7 ? Colors.orange : const Color(0xFF2DBE7F)),
                                    minHeight: 8,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ],
        ),
      ),
    );
  }
}
