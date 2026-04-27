import 'package:flutter/material.dart';
import '../api_service.dart';
import 'home_screen.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  String? occupation;
  String? housingType;
  final spendController = TextEditingController();

  Future<void> complete() async {
    try {
      await ApiService.patch("/profile", {
        "onboarding": {
          "isCompleted": true,
          "occupation": occupation ?? "student",
          "housingType": housingType ?? "rent",
          "estimatedMonthlySpend": int.tryParse(spendController.text) ?? 15000,
        }
      });
      print("Onboarding complete");
    } catch (e) {
      print("Onboarding error: $e");
    }

    Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const HomeScreen()));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Setup BachatBot")),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            DropdownButtonFormField<String>(
              value: occupation,
              hint: const Text("Occupation"),
              items: ["student", "employed", "business", "freelance"].map((e) => DropdownMenuItem(value: e, child: Text(e))).toList(),
              onChanged: (v) => setState(() => occupation = v),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: housingType,
              hint: const Text("Housing"),
              items: ["rent", "own", "hostel", "family"].map((e) => DropdownMenuItem(value: e, child: Text(e.capitalize()))).toList(),
              onChanged: (v) => setState(() => housingType = v),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: spendController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: "Estimated Monthly Spend (Rs)",
                prefixText: "Rs ",
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: complete,
              style: ElevatedButton.styleFrom(minimumSize: const Size(double.infinity, 52)),
              child: const Text("Complete Setup", style: TextStyle(fontSize: 16)),
            ),
          ],
        ),
      ),
    );
  }
}

// Extension for capitalize
extension StringExtension on String {
  String capitalize() {
    return "${this[0].toUpperCase()}${substring(1)}";
  }
}