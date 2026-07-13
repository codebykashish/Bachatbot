import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:notification_listener_service/notification_event.dart';
import '../api_service.dart';

/// Listens to Android system notifications (eSewa, Khalti, wallet apps —
/// anything that doesn't send SMS), filters for wallet/transaction-shaped
/// content, and forwards matches to the same /messages pipeline used by
/// MockNotificationScreen and SmsSyncService.
class NotificationSyncService {
  static final NotificationSyncService _instance =
      NotificationSyncService._internal();

  factory NotificationSyncService() => _instance;

  NotificationSyncService._internal();

  StreamSubscription<ServiceNotificationEvent>? _sub;
  bool _initialized = false;

  // Never process our own app's notifications (e.g. the budget alert
  // popups) — avoids any risk of self-triggering a fake transaction.
  // Also never process default SMS/Messaging apps — SmsSyncService already
  // reads SMS content directly, and these apps post a notification preview
  // of every new SMS that would otherwise get forwarded a second time as
  // a duplicate transaction.
  static const _excludedPackages = {
    'com.example.bachatbot',
    'com.google.android.apps.messaging', // Google Messages
    'com.samsung.android.messaging',     // Samsung Messages
    'com.android.mms',
    'com.android.messaging',
  };

  // Matches wallet/transaction notifications like:
  // "You have received NPR. 140.0 from EVEREST BANK LTD. in your eSewa account."
  // "Your transaction of Rs. 430.0 for Bank Withdraw has been successfully completed."
  static final RegExp _txnPattern = RegExp(
    r'(received|debited|credited|transaction of).{0,60}(NPR|Rs)\.?\s*[\d,]+',
    caseSensitive: false,
  );

  Future<void> init() async {
    if (_initialized) return;

    bool granted = await NotificationListenerService.isPermissionGranted();
    if (!granted) {
      granted = await NotificationListenerService.requestPermission();
    }
    if (!granted) {
      debugPrint('[NOTIF_SYNC] Notification access not granted — skipping listener setup.');
      return;
    }

    _sub = NotificationListenerService.notificationsStream.listen(_onNotification);
    _initialized = true;
    debugPrint('[NOTIF_SYNC] Listening for notifications.');
  }

  void dispose() {
    _sub?.cancel();
    _sub = null;
    _initialized = false;
  }

  void _onNotification(ServiceNotificationEvent event) {
    final package = event.packageName ?? '';
    if (_excludedPackages.contains(package)) return;

    final content = event.content ?? '';
    final title = event.title ?? '';

    debugPrint('[NOTIF_SYNC] package="$package" title="$title" content="$content"');

    if (!_txnPattern.hasMatch(content)) {
      debugPrint('[NOTIF_SYNC] Not a transaction pattern — ignoring.');
      return;
    }

    _forwardToBackend(content, title.isNotEmpty ? title : package);
  }

  Future<void> _forwardToBackend(String text, String sourceApp) async {
    try {
      final response = await ApiService.post('/messages', {
        'text': text,
        'source': 'notification',
        'sourceApp': sourceApp,
        'originalMessageId': 'notif-${DateTime.now().millisecondsSinceEpoch}',
      });
      debugPrint('[NOTIF_SYNC] Backend response: $response');
    } catch (e) {
      debugPrint('[NOTIF_SYNC] Forward failed: $e');
    }
  }
}
