import 'package:flutter/material.dart';
import '../services/notification_sync_service.dart';

/// A helper screen that guides the user through enabling
/// Android Notification Access for BachatBot.
///
/// Usage:
/// ```dart
/// Navigator.push(context,
///   MaterialPageRoute(builder: (_) => const NotificationPermissionScreen()));
/// ```
class NotificationPermissionScreen extends StatefulWidget {
  const NotificationPermissionScreen({super.key});

  @override
  State<NotificationPermissionScreen> createState() =>
      _NotificationPermissionScreenState();
}

class _NotificationPermissionScreenState
    extends State<NotificationPermissionScreen> with WidgetsBindingObserver {
  static const Color _primary = Color(0xFF2DBE7F);

  bool _checking = true;
  bool _granted = false;

  final _syncService = NotificationSyncService();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _checkPermission();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Re-check when the user returns from Android Settings.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _checkPermission();
    }
  }

  Future<void> _checkPermission() async {
    final granted = await _syncService.isPermissionGranted();
    if (!mounted) return;
    setState(() {
      _granted = granted;
      _checking = false;
    });

    // Auto-start the listener once permission is granted.
    if (granted) {
      await _syncService.init();
    }
  }

  Future<void> _openSettings() async {
    await _syncService.requestPermission();
    // Re-check happens automatically via didChangeAppLifecycleState.
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        centerTitle: true,
        title: const Text(
          'Notification Sync',
          style: TextStyle(
            fontWeight: FontWeight.bold,
            color: Colors.black87,
            fontSize: 20,
          ),
        ),
        iconTheme: const IconThemeData(color: Colors.black87),
      ),
      body: _checking
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
              child: Column(
                children: [
                  const Spacer(),
                  // Icon
                  Container(
                    width: 88,
                    height: 88,
                    decoration: BoxDecoration(
                      color: _granted
                          ? _primary.withValues(alpha: 0.12)
                          : Colors.orange.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: Icon(
                      _granted
                          ? Icons.notifications_active
                          : Icons.notifications_off_outlined,
                      size: 42,
                      color: _granted ? _primary : Colors.orange,
                    ),
                  ),
                  const SizedBox(height: 28),

                  // Title
                  Text(
                    _granted
                        ? 'Notification Sync Active!'
                        : 'Enable Notification Access',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFF22252A),
                    ),
                  ),
                  const SizedBox(height: 14),

                  // Description
                  Text(
                    _granted
                        ? 'BachatBot is now listening for payment notifications from eSewa, Khalti, and your bank apps to automatically log transactions.'
                        : 'BachatBot needs Notification Access to read payment notifications from eSewa, Khalti, and bank apps.\n\nWe only read finance-related notifications — your other app notifications stay private.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14.5,
                      height: 1.5,
                      color: Colors.grey.shade600,
                    ),
                  ),
                  const SizedBox(height: 36),

                  // Privacy note
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.blue.shade50,
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: Colors.blue.shade100,
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.shield_outlined,
                            color: Colors.blue.shade700, size: 22),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Only eSewa, Khalti & bank notifications are processed. '
                            'Social media & other apps are never accessed.',
                            style: TextStyle(
                              fontSize: 12.5,
                              height: 1.4,
                              color: Colors.blue.shade800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const Spacer(),

                  // Action button
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _granted
                          ? () => Navigator.pop(context, true)
                          : _openSettings,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _granted ? _primary : Colors.orange,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        elevation: 0,
                      ),
                      child: Text(
                        _granted ? 'Done' : 'Open Settings',
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // Skip option (when not granted)
                  if (!_granted)
                    TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: Text(
                        'Skip for now',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.grey.shade500,
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                ],
              ),
            ),
    );
  }
}
