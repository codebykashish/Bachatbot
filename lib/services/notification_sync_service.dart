import 'dart:async';
import 'package:notification_listener_service/notification_event.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import '../api_service.dart';
// sab

/// Singleton service that listens to Android system notifications,
/// filters for finance-related apps (eSewa, Khalti, banks),
/// parses amount / type, and forwards to the backend via POST /chat.
class NotificationSyncService {
  // ── Singleton ──────────────────────────────────────────────────────────
  static final NotificationSyncService _instance =
      NotificationSyncService._internal();
  factory NotificationSyncService() => _instance;
  NotificationSyncService._internal();

  StreamSubscription<ServiceNotificationEvent>? _subscription;
  bool _isListening = false;

  // ── Allowed package names (finance apps only) ─────────────────────────
  /// Only notifications from these packages are forwarded.
  /// Add real package names as they are confirmed.
  static const Set<String> _allowedPackages = {
    // eSewa
    'com.f1soft.esewa',

    // Khalti
    'com.khalti',
    'com.khalti.android',

    // IME Pay
    'com.swifttechnology.imepay',

    // ConnectIPS
    'com.nchl.connectips',

    // ──── Banks ────
    // Nabil Bank
    'com.nabornepal.nabil',
    'com.nabilbank.nMobile',

    // NIC Asia
    'com.nicasia.ebanking',
    'com.nicasia.nicmobilebanking',

    // Global IME
    'com.gibl.app',

    // Sanima Bank
    'com.sanimabank.mobilebanking',

    // Machhapuchchhre Bank
    'com.mabornepal.mabornepal',

    // Siddhartha Bank
    'com.siddharthabank.mobilebanking',

    // Laxmi Sunrise Bank
    'com.laxmisunrisebank.mobilebanking',

    // Citizens Bank
    'com.citizensbank.mobilebanking',

    // Prabhu Bank
    'com.prabhubank.mobilebanking',

    // Nepal Investment Mega Bank
    'com.nimb.mobilebanking',

    // Standard Chartered Nepal
    'com.scb.breezenp',

    // Everest Bank
    'com.everestbank.mobilebanking',

    // NMB Bank
    'com.nmb.mobilebanking',

    // Kumari Bank
    'com.kumaribank.mobilebanking',

    // Agriculture Development Bank
    'com.adbl.mobilebanking',

    // Nepal Bank Limited
    'com.nbl.mobilebanking',

    // Rastriya Banijya Bank
    'com.rbb.mobilebanking',
  };

  // ── Text patterns that indicate a financial notification ──────────────
  static final RegExp _amountPattern =
      RegExp(r'(?:Rs|NPR|NRs)\.?\s?[\d,]+(?:\.\d{1,2})?', caseSensitive: false);

  static final RegExp _numericExtract =
      RegExp(r'[\d,]+(?:\.\d{1,2})?');

  static const Set<String> _financialKeywords = {
    'debited',
    'credited',
    'paid',
    'received',
    'transferred',
    'deposited',
    'withdraw',
    'withdrawn',
    'payment',
    'sent',
    'balance',
    'transaction',
  };

  static const Set<String> _incomeKeywords = {
    'credited',
    'received',
    'deposited',
    'deposit',
  };

  // ── Public API ────────────────────────────────────────────────────────

  /// Check if the user has granted Notification Access.
  Future<bool> isPermissionGranted() async {
    return await NotificationListenerService.isPermissionGranted();
  }

  /// Open Android Settings so the user can grant Notification Access.
  Future<bool> requestPermission() async {
    final granted = await NotificationListenerService.requestPermission();
    print('[NOTIF_SYNC] Permission granted: $granted');
    return granted;
  }

  /// Initialize the listener. Call once after login (e.g. in MainScreen).
  /// If permission is not yet granted, this is a no-op — the UI should
  /// call [requestPermission] first.
  Future<void> init() async {
    if (_isListening) {
      print('[NOTIF_SYNC] Already listening — skipping re-init.');
      return;
    }

    final hasPermission = await isPermissionGranted();
    if (!hasPermission) {
      print('[NOTIF_SYNC] Notification access not granted. '
          'Call requestPermission() first.');
      return;
    }

    _subscription = NotificationListenerService.notificationsStream
        .listen(_onNotification);
    _isListening = true;
    print('[NOTIF_SYNC] Listener started ✓');
  }

  /// Stop listening (e.g. on logout).
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _isListening = false;
    print('[NOTIF_SYNC] Listener disposed.');
  }

  // ── Internal: notification handler ────────────────────────────────────

  void _onNotification(ServiceNotificationEvent event) {
    final packageName = event.packageName ?? '';
    final title = event.title ?? '';
    final body = event.content ?? '';
    final fullText = '$title $body';

    // 1. Package filter — skip if not a finance app.
    if (!_allowedPackages.contains(packageName)) return;

    // 2. Keyword filter — must contain at least one financial keyword.
    final lowerText = fullText.toLowerCase();
    final hasKeyword =
        _financialKeywords.any((kw) => lowerText.contains(kw));
    if (!hasKeyword) return;

    // 3. Amount filter — must mention Rs / NPR / NRs with a number.
    if (!_amountPattern.hasMatch(fullText)) return;

    print('[NOTIF_SYNC] ✓ Finance notification detected');
    print('[NOTIF_SYNC]   package=$packageName');
    print('[NOTIF_SYNC]   title=$title');
    print('[NOTIF_SYNC]   body=$body');

    // 4. Parse amount.
    final amountMatch = _amountPattern.firstMatch(fullText);
    String? parsedAmount;
    if (amountMatch != null) {
      final numMatch = _numericExtract.firstMatch(amountMatch.group(0)!);
      if (numMatch != null) {
        parsedAmount = numMatch.group(0)!.replaceAll(',', '');
      }
    }

    // 5. Determine type (income or expense).
    final isIncome = _incomeKeywords.any((kw) => lowerText.contains(kw));
    final type = isIncome ? 'income' : 'expense';

    print('[NOTIF_SYNC]   parsed amount=$parsedAmount  type=$type');

    // 6. Send to backend.
    _sendToBackend(
      notificationText: fullText,
      packageName: packageName,
      notificationId: event.id?.toString() ?? '',
    );
  }

  Future<void> _sendToBackend({
    required String notificationText,
    required String packageName,
    required String notificationId,
  }) async {
    print('[NOTIF_SYNC] Sending to backend POST /chat  source=notification');

    try {
      final response = await ApiService.post('/chat', {
        'message': notificationText,
        'source': 'notification',
        'sourceApp': packageName,
        'originalMessageId': notificationId,
      });

      print('[NOTIF_SYNC] Backend response: $response');
    } catch (e) {
      // Never crash the UI — just log.
      print('[NOTIF_SYNC] ✗ Backend error: $e');
    }
  }
}
