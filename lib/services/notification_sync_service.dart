import 'package:notification_listener_service/notification_listener_service.dart';
import 'package:flutter/material.dart';
import '../api_service.dart';

class NotificationSyncService {
  static final NotificationSyncService _instance =
      NotificationSyncService._internal();

  factory NotificationSyncService() => _instance;

  NotificationSyncService._internal();

  bool _initialized = false;

  // Allowed finance packages - adjust these to real package names
  static const List<String> allowedPackages = [
    "com.esewa.android", // eSewa
    "com.khalti", // Khalti
    "com.nabilbank", // Nabil Bank
    "com.nicasiabank", // Nicasia Bank
    "com.nrb.apps.mobileerp", // NRB Mobile
    "com.sc.biz.mobile", // Siddhartha Bank
    "com.imepay", // IME Pay
    "com.connectips.appz", // ConnectIPS
  ];

  /// Initialize notification listener
  /// Call this after user is logged in (in MainScreen or similar)
  Future<void> init() async {
    if (_initialized) {
      debugPrint("[NOTIF_SYNC] Already initialized, skipping.");
      return;
    }

    try {
      _initialized = true;
      debugPrint("[NOTIF_SYNC] Initializing notification listener...");

      // Check if notification listener permission is granted
      final bool hasAccess =
          await NotificationListenerService.isPermissionGranted();

      if (!hasAccess) {
        debugPrint(
            "[NOTIF_SYNC] Permission not granted. Opening permission settings...");
        // Request permission (this opens system settings)
        await NotificationListenerService.requestPermission();
        debugPrint(
            "[NOTIF_SYNC] Permission settings opened. User should enable notification access.");
      } else {
        debugPrint("[NOTIF_SYNC] Permission already granted.");
      }

      // Start listening to notifications
      NotificationListenerService.notificationsStream.listen(
        _onNotification,
        onError: (error) {
          debugPrint("[NOTIF_SYNC] Stream error: $error");
        },
      );

      debugPrint("[NOTIF_SYNC] Notification listener active.");
    } catch (e) {
      debugPrint("[NOTIF_SYNC] Init error: $e");
      _initialized = false;
    }
  }

  /// Process incoming notification
  /// ✅ FIXED: NotificationEvent → ServiceNotificationEvent
  void _onNotification(dynamic event) async {
    try {
      final package = event.packageName ?? "";
      final title = event.title ?? "";
      final body = event.body ?? "";
      final fullText = "$title $body".trim();

      debugPrint(
          "[NOTIF_SYNC] Received notification: package=$package, title=$title, body=$body");

      // 1. Filter for finance apps only
      final isAllowedApp = allowedPackages.any(
        (p) => package.toLowerCase().contains(p.toLowerCase()),
      );

      if (!isAllowedApp) {
        debugPrint("[NOTIF_SYNC] Package not in allowlist. Ignoring: $package");
        return;
      }

      // 2. Further filter on content to avoid random notifications
      final lower = fullText.toLowerCase();
      final bool looksLikeMoney = fullText.contains("Rs") ||
          fullText.contains("rs") ||
          lower.contains("rs.") ||
          lower.contains("debited") ||
          lower.contains("credited") ||
          lower.contains("paid") ||
          lower.contains("received") ||
          lower.contains("payment") ||
          lower.contains("amount") ||
          lower.contains("transfer") ||
          lower.contains("withdrawal") ||
          lower.contains("deposit");

      if (!looksLikeMoney) {
        debugPrint(
            "[NOTIF_SYNC] Notification does not contain money-related keywords. Ignoring: $fullText");
        return;
      }

      debugPrint(
          "[NOTIF_SYNC] Relevant notification detected. Forwarding to backend...");

      // 3. Forward to backend /chat with source="notification"
      // ✅ FIXED: event.id → event.notificationId
      final bodyJson = {
        "message": fullText,
        "source": "notification",
        "sourceApp": package,
        "originalMessageId": event.notificationId?.toString() ??
            event.tag ??
            "notif-${DateTime.now().millisecondsSinceEpoch}",
      };

      try {
        final res = await ApiService.post('/chat', bodyJson);
        debugPrint("[NOTIF_SYNC] Backend response: $res");

        // Backend will handle creating pending transaction and notification
        // Chat UI will show confirmation dialog through existing flow
      } catch (apiError) {
        debugPrint("[NOTIF_SYNC] API error: $apiError");
      }
    } catch (e) {
      debugPrint("[NOTIF_SYNC] Error processing notification: $e");
    }
  }
}
