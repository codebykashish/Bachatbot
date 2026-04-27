import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final emailController = TextEditingController();
  final passController = TextEditingController();
  bool isLoading = false;
  bool obscurePassword = true;

  String? validateEmail(String? value) {
    if (value == null || value.isEmpty) return 'Email required';
    if (!RegExp(r'^[\w-\.]+@([gmail|yahoo|outlook|hotmail]+\.)+[a-zA-Z]{2,}$').hasMatch(value)) {
      return 'Enter valid email (e.g. gmail.com)';
    }
    return null;
  }

  String? validatePassword(String? value) {
    if (value == null || value.isEmpty) return 'Password required';
    if (value.length < 8) return 'Min 8 characters';
    if (!RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+$').hasMatch(value)) {
      return 'Upper, lower, number required';
    }
    return null;
  }

  Future<void> login() async {
    if (!mounted) return;

    final emailValid = validateEmail(emailController.text.trim());
    final passValid = validatePassword(passController.text.trim());

    if (emailValid != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(emailValid), backgroundColor: Colors.red));
      return;
    }
    if (passValid != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(passValid), backgroundColor: Colors.red));
      return;
    }

    setState(() => isLoading = true);

    try {
      print("LOGIN BUTTON PRESSED");

      await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: emailController.text.trim(),
        password: passController.text.trim(),
      );

      print("LOGIN SUCCESS");
      print("CURRENT USER: ${FirebaseAuth.instance.currentUser?.email}");

    } on FirebaseAuthException catch (e) {
      print("LOGIN ERROR: ${e.code}");
      String msg = "Login failed: ${e.message}";
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg), backgroundColor: Colors.red));
    } catch (e) {
      print("LOGIN ERROR: $e");
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red));
    }

    if (mounted) setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            children: [
              const SizedBox(height: 60),
              Icon(Icons.savings, size: 80, color: Colors.green),
              const SizedBox(height: 16),
              const Text("BachatBot", style: TextStyle(fontSize: 32, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text("Smart expense tracker", style: TextStyle(color: Colors.grey)),
              const SizedBox(height: 48),
              TextFormField(
                controller: emailController,
                keyboardType: TextInputType.emailAddress,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: InputDecoration(
                  labelText: "Email",
                  prefixIcon: const Icon(Icons.email_outlined),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  hintText: "test@bachatbot.com",
                ),
                validator: validateEmail,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: passController,
                obscureText: obscurePassword,
                autovalidateMode: AutovalidateMode.onUserInteraction,
                decoration: InputDecoration(
                  labelText: "Password",
                  prefixIcon: const Icon(Icons.lock_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(obscurePassword ? Icons.visibility : Icons.visibility_off),
                    onPressed: () => setState(() => obscurePassword = !obscurePassword),
                  ),
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                  hintText: "Min 8 chars + upper + lower + number",
                ),
                validator: validatePassword,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: isLoading ? null : login,
                  child: isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2),
                        )
                      : const Text("Login", style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => Navigator.pushNamed(context, '/signup'),
                child: const Text("Don't have account? Signup"),
              ),
            ],
          ),
        ),
      ),
    );
  }
}