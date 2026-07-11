import 'package:flutter/material.dart';

class BalanceCard extends StatelessWidget {
  final double unusedBudget;     // allocated to categories but not yet spent
  final double pureSavings;      // income never allocated to any category budget
  final bool isOverBudget;       // total spent across categories > total allocated
  final double spendingThisMonth;
  final double incomeThisMonth;
  final bool hideAmounts;
  final VoidCallback? onExpenseTap;
  final VoidCallback? onIncomeTap;

  const BalanceCard({
    super.key,
    required this.unusedBudget,
    required this.pureSavings,
    required this.isOverBudget,
    required this.spendingThisMonth,
    required this.incomeThisMonth,
    this.hideAmounts = false,
    this.onExpenseTap,
    this.onIncomeTap,
  });

  String _fmt(double amount) {
    if (hideAmounts) return '****';
    if (amount.abs() >= 100000) {
      return 'Rs ${(amount / 100000).toStringAsFixed(1)}L';
    }
    if (amount.abs() >= 1000) {
      return 'Rs ${(amount / 1000).toStringAsFixed(1)}k';
    }
    return 'Rs ${amount.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    final isZero = unusedBudget == 0 && incomeThisMonth > 0;

    return Column(
      children: [
        // ── Savings card ──────────────────────────────────────────────────
        Stack(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 22, 20, 28),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: isOverBudget
                      ? [const Color(0xFFD84040), const Color(0xFFFF7043)]
                      : [const Color(0xFF1B8B8E), const Color(0xFF2DBE7F)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isOverBudget
                            ? Icons.warning_amber_rounded
                            : Icons.savings_outlined,
                        color: Colors.white.withValues(alpha: 0.85),
                        size: 16,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        isOverBudget ? 'Over Budget' : 'Unused Budget',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontWeight: FontWeight.w500,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),
                  hideAmounts
                      ? const Text(
                          'Rs ****',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                            fontSize: 32,
                          ),
                        )
                      : isZero
                          ? const Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Rs 0',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 32,
                                  ),
                                ),
                                SizedBox(height: 4),
                                Text(
                                  'Keep tracking — savings start here! 💪',
                                  style: TextStyle(color: Colors.white70, fontSize: 12),
                                ),
                              ],
                            )
                          : Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  _fmt(unusedBudget),
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 32,
                                  ),
                                ),
                                if (isOverBudget) ...[
                                  const SizedBox(height: 4),
                                  const Text(
                                    'Spending has gone over your allocated budgets',
                                    style: TextStyle(color: Colors.white70, fontSize: 11),
                                  ),
                                ],
                              ],
                            ),
                ],
              ),
            ),
            // Decorative wave
            Positioned(
              bottom: 0,
              right: 0,
              child: CustomPaint(
                size: const Size(150, 60),
                painter: _WavePainter(),
              ),
            ),
            // Pure savings — income never allocated to any category budget.
            if (!hideAmounts)
              Positioned(
                bottom: 12,
                right: 16,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      'Savings',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.75),
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    Text(
                      _fmt(pureSavings),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),

        const SizedBox(height: 16),

        // ── Income / Expense row ──────────────────────────────────────────
        Row(
          children: [
            // Income card (LEFT) — tappable → IncomePage
            Expanded(
              child: _MiniCard(
                label: 'Total Income',
                amount: _fmt(incomeThisMonth),
                icon: Icons.account_balance_wallet_outlined,
                iconColor: const Color(0xFF1B8B8E),
                onTap: onIncomeTap,
              ),
            ),
            const SizedBox(width: 14),
            // Expense card (RIGHT) — tappable → Activity
            Expanded(
              child: _MiniCard(
                label: 'Expense',
                amount: _fmt(spendingThisMonth),
                icon: Icons.trending_down_rounded,
                iconColor: const Color(0xFFD85E5E),
                onTap: onExpenseTap,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _MiniCard extends StatelessWidget {
  final String label;
  final String amount;
  final IconData icon;
  final Color iconColor;
  final VoidCallback? onTap;

  const _MiniCard({
    required this.label,
    required this.amount,
    required this.icon,
    required this.iconColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.07),
              blurRadius: 10,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 38, height: 38,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(height: 10),
            Text(
              label,
              style: const TextStyle(fontSize: 11, color: Colors.grey, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 4),
            Text(
              amount,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: iconColor,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            if (onTap != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Text(
                      'View',
                      style: TextStyle(fontSize: 10, color: iconColor.withValues(alpha: 0.7)),
                    ),
                    Icon(Icons.chevron_right, size: 12, color: iconColor.withValues(alpha: 0.7)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.12)
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, size.height * 0.5);
    path.quadraticBezierTo(
      size.width * 0.25, size.height * 0.2,
      size.width * 0.5, size.height * 0.5,
    );
    path.quadraticBezierTo(
      size.width * 0.75, size.height * 0.8,
      size.width, size.height * 0.5,
    );
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_WavePainter old) => false;
}
