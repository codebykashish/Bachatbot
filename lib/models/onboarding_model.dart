import 'package:flutter/material.dart';

class OnboardingModel {
  final String title;
  final String description;
  final IconData icon;
  final String? assetPath;

  const OnboardingModel({
    required this.title,
    required this.description,
    required this.icon,
    this.assetPath,
  });
}

class OnboardingStrings {
  // Splash Screen
  static const String appName = "Bachatbot";
  static const String splashTagline = "Know your kharcha(spending), grow your bachat(savings)";

  // Get Started Screen
  static const String getStartedTitle = "Take Control of Your Money";
  static const String getStartedSubtitle = "Track every rupee with the power of AI. Just chat, and we handle the rest.";
  static const String getStartedButton = "Get Started →";
  static const String alreadyHaveAccount = "Already have an account? Sign In";

  // Feature 1
  static const String feature1Title = "Chat to Track";
  static const String feature1Desc = "Just say 'Spent 500 on food' and our AI logs it instantly. No forms, no hassle.";

  // Feature 2
  static const String feature2Title = "Smart Budget Alerts";
  static const String feature2Desc = "Set monthly limits for each category. Get instant alerts when you're about to overspend.";

  // Feature 3
  static const String feature3Title = "Weekly & Monthly Reports";
  static const String feature3Desc = "Get clear summaries of your income vs expenses. Know exactly where your money goes.";

  // Button text
  static const String skip = "Skip";
  static const String next = "Next →";
  static const String letsGo = "Let's Go! 🚀";
}

