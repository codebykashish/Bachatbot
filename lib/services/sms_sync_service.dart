import 'package:flutter/foundation.dart';
import 'package:another_telephony/telephony.dart';
import '../api_service.dart';

/// Phase 2: filter + forward.
/// Listens for incoming SMS, keeps only messages that look like a bank
/// transaction alert (contains "credited"/"debited" + "NPR"), and forwards
/// the raw text to the existing /messages pipeline (same one used by
/// MockNotificationScreen) so Gemini parses it and a pending transaction
/// is created for review.
class SmsSyncService {
  static final SmsSyncService _instance = SmsSyncService._internal();

  factory SmsSyncService() => _instance;

  SmsSyncService._internal();

  final Telephony _telephony = Telephony.instance;
  bool _initialized = false;

  static final RegExp _bankTxnPattern = RegExp(
    r'(credited|debited).{0,40}NPR',
    caseSensitive: false,
  );

  Future<void> init() async {
    if (_initialized) return;

    final granted = await _telephony.requestSmsPermissions;
    if (granted != true) {
      debugPrint('[SMS_SYNC] SMS permission not granted — skipping listener setup.');
      return;
    }

    _telephony.listenIncomingSms(
      onNewMessage: _onSms,
      listenInBackground: false,
    );

    _initialized = true;
    debugPrint('[SMS_SYNC] Listening for incoming SMS (filter + forward, foreground).');
  }

  void _onSms(SmsMessage message) {
    final body = message.body ?? '';
    final sender = message.address ?? 'Unknown';

    debugPrint('[SMS_SYNC] sender="$sender" body="$body"');

    if (!_bankTxnPattern.hasMatch(body)) {
      debugPrint('[SMS_SYNC] Not a bank transaction pattern — ignoring.');
      return;
    }

    final bankName = _extractBankName(body) ?? sender;
    _forwardToBackend(body, bankName);
  }

  String? _extractBankName(String body) {
    final lines = body.trim().split('\n');
    final lastLine = lines.last.trim();
    if (lastLine.startsWith('-')) return lastLine.substring(1).trim();
    return null;
  }

  Future<void> _forwardToBackend(String text, String sourceApp) async {
    try {
      final response = await ApiService.post('/messages', {
        'text': text,
        'source': 'notification',
        'sourceApp': sourceApp,
        'originalMessageId': 'sms-${DateTime.now().millisecondsSinceEpoch}',
      });

      debugPrint('[SMS_SYNC] Backend response: $response');
    } catch (e) {
      debugPrint('[SMS_SYNC] Forward failed: $e');
    }
  }
}
