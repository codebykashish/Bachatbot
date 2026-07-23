import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import '../api_service.dart';
import 'about_us_screen.dart';
import 'contact_us_screen.dart';
import 'edit_profile_screen.dart';
import 'faqs_screen.dart';
import 'goals_screen.dart';
import 'help_screen.dart';
import 'login_screen.dart';
import 'mock_notification_screen.dart';
import 'notification_preferences_screen.dart';

/// Everything account-configuration/reference related lives here now —
/// split out of ProfileScreen so Profile can focus on "who am I doing
/// financially" (streaks, suggestion, spending habit, income/expense)
/// while Settings answers "how do I configure/manage my account."
class SettingsScreen extends StatefulWidget {
  final Map<String, dynamic> profileData;
  final VoidCallback onProfileChanged;

  const SettingsScreen({
    super.key,
    required this.profileData,
    required this.onProfileChanged,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const Color _primary = Color(0xFF2DBE7F);
  bool _isLoggingOut = false;

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Logout'),
        content: const Text('Are you sure you want to logout?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Logout', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isLoggingOut = true);
    try {
      await ApiService.logout();
      await FirebaseAuth.instance.signOut();
      if (!mounted) return;
      Navigator.pushAndRemoveUntil(
        context,
        MaterialPageRoute(builder: (_) => const LoginScreen()),
        (route) => false,
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Logout failed.'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isLoggingOut = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF7F8FA),
      appBar: AppBar(
        title: const Text('Settings', style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: Colors.white,
        foregroundColor: const Color(0xFF22252A),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionCard(children: [
            _tile(
              icon: Icons.edit_outlined,
              title: 'Edit Profile',
              onTap: () async {
                final saved = await Navigator.push<bool>(
                  context,
                  MaterialPageRoute(
                    builder: (_) => EditProfileScreen(profileData: widget.profileData),
                  ),
                );
                if (saved == true) widget.onProfileChanged();
              },
            ),
            const Divider(height: 1, indent: 52),
            _tile(
              icon: Icons.savings_outlined,
              title: 'Goals',
              subtitle: 'Save toward something specific',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const GoalsScreen()),
              ),
            ),
            const Divider(height: 1, indent: 52),
            _tile(
              icon: Icons.notifications_none_outlined,
              title: 'Notification Preferences',
              subtitle: 'Choose what BachatBot keeps you informed about',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const NotificationPreferencesScreen()),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          _sectionCard(children: [
            _tile(
              icon: Icons.bug_report_outlined,
              title: 'Test Mock Notification',
              subtitle: 'Dev only',
              iconColor: _primary,
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const MockNotificationScreen()),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          _sectionHeader('More'),
          _sectionCard(children: [
            _tile(
              icon: Icons.info_outline,
              title: 'About Us',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AboutUsScreen()),
              ),
            ),
            const Divider(height: 1, indent: 52),
            _tile(
              icon: Icons.mail_outline,
              title: 'Contact Us',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ContactUsScreen(
                    initialName: [
                      (widget.profileData['firstName'] as String?) ?? '',
                      (widget.profileData['lastName'] as String?) ?? '',
                    ].where((s) => s.isNotEmpty).join(' '),
                    initialEmail: (widget.profileData['email'] as String?) ?? '',
                  ),
                ),
              ),
            ),
            const Divider(height: 1, indent: 52),
            _tile(
              icon: Icons.help_outline,
              title: 'FAQs',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const FaqsScreen()),
              ),
            ),
            const Divider(height: 1, indent: 52),
            _tile(
              icon: Icons.support_agent_outlined,
              title: 'Help',
              onTap: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const HelpScreen()),
              ),
            ),
          ]),

          const SizedBox(height: 12),

          _sectionCard(children: [
            ListTile(
              leading: _isLoggingOut
                  ? const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.red),
                    )
                  : const Icon(Icons.logout, color: Colors.red),
              title: const Text('Logout',
                  style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
              onTap: _isLoggingOut ? null : _logout,
            ),
          ]),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4, top: 4),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: Colors.black54,
            letterSpacing: 0.3,
          ),
        ),
      );

  Widget _sectionCard({required List<Widget> children}) => Container(
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.04),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(children: children),
      );

  Widget _tile({
    required IconData icon,
    required String title,
    String? subtitle,
    Color? iconColor,
    required VoidCallback onTap,
  }) =>
      ListTile(
        leading: Icon(icon, color: iconColor ?? _primary),
        title: Text(title),
        subtitle: subtitle != null ? Text(subtitle, style: const TextStyle(fontSize: 11)) : null,
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: onTap,
      );
}
