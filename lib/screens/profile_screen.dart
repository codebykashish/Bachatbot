import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import '../api_service.dart';
import 'edit_profile_screen.dart';
import 'notification_screen.dart';
import 'income_page.dart';
import 'login_screen.dart';
import 'mock_notification_screen.dart';
import 'about_us_screen.dart';
import 'contact_us_screen.dart';
import 'faqs_screen.dart';
import 'help_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => ProfileScreenState();
}

class ProfileScreenState extends State<ProfileScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  Map<String, dynamic>? _profileData;
  bool _isLoading = true;
  bool _isLoggingOut = false;
  bool _isUploadingPhoto = false;
  double _declaredIncome = 0.0;

  @override
  void initState() {
    super.initState();
    loadProfile();
  }

  void refresh() => loadProfile();

  Future<void> loadProfile() async {
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        ApiService.get('/profile'),
        ApiService.get('/income'),
      ]);
      final profileRes = results[0];
      final incomeRes = results[1];
      if (mounted) {
        setState(() {
          _profileData = profileRes['data'] as Map<String, dynamic>?;
          if (incomeRes['success'] == true) {
            _declaredIncome = (incomeRes['data']?['total'] ?? 0).toDouble();
          }
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[ProfileScreen] Failed to load profile: $e');
      if (mounted) setState(() => _isLoading = false);
    }
  }

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

  Future<void> _showPhotoOptions() async {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.grey.shade300,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Upload from Gallery'),
              onTap: () {
                Navigator.pop(ctx);
                _uploadProfilePhoto(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Take Photo'),
              onTap: () {
                Navigator.pop(ctx);
                _uploadProfilePhoto(ImageSource.camera);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _uploadProfilePhoto(ImageSource source) async {
    try {
      final picker = ImagePicker();
      final XFile? picked = await picker.pickImage(
        source: source,
        imageQuality: 80,
        maxWidth: 800,
        preferredCameraDevice: source == ImageSource.camera
            ? CameraDevice.front
            : CameraDevice.rear,
      );
      if (picked == null) return;

      setState(() => _isUploadingPhoto = true);

      final user = FirebaseAuth.instance.currentUser;
      if (user == null) throw Exception('Not logged in');

      final token = await user.getIdToken(true);

      // Step 1 — Upload image; backend handles Cloudinary
      final uri = Uri.parse('${ApiService.baseUrl}/upload/profile-photo');
      final request = http.MultipartRequest('POST', uri)
        ..headers['Authorization'] = 'Bearer $token'
        ..files.add(await http.MultipartFile.fromPath(
          'file',
          picked.path,
          contentType: MediaType('image', 'jpeg'),
        ));

      final streamed = await request.send();
      final uploadResponse = await http.Response.fromStream(streamed);

      if (uploadResponse.statusCode != 200) {
        final err = jsonDecode(uploadResponse.body);
        throw Exception(err['detail']?['message'] ?? 'Upload failed');
      }

      final uploadData = jsonDecode(uploadResponse.body);
      final photoUrl = uploadData['photoUrl'] as String;

      // Step 2 — Save Cloudinary URL to profile
      final patchResponse = await http.patch(
        Uri.parse('${ApiService.baseUrl}/profile'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'photoUrl': photoUrl}),
      );

      if (patchResponse.statusCode == 200) {
        if (mounted) {
          setState(() => _profileData?['photoUrl'] = photoUrl);
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Profile photo updated!'),
              backgroundColor: Colors.green,
            ),
          );
        }
      } else {
        final err = jsonDecode(patchResponse.body);
        throw Exception(err['detail']?['message'] ?? 'Failed to save photo');
      }
    } catch (e) {
      debugPrint('[ProfileScreen] Photo upload failed: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Photo upload failed: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isUploadingPhoto = false);
    }
  }


  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    final firstName = (_profileData?['firstName'] as String?) ?? '';
    final lastName = (_profileData?['lastName'] as String?) ?? '';
    final email = (_profileData?['email'] as String?) ?? '';
    final photoUrl = _profileData?['photoUrl'] as String?;
    final totalIncome = _declaredIncome > 0
        ? _declaredIncome
        : ((_profileData?['totalIncome'] as num?)?.toDouble() ?? 0);
    final totalExpense =
        (_profileData?['totalExpense'] as num?)?.toDouble() ?? 0;
    final initials =
        '${firstName.isNotEmpty ? firstName[0] : ''}${lastName.isNotEmpty ? lastName[0] : ''}'
            .toUpperCase();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          // ── Profile Header ───────────────────────────────────────────────
          Column(
            children: [
              Stack(
                children: [
                  CircleAvatar(
                    radius: 52,
                    backgroundColor: _primary.withValues(alpha: 0.15),
                    backgroundImage: (photoUrl != null && photoUrl.isNotEmpty)
                        ? NetworkImage(photoUrl)
                        : null,
                    child: (photoUrl == null || photoUrl.isEmpty)
                        ? Text(
                            initials.isEmpty ? '?' : initials,
                            style: const TextStyle(
                              fontSize: 36,
                              fontWeight: FontWeight.bold,
                              color: _primary,
                            ),
                          )
                        : null,
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _isUploadingPhoto ? null : _showPhotoOptions,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: _primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 2),
                        ),
                        child: _isUploadingPhoto
                            ? const Padding(
                                padding: EdgeInsets.all(6),
                                child: CircularProgressIndicator(
                                    color: Colors.white, strokeWidth: 2),
                              )
                            : const Icon(Icons.camera_alt,
                                color: Colors.white, size: 16),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Text(
                '$firstName $lastName'.trim(),
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF22252A),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                email,
                style: const TextStyle(fontSize: 13, color: Colors.grey),
              ),
            ],
          ),

          const SizedBox(height: 24),

          // ── Quick Stats ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (_) => const NotificationScreen(initialType: 'expense'),
                      ),
                    ),
                    child: _statCard(
                      icon: '💸',
                      label: 'This Month\nExpense',
                      value: 'Rs ${totalExpense.toStringAsFixed(0)}',
                      color: Colors.red.shade50,
                      valueColor: Colors.red.shade700,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const IncomePage()),
                    ),
                    child: _statCard(
                      icon: '💰',
                      label: 'My Income',
                      value: 'Rs ${totalIncome.toStringAsFixed(0)}',
                      color: const Color(0xFFEAFAF3),
                      valueColor: _primary,
                    ),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 20),

          // ── List Sections ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Edit Profile
                _sectionCard(children: [
                  _tile(
                    icon: Icons.edit_outlined,
                    title: 'Edit Profile',
                    onTap: () async {
                      final saved = await Navigator.push<bool>(
                        context,
                        MaterialPageRoute(
                          builder: (_) => EditProfileScreen(
                              profileData: _profileData ?? {}),
                        ),
                      );
                      if (saved == true) loadProfile();
                    },
                  ),
                ]),

                const SizedBox(height: 12),

                // Mock notification (dev only)
                _sectionCard(children: [
                  _tile(
                    icon: Icons.bug_report_outlined,
                    title: 'Test Mock Notification',
                    subtitle: 'Dev only',
                    iconColor: _primary,
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const MockNotificationScreen()),
                    ),
                  ),
                ]),

                const SizedBox(height: 12),

                // More section
                _sectionHeader('More'),
                _sectionCard(children: [
                  _tile(
                    icon: Icons.info_outline,
                    title: 'About Us',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const AboutUsScreen()),
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
                            (_profileData?['firstName'] as String?) ?? '',
                            (_profileData?['lastName'] as String?) ?? '',
                          ].where((s) => s.isNotEmpty).join(' '),
                          initialEmail:
                              (_profileData?['email'] as String?) ?? '',
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
                      MaterialPageRoute(
                          builder: (_) => const FaqsScreen()),
                    ),
                  ),
                  const Divider(height: 1, indent: 52),
                  _tile(
                    icon: Icons.support_agent_outlined,
                    title: 'Help',
                    onTap: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const HelpScreen()),
                    ),
                  ),
                ]),

                const SizedBox(height: 12),

                // Logout
                _sectionCard(children: [
                  ListTile(
                    leading: _isLoggingOut
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(
                                strokeWidth: 2, color: Colors.red))
                        : const Icon(Icons.logout, color: Colors.red),
                    title: const Text('Logout',
                        style: TextStyle(
                            color: Colors.red,
                            fontWeight: FontWeight.w600)),
                    onTap: _isLoggingOut ? null : _logout,
                  ),
                ]),

                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard({
    required String icon,
    required String label,
    required String value,
    required Color color,
    required Color valueColor,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(icon, style: const TextStyle(fontSize: 22)),
          const SizedBox(height: 8),
          Text(label,
              style: const TextStyle(
                  fontSize: 12, color: Colors.black54, height: 1.4)),
          const SizedBox(height: 6),
          Text(value,
              style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                  color: valueColor)),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8, left: 4),
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
        subtitle: subtitle != null
            ? Text(subtitle, style: const TextStyle(fontSize: 11))
            : null,
        trailing: const Icon(Icons.chevron_right, color: Colors.grey),
        onTap: onTap,
      );
}
