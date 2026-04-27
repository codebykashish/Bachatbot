import 'package:flutter/material.dart';
import '../api_service.dart';
import 'home_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final spend = TextEditingController();
  String occupation = "student";

  Future<void> save() async {
  try {
    await ApiService.patch("/profile", {
      "onboarding": {
        "isCompleted": true,
        "occupation": occupation,
        "housingType": "rent",
        "estimatedMonthlySpend": int.parse(spend.text)
      }
    });

    Navigator.pushReplacement(
        context, MaterialPageRoute(builder: (_) => const HomeScreen()));
  } catch (e) {
    print(e);
  }
}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(children: [
        const Text("Onboarding"),
        TextField(controller: spend, decoration: const InputDecoration(labelText: "Monthly Spend")),
        ElevatedButton(onPressed: save, child: const Text("Save"))
      ]),
    );
  }
}