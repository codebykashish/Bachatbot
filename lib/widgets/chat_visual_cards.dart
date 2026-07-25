import 'package:flutter/material.dart';

// ─── Visual Models ─────────────────────────────────────────────────────────

class VisualPayload {
  final String type;
  final Map<String, dynamic> data;

  VisualPayload({required this.type, required this.data});

  factory VisualPayload.fromJson(Map<String, dynamic> json) {
    return VisualPayload(
      type: json['type'] as String? ?? 'unknown',
      data: json,
    );
  }
}

// ─── Widget Dispatcher ─────────────────────────────────────────────────────

class ChatVisualCard extends StatelessWidget {
  final VisualPayload payload;

  const ChatVisualCard({super.key, required this.payload});

  @override
  Widget build(BuildContext context) {
    switch (payload.type) {
      case 'budget_summary':
        return BudgetSummaryCard(data: payload.data);
      case 'daily_spend':
        return DailySpendCard(data: payload.data);
      case 'spending_chart':
        return SpendingChartCard(data: payload.data);
      case 'budget_alert':
        return BudgetAlertCard(data: payload.data);
      default:
        return const SizedBox.shrink(); // Fallback for unknown visual types
    }
  }
}

// ─── 1. Budget Summary Card ────────────────────────────────────────────────

class BudgetSummaryCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const BudgetSummaryCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final budgets = (data['budgets'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final insight = data['insight'] as String?;
    final totalSpent = data['totalSpent'] ?? 0;
    final unallocated = data['unallocated'] ?? 0;
    final daysRemaining = data['daysRemaining'] ?? 0;

    return Container(
      margin: const EdgeInsets.only(left: 42, bottom: 10, right: 16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6E8EE)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: const BoxDecoration(
              color: Color(0xFFF9FAFB),
              borderRadius: BorderRadius.vertical(top: Radius.circular(14)),
              border: Border(bottom: BorderSide(color: Color(0xFFE6E8EE))),
            ),
            child: Row(
              children: [
                const Text('💰', style: TextStyle(fontSize: 16)),
                const SizedBox(width: 8),
                const Text(
                  'Your Budget Status',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF22252A),
                  ),
                ),
                const Spacer(),
                Text(
                  '$daysRemaining days left',
                  style: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
          
          // Budgets List
          if (budgets.isNotEmpty)
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                children: budgets.map((b) {
                  final cat = b['category'] ?? '';
                  final limit = b['limit'] ?? 0;
                  final spent = b['spent'] ?? 0;
                  final remaining = b['remaining'] ?? 0;
                  final pct = (b['percentUsed'] as num?)?.toDouble() ?? 0.0;
                  
                  final isOver = spent > limit;
                  final isTight = pct >= 90;
                  final barColor = isOver ? Colors.red : (isTight ? Colors.orange : const Color(0xFF2DBE7F));

                  return Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Text(
                              cat,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                            ),
                            Text(
                              'Rs $remaining left',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: isOver ? Colors.red : (isTight ? Colors.orange : Colors.grey[700]),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        Row(
                          children: [
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(4),
                                child: LinearProgressIndicator(
                                  value: limit > 0 ? (spent / limit).clamp(0.0, 1.0) : 0.0,
                                  minHeight: 8,
                                  backgroundColor: const Color(0xFFE6E8EE),
                                  valueColor: AlwaysStoppedAnimation<Color>(barColor),
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            SizedBox(
                              width: 36,
                              child: Text(
                                '${pct.round()}%',
                                textAlign: TextAlign.right,
                                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Colors.grey),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            )
          else
            const Padding(
              padding: EdgeInsets.all(20),
              child: Center(
                child: Text('No budgets set for this month.', style: TextStyle(color: Colors.grey, fontSize: 13)),
              ),
            ),
            
          // Summary Footer
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFE6E8EE))),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Total Spent', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(height: 2),
                    Text('Rs $totalSpent', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold)),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Unallocated', style: TextStyle(fontSize: 11, color: Colors.grey)),
                    const SizedBox(height: 2),
                    Text('Rs $unallocated', style: const TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Color(0xFF2DBE7F))),
                  ],
                ),
              ],
            ),
          ),
          
          // Insight
          if (insight != null && insight.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.08),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
              ),
              child: Text(
                insight,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFE08A00),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─── 2. Daily Spend Card ───────────────────────────────────────────────────

class DailySpendCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const DailySpendCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final dailySpend = data['recommendedDailySpend'] ?? 0;
    final daysRemaining = data['daysRemaining'] ?? 0;
    final tightestCategory = data['tightestCategory'] as String?;
    
    return Container(
      margin: const EdgeInsets.only(left: 42, bottom: 10, right: 16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF22252A), Color(0xFF32363E)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(
              children: [
                const Text(
                  '💡 Safe Daily Spend',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white70),
                ),
                const SizedBox(height: 12),
                Text(
                  'Rs $dailySpend',
                  style: const TextStyle(fontSize: 32, fontWeight: FontWeight.w800, color: Colors.white),
                ),
                const Text(
                  'per day',
                  style: TextStyle(fontSize: 13, color: Colors.white54, fontWeight: FontWeight.w500),
                ),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    'Stay around Rs $dailySpend/day for the next $daysRemaining days to remain within your budget.',
                    textAlign: TextAlign.center,
                    style: const TextStyle(fontSize: 12, color: Colors.white70, height: 1.4),
                  ),
                ),
              ],
            ),
          ),
          if (tightestCategory != null && tightestCategory.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.orange.withOpacity(0.15),
                borderRadius: const BorderRadius.vertical(bottom: Radius.circular(14)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orangeAccent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'Be careful with $tightestCategory spending.',
                      style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.orangeAccent),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

// ─── 3. Spending Chart Card ────────────────────────────────────────────────

class SpendingChartCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const SpendingChartCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final chartData = (data['data'] as List?)?.cast<Map<String, dynamic>>() ?? [];
    final totalSpent = data['totalSpent'] ?? 0;
    
    // We will render a simplified bar chart using standard widgets
    return Container(
      margin: const EdgeInsets.only(left: 42, bottom: 10, right: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFE6E8EE)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Spending Breakdown',
                style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF22252A)),
              ),
              Text(
                'Total: Rs $totalSpent',
                style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Color(0xFF2DBE7F)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (chartData.isEmpty)
            const Center(
              child: Padding(
                padding: EdgeInsets.all(16.0),
                child: Text('No spending this month yet.', style: TextStyle(color: Colors.grey)),
              ),
            )
          else
            Column(
              children: chartData.map((d) {
                final cat = d['category'] ?? '';
                final spent = d['spent'] ?? 0;
                
                // Calculate percentage relative to total spent
                final pctOfTotal = totalSpent > 0 ? (spent / totalSpent) : 0.0;
                
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 75,
                        child: Text(
                          cat,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: pctOfTotal,
                            minHeight: 8,
                            backgroundColor: const Color(0xFFE6E8EE),
                            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF2DBE7F)),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 60,
                        child: Text(
                          'Rs $spent',
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.grey),
                        ),
                      ),
                    ],
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }
}

// ─── 4. Budget Alert Card ──────────────────────────────────────────────────

class BudgetAlertCard extends StatelessWidget {
  final Map<String, dynamic> data;

  const BudgetAlertCard({super.key, required this.data});

  @override
  Widget build(BuildContext context) {
    final unallocated = data['unallocated'] ?? 0;
    
    return Container(
      margin: const EdgeInsets.only(left: 42, bottom: 10, right: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF1F0), // Light red
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.red.withOpacity(0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: Colors.red, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Budget cannot be set',
                  style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, color: Colors.red),
                ),
                const SizedBox(height: 6),
                Text(
                  'You only have Rs $unallocated unallocated income remaining. Please adjust your budget limit to stay within your total income.',
                  style: TextStyle(fontSize: 12.5, color: Colors.red[800], height: 1.4),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
