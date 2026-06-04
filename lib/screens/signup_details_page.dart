import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../api_service.dart';
import 'main_screen.dart';

class SignupDetailsPage extends StatefulWidget {
  final String email;

  const SignupDetailsPage({super.key, required this.email});

  @override
  State<SignupDetailsPage> createState() => _SignupDetailsPageState();
}

class _SignupDetailsPageState extends State<SignupDetailsPage> {
  final _formKey = GlobalKey<FormState>();
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _obscureConfirmPassword = true;
  
  // Backend password error if any
  String? _backendPasswordError;

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  // ── Password Rules Logic ───────────────────────────────────────────────

  bool get _hasMinLength => _passwordController.text.length >= 8;
  bool get _hasNumber => _passwordController.text.contains(RegExp(r'[0-9]'));
  bool get _hasSpecial => _passwordController.text.contains(RegExp(r'[^a-zA-Z0-9]'));
  bool get _isPasswordStrong => _hasMinLength && _hasNumber && _hasSpecial;

  String? _getPasswordError() {
    final password = _passwordController.text;
    if (password.isEmpty) return null;
    
    // Prioritize backend error if it exists and password hasn't changed much
    if (_backendPasswordError != null) return _backendPasswordError;

    List<String> missing = [];
    if (!_hasMinLength) {
      int remaining = 8 - password.length;
      return 'Your password is too short. Add at least $remaining more characters (minimum 8 characters in total).';
    }
    
    if (!_hasNumber) missing.add('one number (e.g. 1, 2, 3)');
    if (!_hasSpecial) missing.add('one special character (e.g. @, #, *)');

    if (missing.isNotEmpty) {
      if (missing.length == 1) {
        return 'Your password is missing: ${missing[0]}.';
      } else {
        return 'Your password is missing: ${missing[0]} and ${missing[1]}.';
      }
    }

    return null;
  }

  // ── Validators ─────────────────────────────────────────────────────────────

  String? _validateFirstName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'First name is required';
    }
    return null;
  }

  String? _validateLastName(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Last name is required';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your password';
    }
    if (value != _passwordController.text) {
      return 'Passwords do not match';
    }
    return null;
  }

  // ── Helpers ─────────────────────────────────────────────────────────────────

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
      ),
    );
  }

  void _showSuccess(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.green.shade700,
      ),
    );
  }

  // ── Signup logic ────────────────────────────────────────────────────────────

  Future<void> _completeSignup() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_isPasswordStrong) return;

    final firstName = _firstNameController.text.trim();
    final lastName = _lastNameController.text.trim();
    final phone = _phoneController.text.trim();
    final password = _passwordController.text;

    setState(() {
      _isLoading = true;
      _backendPasswordError = null;
    });

    try {
      // 1. Firebase create user
      final userCredential =
          await FirebaseAuth.instance.createUserWithEmailAndPassword(
        email: widget.email,
        password: password,
      );

      // Save display name
      await userCredential.user?.updateDisplayName(firstName);

      // 2. Complete signup in backend
      try {
        final signupRes = await ApiService.post('/complete-signup', {
          'firstName': firstName,
          'lastName': lastName,
          'email': widget.email,
          'phone': phone.isNotEmpty ? phone : null,
        });
        debugPrint('[SignupDetailsPage] /complete-signup response: $signupRes');
      } catch (e) {
        debugPrint('[SignupDetailsPage] /complete-signup error: $e');
        
        // Handle backend weak password error if it comes back from complete-signup
        final errorMsg = e.toString().toLowerCase();
        if (errorMsg.contains('password') && errorMsg.contains('weak')) {
           setState(() => _backendPasswordError = 'The backend rejected this password as too weak. Please use a stronger one.');
           // If it failed at backend, we might want to delete the firebase user or let them try again
           // For now, let's just show the error.
        }
      }

      // 3. Verify profile
      try {
        await ApiService.get('/profile');
      } catch (e) {
        debugPrint('[SignupDetailsPage] /profile error: $e');
      }

      if (!mounted) return;
      _showSuccess('Account created successfully!');

      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(
          builder: (_) => MainScreen(firstName: firstName),
        ),
        (route) => false,
      );
    } on FirebaseAuthException catch (e) {
      if (e.code == 'weak-password') {
        setState(() => _backendPasswordError = e.message ?? 'Password is too weak.');
      } else {
        _showError(e.message ?? 'Signup failed. Please try again.');
      }
    } catch (e) {
      debugPrint('[SignupDetailsPage] signup error: $e');
      _showError('Failed to complete signup. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final passwordError = _getPasswordError();
    final bool canSubmit = !_isLoading && _isPasswordStrong;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile Details'),
        backgroundColor: const Color(0xFF2DBE7F),
        foregroundColor: Colors.white,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 24),
              const Text(
                'Complete your profile',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 24),

              // ── First Name ─────────────────────────────────────────────
              TextFormField(
                controller: _firstNameController,
                validator: _validateFirstName,
                decoration: InputDecoration(
                  labelText: 'First Name',
                  prefixIcon: const Icon(Icons.person_outline),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── Last Name ──────────────────────────────────────────────
              TextFormField(
                controller: _lastNameController,
                validator: _validateLastName,
                decoration: InputDecoration(
                  labelText: 'Last Name',
                  prefixIcon: const Icon(Icons.person_outline),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── Phone ──────────────────────────────────────────────────
              TextFormField(
                controller: _phoneController,
                keyboardType: TextInputType.phone,
                decoration: InputDecoration(
                  labelText: 'Phone (Optional)',
                  prefixIcon: const Icon(Icons.phone_outlined),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ── Password ───────────────────────────────────────────────
              TextFormField(
                controller: _passwordController,
                obscureText: _obscurePassword,
                onChanged: (_) {
                  if (_backendPasswordError != null) {
                    setState(() => _backendPasswordError = null);
                  } else {
                    setState(() {});
                  }
                },
                decoration: InputDecoration(
                  labelText: 'Password',
                  prefixIcon: const Icon(Icons.lock_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscurePassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () =>
                        setState(() => _obscurePassword = !_obscurePassword),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  // Highlight red border if invalid or missing parts
                  enabledBorder: (passwordError != null)
                      ? OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Colors.red),
                        )
                      : null,
                  focusedBorder: (passwordError != null)
                      ? OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Colors.red, width: 2),
                        )
                      : null,
                ),
              ),

              // ── Direct Password Error ──────────────────────────────────
              if (passwordError != null) ...[
                const SizedBox(height: 8),
                Text(
                  passwordError,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],
              
              const SizedBox(height: 16),

              // ── Confirm Password ───────────────────────────────────────
              TextFormField(
                controller: _confirmPasswordController,
                obscureText: _obscureConfirmPassword,
                validator: _validateConfirmPassword,
                decoration: InputDecoration(
                  labelText: 'Confirm Password',
                  prefixIcon: const Icon(Icons.lock_outlined),
                  suffixIcon: IconButton(
                    icon: Icon(
                      _obscureConfirmPassword
                          ? Icons.visibility_off_outlined
                          : Icons.visibility_outlined,
                    ),
                    onPressed: () => setState(() =>
                        _obscureConfirmPassword = !_obscureConfirmPassword),
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // ── Create Account Button ──────────────────────────────────
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  onPressed: canSubmit ? _completeSignup : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF2DBE7F),
                    foregroundColor: Colors.white,
                    disabledBackgroundColor: Colors.grey.shade300,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: _isLoading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2.5,
                          ),
                        )
                      : const Text(
                          'Create Account',
                          style: TextStyle(fontSize: 16),
                        ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
