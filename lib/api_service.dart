import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';

class ApiService {
  // If running on an Android Emulator, use 10.0.2.2 to access your computer's localhost:3000
  // If running on a physical phone, change this to your computer's Wi-Fi IP address (e.g., "http://192.168.1.100:3000")
  // Or use your new ngrok URL here if you prefer ngrok.
  static const String baseUrl =
      "https://thoroughpaced-nabobically-mika.ngrok-free.dev";

  /// Gets a fresh token — Firebase auto-refreshes if expired
  /// This means user NEVER gets logged out due to token expiry
  static Future<String> _getToken() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw Exception("User not logged in");

    // forceRefresh: true ensures we always get a valid token
    // Firebase handles the refresh silently — no re-login needed
    final token = await user.getIdToken(true);
    if (token == null) throw Exception("Failed to get token");
    return token;
  }

  static Map<String, String> _headers(String token) => {
        "Authorization": "Bearer $token",
        "Content-Type": "application/json",
      };

  /// GET request with auto token refresh + 401 retry
  static Future<Map<String, dynamic>> get(String endpoint) async {
    try {
      final token = await _getToken();
      final response = await http.get(
        Uri.parse("$baseUrl$endpoint"),
        headers: _headers(token),
      );

      // If 401, force refresh and retry once
      if (response.statusCode == 401) {
        final freshToken = await _getToken();
        final retryResponse = await http.get(
          Uri.parse("$baseUrl$endpoint"),
          headers: _headers(freshToken),
        );
        if (retryResponse.statusCode < 200 || retryResponse.statusCode >= 300) {
          throw Exception(
              "HTTP ${retryResponse.statusCode}: ${retryResponse.body}");
        }
        return jsonDecode(retryResponse.body);
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception("HTTP ${response.statusCode}: ${response.body}");
      }
      return jsonDecode(response.body);
    } catch (e) {
      rethrow;
    }
  }

  /// POST request with auto token refresh + 401 retry
  static Future<Map<String, dynamic>> post(
      String endpoint, Map<String, dynamic> body) async {
    try {
      final token = await _getToken();
      final response = await http.post(
        Uri.parse("$baseUrl$endpoint"),
        headers: _headers(token),
        body: jsonEncode(body),
      );

      if (response.statusCode == 401) {
        final freshToken = await _getToken();
        final retryResponse = await http.post(
          Uri.parse("$baseUrl$endpoint"),
          headers: _headers(freshToken),
          body: jsonEncode(body),
        );
        if (retryResponse.statusCode < 200 || retryResponse.statusCode >= 300) {
          throw Exception(
              "HTTP ${retryResponse.statusCode}: ${retryResponse.body}");
        }
        return jsonDecode(retryResponse.body);
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception("HTTP ${response.statusCode}: ${response.body}");
      }
      return jsonDecode(response.body);
    } catch (e) {
      rethrow;
    }
  }

  /// POST request returning raw http.Response (with auto token refresh + 401 retry)
  static Future<http.Response> postRaw(
      String endpoint, Map<String, dynamic> body) async {
    try {
      final token = await _getToken();
      var response = await http.post(
        Uri.parse("$baseUrl$endpoint"),
        headers: _headers(token),
        body: jsonEncode(body),
      );

      if (response.statusCode == 401) {
        final freshToken = await _getToken();
        response = await http.post(
          Uri.parse("$baseUrl$endpoint"),
          headers: _headers(freshToken),
          body: jsonEncode(body),
        );
      }
      return response;
    } catch (e) {
      rethrow;
    }
  }

  /// PATCH request with auto token refresh + 401 retry
  static Future<Map<String, dynamic>> patch(
      String endpoint, Map<String, dynamic> body) async {
    try {
      final token = await _getToken();
      final response = await http.patch(
        Uri.parse("$baseUrl$endpoint"),
        headers: _headers(token),
        body: jsonEncode(body),
      );

      if (response.statusCode == 401) {
        final freshToken = await _getToken();
        final retryResponse = await http.patch(
          Uri.parse("$baseUrl$endpoint"),
          headers: _headers(freshToken),
          body: jsonEncode(body),
        );
        if (retryResponse.statusCode < 200 || retryResponse.statusCode >= 300) {
          throw Exception(
              "HTTP ${retryResponse.statusCode}: ${retryResponse.body}");
        }
        return jsonDecode(retryResponse.body);
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception("HTTP ${response.statusCode}: ${response.body}");
      }
      return jsonDecode(response.body);
    } catch (e) {
      rethrow;
    }
  }

  /// Notifies the backend of logout while the Firebase token is still valid.
  /// Must be called BEFORE FirebaseAuth.instance.signOut().
  static Future<void> logout() async {
    try {
      final user = FirebaseAuth.instance.currentUser;
      if (user == null) return; // already signed out on client
      // Use the current token without forcing a refresh — it's still valid
      final token = await user.getIdToken(false);
      if (token == null) return;
      await http.post(
        Uri.parse("$baseUrl/logout"),
        headers: _headers(token),
      );
    } catch (e) {
      // Log but don't rethrow — client-side signOut must still proceed
      debugPrint('[ApiService] logout backend call failed: $e');
    }
  }

  /// DELETE request with auto token refresh + 401 retry
  static Future<Map<String, dynamic>> delete(String endpoint) async {
    try {
      final token = await _getToken();
      final response = await http.delete(
        Uri.parse("$baseUrl$endpoint"),
        headers: _headers(token),
      );

      if (response.statusCode == 401) {
        final freshToken = await _getToken();
        final retryResponse = await http.delete(
          Uri.parse("$baseUrl$endpoint"),
          headers: _headers(freshToken),
        );
        if (retryResponse.statusCode < 200 || retryResponse.statusCode >= 300) {
          throw Exception(
              "HTTP ${retryResponse.statusCode}: ${retryResponse.body}");
        }
        return jsonDecode(retryResponse.body);
      }

      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception("HTTP ${response.statusCode}: ${response.body}");
      }
      return jsonDecode(response.body);
    } catch (e) {
      rethrow;
    }
  }

  // ── Pending transaction helpers ────────────────────────────────────────────

  /// Confirm one or more pending transactions.
  /// [ids] — backend transaction IDs.
  /// [amount] — optional updated amount (for edit flow).
  /// [category] — optional category selected by user.
  static Future<Map<String, dynamic>> confirmTransactions(
    List<String> ids, {
    double? amount,
    String? category,
  }) {
    final body = <String, dynamic>{'ids': ids};
    if (amount != null) body['amount'] = amount;
    if (category != null) body['category'] = category;
    return post('/transactions/confirm', body);
  }

  /// Cancel / discard one or more pending transactions.
  static Future<Map<String, dynamic>> cancelTransactions(List<String> ids) {
    return post('/transactions/cancel', {'ids': ids});
  }
}
