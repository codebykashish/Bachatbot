import 'package:flutter/material.dart';

class BalanceCard extends StatelessWidget {
  final double currentBalance;
  final double spendingThisMonth;
  final double incomeThisMonth;
  final bool hideAmounts;
  final VoidCallback? onExpenseTap;
  final VoidCallback? onIncomeTap;

  const BalanceCard({
    super.key,
    required this.currentBalance,
    required this.spendingThisMonth,
    required this.incomeThisMonth,
    this.hideAmounts = false,
    this.onExpenseTap,
    this.onIncomeTap,
  });

  String _formatAmount(double amount) {
    if (hideAmounts) return 'Rs ****';
    return 'Rs ${amount.toStringAsFixed(0)}';
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        // Current Balance Card with wave pattern
        Stack(
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [
                    Color(0xFF1B8B8E),
                    Color(0xFF2DBE7F),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Current Balance',
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                        ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    _formatAmount(currentBalance),
                    style: Theme.of(context).textTheme.displaySmall?.copyWith(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 32,
                        ),
                  ),
                ],
              ),
            ),
            // Wave decoration (bottom right)
            Positioned(
              bottom: 0,
              right: 0,
              child: CustomPaint(
                size: const Size(150, 60),
                painter: WavePainter(),
              ),
            ),
            // Decorative dots
            Positioned(
              bottom: 25,
              right: 30,
              child: Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.3),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),
        // Income and Expense Cards Row (swapped: Income LEFT, Expense RIGHT)
        Row(
          children: [
            // ── Income Card (LEFT) ──────────────────────────────────────
            Expanded(
              child: MouseRegion(
                cursor: onIncomeTap != null
                    ? SystemMouseCursors.click
                    : MouseCursor.defer,
                child: GestureDetector(
                  onTap: onIncomeTap,
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: const Color(0xFF1B8B8E).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.account_balance_wallet,
                            color: Color(0xFF1B8B8E),
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Income this\nMonth',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF5A5A5A),
                                fontWeight: FontWeight.w500,
                                fontSize: 12,
                                height: 1.4,
                              ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _formatAmount(incomeThisMonth),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: const Color(0xFF1B8B8E),
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            // ── Expense Card (RIGHT) ────────────────────────────────────
            Expanded(
              child: MouseRegion(
                cursor: onExpenseTap != null
                    ? SystemMouseCursors.click
                    : MouseCursor.defer,
                child: GestureDetector(
                  onTap: onExpenseTap,
                  child: Container(
                    padding: const EdgeInsets.all(18),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(16),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.08),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            color: const Color(0xFFD85E5E).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: const Icon(
                            Icons.trending_down,
                            color: Color(0xFFD85E5E),
                            size: 28,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          'Expense this\nMonth',
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                color: const Color(0xFF5A5A5A),
                                fontWeight: FontWeight.w500,
                                fontSize: 12,
                                height: 1.4,
                              ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _formatAmount(spendingThisMonth),
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                color: const Color(0xFFD85E5E),
                                fontWeight: FontWeight.bold,
                                fontSize: 18,
                              ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// Custom wave painter for bottom right decoration
class WavePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;

    final path = Path();
    path.moveTo(0, size.height * 0.5);
    path.quadraticBezierTo(
      size.width * 0.25,
      size.height * 0.2,
      size.width * 0.5,
      size.height * 0.5,
    );
    path.quadraticBezierTo(
      size.width * 0.75,
      size.height * 0.8,
      size.width,
      size.height * 0.5,
    );
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(WavePainter oldDelegate) => false;
}
