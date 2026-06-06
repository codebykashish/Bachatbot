import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../models/onboarding_model.dart';

class FeaturePage extends StatelessWidget {
  final OnboardingModel model;

  const FeaturePage({
    super.key,
    required this.model,
  });

  @override
  Widget build(BuildContext context) {
    final mediaQuery = MediaQuery.of(context);
    final isLandscape = mediaQuery.orientation == Orientation.landscape;
    final screenHeight = mediaQuery.size.height;
    final screenWidth = mediaQuery.size.width;

    // Responsive circular container size
    final circleSize = isLandscape 
        ? screenHeight * 0.35 
        : screenWidth * 0.55;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Circular Container for Illustration / Icon
          Container(
            width: circleSize,
            height: circleSize,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 20,
                  spreadRadius: 2,
                  offset: const Offset(0, 10),
                ),
              ],
              border: Border.all(
                color: const Color(0xFF2DBD7F).withValues(alpha: 0.15),
                width: 2,
              ),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  Colors.white,
                  const Color(0xFF2DBD7F).withValues(alpha: 0.05),
                ],
              ),
            ),
            child: Center(
              child: model.assetPath != null
                  ? Image.asset(
                      model.assetPath!,
                      width: circleSize * 0.65,
                      height: circleSize * 0.65,
                      fit: BoxFit.contain,
                      errorBuilder: (context, error, stackTrace) {
                        // Fallback icon composition if asset fails to load
                        return _buildIconComposition(circleSize);
                      },
                    )
                  : _buildIconComposition(circleSize),
            ),
          ),
          SizedBox(height: screenHeight * 0.05),
          // Feature Title
          Text(
            model.title,
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: const Color(0xFF1B5E20), // Deep Green representing growth
              height: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          // Feature Description
          Text(
            model.description,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 16,
              color: Colors.grey.shade600,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // A creative, dynamic composite icon to visually represent each feature
  Widget _buildIconComposition(double size) {
    const iconColor = Color(0xFF2DBD7F);
    const accentColor = Color(0xFFFFB300); // Gold/Amber representing coins
    final iconSize = size * 0.45;

    // Feature-specific composition
    if (model.icon == Icons.chat_bubble_outline) {
      // Feature 1: AI Chatbot
      return Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.chat_bubble_rounded,
            size: iconSize,
            color: iconColor.withValues(alpha: 0.15),
          ),
          Positioned(
            right: size * 0.08,
            top: size * 0.08,
            child: Icon(
              Icons.support_agent_rounded,
              size: iconSize * 0.7,
              color: iconColor,
            ),
          ),
          Positioned(
            left: size * 0.1,
            bottom: size * 0.1,
            child: Icon(
              Icons.attach_money_rounded,
              size: iconSize * 0.6,
              color: accentColor,
            ),
          ),
        ],
      );
    } else if (model.icon == Icons.pie_chart_outline) {
      // Feature 2: Smart Budgets & Alerts
      return Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.pie_chart_rounded,
            size: iconSize,
            color: iconColor.withValues(alpha: 0.15),
          ),
          Positioned(
            left: size * 0.15,
            top: size * 0.15,
            child: Icon(
              Icons.donut_large_rounded,
              size: iconSize * 0.8,
              color: iconColor,
            ),
          ),
          Positioned(
            right: size * 0.05,
            bottom: size * 0.05,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: const BoxDecoration(
                color: Colors.white,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.notifications_active_rounded,
                size: iconSize * 0.5,
                color: accentColor,
              ),
            ),
          ),
        ],
      );
    } else {
      // Feature 3: Reports & Insights
      return Stack(
        alignment: Alignment.center,
        children: [
          Icon(
            Icons.analytics_outlined,
            size: iconSize,
            color: iconColor.withValues(alpha: 0.15),
          ),
          Icon(
            Icons.bar_chart_rounded,
            size: iconSize * 0.9,
            color: iconColor,
          ),
          Positioned(
            right: size * 0.1,
            top: size * 0.1,
            child: Icon(
              Icons.search_rounded,
              size: iconSize * 0.55,
              color: accentColor,
            ),
          ),
        ],
      );
    }
  }
}
