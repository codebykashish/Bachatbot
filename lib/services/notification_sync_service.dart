import 'package:flutter/material.dart';

class NotificationSyncService {
  static final NotificationSyncService _instance =
      NotificationSyncService._internal();

  factory NotificationSyncService() => _instance;

  NotificationSyncService._internal();

  /// Real notification sync is disabled.
  /// Mock notification flow (MockNotificationScreen) remains unaffected.
  Future<void> init() async {
    debugPrint("[NOTIF_SYNC] Real notification sync is disabled.");
  }
}
