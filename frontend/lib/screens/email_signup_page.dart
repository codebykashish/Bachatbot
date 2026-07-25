import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import '../api_service.dart';
import 'code_verification_page.dart';

class EmailSignupPage extends StatefulWidget {
  const EmailSignupPage({super.key});

  @override
  State<EmailSignupPage> createState() => _EmailSignupPageState();
}

class _EmailSignupPageState extends State<EmailSignupPage> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _isLoading = false;

  // Inline error shown below the email field
  String? _emailError;

  // Email validation regex
  final _emailRegex = RegExp(r'^[^@]+@[^@]+\.[^@]+$');

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  void _onEmailChanged(String _) {
    // Clear error as soon as user starts typing to enable the button again
    if (_emailError != null) {
      setState(() => _emailError = null);
    }
  }

  String? _getLocalError(String value) {
    if (value.isEmpty) {
      return 'Please enter your email';
    }
    if (!_emailRegex.hasMatch(value)) {
      return 'Please enter a valid email address';
    }
    
    // Domain check: Only allow @gmail.com
    final parts = value.split('@');
    if (parts.length == 2) {
      final domain = parts[1].toLowerCase();
      if (domain != 'gmail.com') {
        return 'Please enter a Gmail address ending with @gmail.com.';
      }
    } else {
      return 'Please enter a valid email address';
    }
    
    return null;
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red.shade700,
      ),
    );
  }

  /// Calls the uniqueness check and the code sending endpoint.
  Future<void> _sendCode() async {
    final email = _emailController.text.trim();
    
    // 1. Local format and domain check
    final localError = _getLocalError(email);
    if (localError != null) {
      setState(() => _emailError = localError);
      return;
    }

    setState(() {
      _isLoading = true;
      _emailError = null;
    });

    try {
      // 2. UX Optimization: Call check-email first
      final checkRes = await http.post(
        Uri.parse('${ApiService.baseUrl}/check-email'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'email': email}),
      );

      if (checkRes.statusCode == 200) {
        final checkData = jsonDecode(checkRes.body);
        if (checkData['exists'] == true) {
          setState(() {
            _emailError = 'An account with this email already exists.\nPlease use another Gmail address or log in instead.';
            _isLoading = false;
          });
          return;
        }
      }

      // 3. Call send-verification-code
      final response = await http.post(
        Uri.parse('${ApiService.baseUrl}/send-verification-code'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'email': email,
          'purpose': 'signup',
        }),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => CodeVerificationPage(email: email),
          ),
        );
      } else {
        // 4. Handle specific backend error codes
        try {
          final data = jsonDecode(response.body);
          final errorKey = data['error'];
          
          if (errorKey == 'EMAIL_ALREADY_IN_USE') {
            setState(() {
              _emailError = 'An account with this email already exists.\nPlease use another Gmail address or log in instead.';
            });
          } else if (errorKey == 'INVALID_EMAIL_DOMAIN') {
             setState(() {
              _emailError = data['message'] ?? 'Please enter a Gmail address ending with @gmail.com.';
            });
          } else {
            _showError(data['message'] ?? 'Failed to send code. Please try again.');
          }
        } catch (_) {
          _showError('Failed to send code. Please try again.');
        }
      }
    } catch (e) {
      if (mounted) _showError('An error occurred. Please try again.');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bool hasError = _emailError != null;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Account'),
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
                'What\'s your email address?',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.black87,
                ),
              ),
              const SizedBox(height: 8),
              const Text(
                'We\'ll send you a verification code.',
                style: TextStyle(
                  fontSize: 14,
                  color: Colors.grey,
                ),
              ),
              const SizedBox(height: 32),

              // ── Email field ───────────────────────────────────────────────
              TextFormField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                onChanged: _onEmailChanged,
                decoration: InputDecoration(
                  labelText: 'Email Address',
                  prefixIcon: const Icon(Icons.email_outlined),
                  // Red error icon on the right if invalid
                  suffixIcon: hasError ? const Icon(Icons.error, color: Colors.red) : null,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  // Red border style when error exists
                  enabledBorder: hasError
                      ? OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Colors.red),
                        )
                      : null,
                  focusedBorder: hasError
                      ? OutlineInputBorder(
                          borderRadius: BorderRadius.circular(8),
                          borderSide: const BorderSide(color: Colors.red, width: 2),
                        )
                      : null,
                ),
              ),

              // ── Inline error ─────────────────────────────────────────────
              if (hasError) ...[
                const SizedBox(height: 8),
                Text(
                  _emailError!,
                  style: const TextStyle(color: Colors.red, fontSize: 12),
                ),
              ],

              const SizedBox(height: 32),

              // ── Next button ───────────────────────────────────────────────
              SizedBox(
                height: 52,
                child: ElevatedButton(
                  // Button is disabled while loading OR while an error is shown
                  onPressed: (_isLoading || hasError) ? null : _sendCode,
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
                          'Next',
                          style: TextStyle(fontSize: 16),
                        ),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Back to Login',
                    style: TextStyle(
                      color: Color(0xFF2DBE7F),
                      fontWeight: FontWeight.w500,
                    ),
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
