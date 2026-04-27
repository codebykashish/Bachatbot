import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../api_service.dart';

class SignupScreen extends StatefulWidget {
  const SignupScreen({super.key});

  @override
  State<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends State<SignupScreen> {
  final first = TextEditingController();
  final last = TextEditingController();
  final email = TextEditingController();
  final pass = TextEditingController();
  bool isLoading = false;

  @override
  void dispose() {
    first.dispose();
    last.dispose();
    email.dispose();
    pass.dispose();
    super.dispose();
  }

  Future<void> signup() async {
    if (!mounted) return;
    setState(() => isLoading = true);

    try {
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email.text.trim(),
        password: pass.text.trim(),
      );

      await ApiService.post("/complete-signup", {
        "firstName": first.text.trim(),
        "lastName": last.text.trim(),
        "email": email.text.trim(),
        "phone": "",
      });

      print("SIGNUP SUCCESS");

      // ✅ FIXED: Use routes instead of pop
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/login');
      }

    } on FirebaseAuthException catch (e) {
      print("SIGNUP ERROR: ${e.code}");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(e.message ?? "Signup failed"), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      print("SIGNUP ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e"), backgroundColor: Colors.red),
        );
      }
    }

    if (mounted) setState(() => isLoading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Create Account")),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            children: [
              TextField(
                controller: first,
                decoration: const InputDecoration(
                  labelText: "First Name",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: last,
                decoration: const InputDecoration(
                  labelText: "Last Name",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: email,
                decoration: const InputDecoration(
                  labelText: "Email",
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: pass,
                decoration: const InputDecoration(
                  labelText: "Password",
                  border: OutlineInputBorder(),
                ),
                obscureText: true,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  onPressed: isLoading ? null : signup,
                  child: isLoading
                      ? const CircularProgressIndicator(color: Colors.white)
                      : const Text("Create Account"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}