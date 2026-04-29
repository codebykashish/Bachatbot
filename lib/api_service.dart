import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:firebase_auth/firebase_auth.dart';

class ApiService {
  static const String baseUrl =
      "https://undying-direness-bagpipe.ngrok-free.dev";

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
        return jsonDecode(retryResponse.body);
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
        return jsonDecode(retryResponse.body);
      }

      return jsonDecode(response.body);
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
        return jsonDecode(retryResponse.body);
      }

      return jsonDecode(response.body);
    } catch (e) {
      rethrow;
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
        return jsonDecode(retryResponse.body);
      }

      return jsonDecode(response.body);
    } catch (e) {
      rethrow;
    }
  }
}