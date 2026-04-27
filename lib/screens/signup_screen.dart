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
  final confirmPass = TextEditingController();
  bool isLoading = false;
  bool obscurePass = true;
  bool obscureConfirm = true;
  String passwordStrength = '';
  Color strengthColor = Colors.red;

  @override
  void initState() {
    super.initState();
    pass.addListener(checkPasswordStrength);
  }

  @override
  void dispose() {
    first.dispose();
    last.dispose();
    email.dispose();
    pass.dispose();
    confirmPass.dispose();
    super.dispose();
  }

  // ─── Password strength checker ──────────────────────────
  void checkPasswordStrength() {
    final value = pass.text;
    setState(() {
      if (value.isEmpty) {
        passwordStrength = '';
        return;
      }

      bool hasUpper = value.contains(RegExp(r'[A-Z]'));
      bool hasLower = value.contains(RegExp(r'[a-z]'));
      bool hasNumber = value.contains(RegExp(r'[0-9]'));
      bool hasSpecial = value.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>]'));
      bool hasLength = value.length >= 8;

      int score = 0;
      if (hasUpper) score++;
      if (hasLower) score++;
      if (hasNumber) score++;
      if (hasSpecial) score++;
      if (hasLength) score++;

      if (score <= 2) {
        passwordStrength = 'Weak — add uppercase, number, special char';
        strengthColor = Colors.red;
      } else if (score == 3) {
        passwordStrength = 'Medium — add special char or more length';
        strengthColor = Colors.orange;
      } else if (score == 4) {
        passwordStrength = 'Strong ✓';
        strengthColor = Colors.green;
      } else {
        passwordStrength = 'Very Strong ✓✓';
        strengthColor = Colors.green;
      }
    });
  }

  // ─── Validations ────────────────────────────────────────
  String? validateFields() {
    if (first.text.trim().isEmpty) return 'First name required';
    if (last.text.trim().isEmpty) return 'Last name required';
    if (email.text.trim().isEmpty) return 'Email required';
    if (!RegExp(r'^[\w.-]+@[\w.-]+\.[a-zA-Z]{2,}$').hasMatch(email.text.trim())) {
      return 'Enter valid email (e.g. name@gmail.com)';
    }
    if (pass.text.isEmpty) return 'Password required';
    if (pass.text.length < 8) return 'Password min 8 characters';
    if (!RegExp(r'^(?=.*[a-z])(?=.*[A-Z])(?=.*\d).+$').hasMatch(pass.text)) {
      return 'Password needs uppercase, lowercase and number';
    }
    if (confirmPass.text.isEmpty) return 'Confirm password required';
    if (confirmPass.text != pass.text) return 'Passwords do not match';
    return null;
  }

  // ─── Signup function ────────────────────────────────────
  Future<void> signup() async {
    if (!mounted) return;

    // Validate all fields first
    final error = validateFields();
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(error), backgroundColor: Colors.red),
      );
      return;
    }

    setState(() => isLoading = true);

    try {
      // Step 1: Firebase create user
      await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: email.text.trim(),
        password: pass.text.trim(),
      );

      // Step 2: Backend /complete-signup (matches endpoint)
      await ApiService.post("/complete-signup", {
        "firstName": first.text.trim(),
        "lastName": last.text.trim(),
        "email": email.text.trim(),
        "phone": "",
      });

      print("SIGNUP SUCCESS");

      // Step 3: Go to onboarding (isCompleted=false for new users)
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/onboarding');
      }
    } on FirebaseAuthException catch (e) {
      print("SIGNUP ERROR: ${e.code}");
      String msg = "Signup failed";
      if (e.code == "email-already-in-use") {
        msg = "Account already exists. Please login.";
      } else if (e.code == "weak-password") {
        msg = "Password too weak";
      } else if (e.code == "invalid-email") {
        msg = "Invalid email address";
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg), backgroundColor: Colors.red),
        );
      }
    } catch (e) {
      print("SIGNUP ERROR: $e");
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text("Error: $e"),
            backgroundColor: Colors.red,
          ),
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
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [

              // ── First Name ──────────────────────────────
              TextField(
                controller: first,
                decoration: const InputDecoration(
                  labelText: "First Name",
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              // ── Last Name ───────────────────────────────
              TextField(
                controller: last,
                decoration: const InputDecoration(
                  labelText: "Last Name",
                  prefixIcon: Icon(Icons.person_outline),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              // ── Email ───────────────────────────────────
              TextField(
                controller: email,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: "Email",
                  hintText: "name@gmail.com",
                  prefixIcon: Icon(Icons.email_outlined),
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),

              // ── Password ────────────────────────────────
              TextField(
                controller: pass,
                obscureText: obscurePass,
                decoration: InputDecoration(
                  labelText: "Password",
                  prefixIcon: const Icon(Icons.lock_outlined),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscurePass
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => obscurePass = !obscurePass),
                  ),
                ),
              ),

              // ── Password Strength (Red/Orange/Green box) ─
              if (passwordStrength.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 6),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: strengthColor.withOpacity(0.1),
                    border: Border.all(color: strengthColor),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        strengthColor == Colors.green
                            ? Icons.check_circle
                            : Icons.warning_amber_rounded,
                        color: strengthColor,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          passwordStrength,
                          style: TextStyle(
                            color: strengthColor,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

              const SizedBox(height: 12),

              // ── Confirm Password ────────────────────────
              TextField(
                controller: confirmPass,
                obscureText: obscureConfirm,
                decoration: InputDecoration(
                  labelText: "Confirm Password",
                  prefixIcon: const Icon(Icons.lock_outlined),
                  border: const OutlineInputBorder(),
                  suffixIcon: IconButton(
                    icon: Icon(
                      obscureConfirm
                          ? Icons.visibility_outlined
                          : Icons.visibility_off_outlined,
                    ),
                    onPressed: () =>
                        setState(() => obscureConfirm = !obscureConfirm),
                  ),
                ),
              ),

              const SizedBox(height: 8),

              // ── Password rules hint ─────────────────────
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      "Password must have:",
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text("• At least 8 characters", style: TextStyle(fontSize: 12)),
                    Text("• One uppercase letter (A-Z)", style: TextStyle(fontSize: 12)),
                    Text("• One lowercase letter (a-z)", style: TextStyle(fontSize: 12)),
                    Text("• One number (0-9)", style: TextStyle(fontSize: 12)),
                  ],
                ),
              ),

              const SizedBox(height: 24),

              // ── Signup Button ───────────────────────────
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: isLoading ? null : signup,
                  child: isLoading
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : const Text(
                          "Create Account",
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Login link ──────────────────────────────
              Center(
                child: TextButton(
                  onPressed: () =>
                      Navigator.pushReplacementNamed(context, '/login'),
                  child: const Text("Already have account? Login"),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}