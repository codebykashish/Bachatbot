import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'email_signup_page.dart';
import 'main_screen.dart';
import '../api_service.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _isLoading = false;
  bool _showPassword = false;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final cred = await FirebaseAuth.instance.signInWithEmailAndPassword(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );

      String firstName = 'User';
      // Call /profile to establish backend session and verify it exists
      try {
        final profileRes = await ApiService.get('/profile');
        debugPrint('[LoginScreen] /profile result: $profileRes');

        // If profile doesn't exist (success: false or no data), create it
        if (profileRes['success'] != true || profileRes['data'] == null) {
          debugPrint(
              '[LoginScreen] Profile not found, attempting to create...');
          await _createProfileFallback(cred.user);
          firstName = (cred.user?.displayName ?? 'User').split(' ').first;
        } else {
          firstName = profileRes['data']['firstName'] as String? ?? 'User';
        }
      } catch (e) {
        debugPrint('[LoginScreen] /profile error: $e — attempting fallback');
        await _createProfileFallback(cred.user);
        firstName = (cred.user?.displayName ?? 'User').split(' ').first;
      }

      if (mounted) {
        Navigator.pushAndRemoveUntil(
          context,
          MaterialPageRoute(builder: (_) => MainScreen(firstName: firstName)),
          (route) => false,
        );
      }
    } on FirebaseAuthException catch (e) {
      if (!mounted) return;
      String msg = 'Login failed. Please try again.';
      switch (e.code) {
        case 'user-not-found':
          msg = 'No account found with this email.';
          break;
        case 'wrong-password':
        case 'invalid-credential':
          msg = 'Incorrect email or password.';
          break;
        case 'invalid-email':
          msg = 'Please enter a valid email address.';
          break;
        case 'too-many-requests':
          msg = 'Too many failed attempts. Try again later.';
          break;
      }
      _showError(msg);
    } catch (e) {
      if (!mounted) return;
      _showError('An unexpected error occurred.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Fallback: create a backend profile if /profile returns 404 or fails.
  /// Uses Firebase displayName / email as defaults.
  Future<void> _createProfileFallback(User? user) async {
    if (user == null) return;
    try {
      final nameParts = (user.displayName ?? 'User').split(' ');
      final res = await ApiService.post('/complete-signup', {
        'firstName': nameParts.first,
        'lastName': nameParts.length > 1 ? nameParts.sublist(1).join(' ') : '',
        'email': user.email ?? '',
      });
      debugPrint('[LoginScreen] /complete-signup fallback result: $res');
    } catch (e) {
      // 409 conflict = profile already exists, which is fine
      debugPrint(
          '[LoginScreen] /complete-signup fallback error (may be 409): $e');
    }
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 40),
                const Icon(Icons.savings, size: 72, color: Color(0xFF2DBE7F)),
                const SizedBox(height: 16),
                const Text(
                  'BachatBot',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF2DBE7F)),
                ),
                const Text(
                  'Your AI expense tracker',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 14, color: Colors.grey),
                ),
                const SizedBox(height: 48),
                TextFormField(
                  controller: _emailController,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: 'Email',
                    prefixIcon: Icon(Icons.email_outlined),
                    border: OutlineInputBorder(),
                  ),
                  validator: (value) => (value == null || value.trim().isEmpty)
                      ? 'Please enter your email'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _passwordController,
                  obscureText: !_showPassword,
                  decoration: InputDecoration(
                    labelText: 'Password',
                    prefixIcon: const Icon(Icons.lock_outlined),
                    border: const OutlineInputBorder(),
                    suffixIcon: IconButton(
                      icon: Icon(_showPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined),
                      onPressed: () =>
                          setState(() => _showPassword = !_showPassword),
                    ),
                  ),
                  validator: (value) => (value == null || value.isEmpty)
                      ? 'Please enter your password'
                      : null,
                ),
                const SizedBox(height: 28),
                SizedBox(
                  height: 52,
                  child: ElevatedButton(
                    onPressed: _isLoading ? null : _login,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2DBE7F),
                      foregroundColor: Colors.white,
                    ),
                    child: _isLoading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                                color: Colors.white, strokeWidth: 2.5))
                        : const Text('Login', style: TextStyle(fontSize: 16)),
                  ),
                ),
                const SizedBox(height: 20),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Text("Don't have an account? ",
                        style: TextStyle(color: Colors.grey)),
                    GestureDetector(
                      onTap: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                              builder: (_) => const EmailSignupPage()),
                        );
                      },
                      child: const Text(
                        'Create Account',
                        style: TextStyle(
                            color: Color(0xFF2DBE7F),
                            fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
