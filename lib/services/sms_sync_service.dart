import 'package:flutter/widgets.dart';
import 'package:another_telephony/telephony.dart';
import 'package:firebase_core/firebase_core.dart';
import '../api_service.dart';
import '../firebase_options.dart';

/// Filters incoming SMS for a bank-transaction shape and forwards matches
/// to the /messages pipeline. Shared between the foreground listener and
/// the background isolate handler below, so both paths behave identically.
final RegExp _bankTxnPattern = RegExp(
  r'(credited|debited).{0,40}NPR',
  caseSensitive: false,
);

String? _extractBankName(String body) {
  final lines = body.trim().split('\n');
  final lastLine = lines.last.trim();
  if (lastLine.startsWith('-')) return lastLine.substring(1).trim();
  return null;
}

Future<void> _handleSms(SmsMessage message, String tag) async {
  final body = message.body ?? '';
  final sender = message.address ?? 'Unknown';

  debugPrint('[SMS_SYNC]$tag sender="$sender" body="$body"');

  if (!_bankTxnPattern.hasMatch(body)) {
    debugPrint('[SMS_SYNC]$tag Not a bank transaction pattern — ignoring.');
    return;
  }

  final bankName = _extractBankName(body) ?? sender;

  try {
    final response = await ApiService.post('/messages', {
      'text': body,
      'source': 'notification',
      'sourceApp': bankName,
      'originalMessageId': 'sms-${DateTime.now().millisecondsSinceEpoch}',
    });
    debugPrint('[SMS_SYNC]$tag Backend response: $response');
  } catch (e) {
    debugPrint('[SMS_SYNC]$tag Forward failed: $e');
  }
}

/// Runs in a separate background isolate that Android spins up when an SMS
/// arrives and the app isn't open. Must be a top-level function (not a
/// class method) and kept from being tree-shaken in release builds via the
/// vm:entry-point pragma. This isolate has no access to the main app's
/// state, so Firebase has to be initialized fresh here before ApiService
/// can fetch an auth token.
@pragma('vm:entry-point')
Future<void> smsBackgroundHandler(SmsMessage message) async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  } catch (_) {
    // Already initialized in this isolate — ignore duplicate-app error.
  }
  await _handleSms(message, '[BG]');
}

/// Phase 2: filter + forward.
/// Listens for incoming SMS — including while the app is closed/backgrounded
/// — keeps only messages that look like a bank transaction alert, and
/// forwards the raw text to the existing /messages pipeline (same one used
/// by MockNotificationScreen) so Gemini parses it and a pending transaction
/// is created for review.
class SmsSyncService {
  static final SmsSyncService _instance = SmsSyncService._internal();

  factory SmsSyncService() => _instance;

  SmsSyncService._internal();

  final Telephony _telephony = Telephony.instance;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    final granted = await _telephony.requestSmsPermissions;
    if (granted != true) {
      debugPrint('[SMS_SYNC] SMS permission not granted — skipping listener setup.');
      return;
    }

    _telephony.listenIncomingSms(
      onNewMessage: (message) => _handleSms(message, ''),
      onBackgroundMessage: smsBackgroundHandler,
      listenInBackground: true,
    );

    _initialized = true;
    debugPrint('[SMS_SYNC] Listening for incoming SMS (foreground + background).');
  }
}
