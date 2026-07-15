import 'package:flutter/material.dart';
import '../services/financial_status_service.dart';

/// A subtle, smoky vignette painted above every screen (via MaterialApp's
/// `builder`), signaling overall spending health without touching any
/// individual screen's Scaffold. Ignores touches — purely atmospheric.
///
/// Deliberately muted/desaturated ("smoky"), not a flat saturated color
/// block — a soft radial haze that thickens toward the edges and stays
/// mostly transparent at the center where content is read.
class AmbientStatusOverlay extends StatelessWidget {
  const AmbientStatusOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<FinancialStatus>(
      valueListenable: FinancialStatusService().status,
      builder: (context, status, _) {
        if (status == FinancialStatus.safe) return const SizedBox.shrink();

        final bool isDanger = status == FinancialStatus.overspent;

        // Smoky, desaturated hues — a muted maroon-charcoal haze for
        // danger, a muted amber-charcoal haze for caution. Never a bright
        // saturated red/yellow. Covers the full page (not just edges) so
        // it's clearly noticeable, while staying translucent enough that
        // text/cards underneath stay readable.
        final Color top = isDanger ? const Color(0xFF6B3A3A) : const Color(0xFF7A6438);
        final Color bottom = isDanger ? const Color(0xFF2A1D1E) : const Color(0xFF2A2318);

        return IgnorePointer(
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 700),
            opacity: 1,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    top.withValues(alpha: isDanger ? 0.22 : 0.16),
                    bottom.withValues(alpha: isDanger ? 0.30 : 0.22),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
