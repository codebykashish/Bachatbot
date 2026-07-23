import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:image_picker/image_picker.dart';
import '../api_service.dart';
import '../theme/health_theme.dart';
import '../utils/behavior_status.dart';
import '../utils/recommendation_copy.dart';
import 'activity_feed_screen.dart';
import 'behavior_screen.dart';
import 'edit_profile_screen.dart';
import 'health_screen.dart';
import 'income_page.dart';
import 'settings_screen.dart';

/// Profile answers "how am I doing financially" — streaks, today's
/// suggestion, spending habit, income/expense — as opposed to Settings
/// (reached via the gear icon), which answers "how do I configure my
/// account." Split apart so this screen stays a daily-glance surface
/// instead of a settings junk drawer.
class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => ProfileScreenState();
}

class ProfileScreenState extends State<ProfileScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  Map<String, dynamic>? _profileData;
  bool _isLoading = true;
  bool _isUploadingPhoto = false;
  double _declaredIncome = 0.0;

  Map<String, dynamic>? _behaviorSummary;
  Map<String, dynamic>? _behaviorState;
  List<dynamic> _milestones = [];
  Map<String, dynamic>? _overallHealth;
  Map<String, dynamic>? _primaryRecommendation;

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
        ApiService.get('/behavior'),
        ApiService.get('/financial-health'),
        ApiService.get('/financial-recommendations'),
      ]);
      final profileRes = results[0];
      final incomeRes = results[1];
      final behaviorRes = results[2];
      final healthRes = results[3];
      final recRes = results[4];
      if (mounted) {
        setState(() {
          _profileData = profileRes['data'] as Map<String, dynamic>?;
          if (incomeRes['success'] == true) {
            _declaredIncome = (incomeRes['data']?['total'] ?? 0).toDouble();
          }
          if (behaviorRes['success'] == true) {
            _behaviorSummary = behaviorRes['data']?['summary'] as Map<String, dynamic>?;
            _behaviorState = behaviorRes['data']?['state'] as Map<String, dynamic>?;
            _milestones = behaviorRes['data']?['milestones'] as List? ?? [];
          }
          _overallHealth = healthRes['success'] == true
              ? (healthRes['data']?['overallHealth'] as Map<String, dynamic>?)
              : null;
          _primaryRecommendation = recRes['success'] == true
              ? (recRes['data']?['primaryRecommendation'] as Map<String, dynamic>?)
              : null;
          _isLoading = false;
        });
      }
    } catch (e) {
      debugPrint('[ProfileScreen] Failed to load profile: $e');
      if (mounted) setState(() => _isLoading = false);
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

  int get _loggingStreak => (_behaviorState?['logging']?['currentStreak'] as num?)?.toInt() ?? 0;

  void _openSettings() {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          profileData: _profileData ?? {},
          onProfileChanged: loadProfile,
        ),
      ),
    );
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
    final healthStatus = _overallHealth?['status'] as String?;
    final healthTheme = HealthTheme.forStatus(healthStatus);
    final habitMeta = behaviorStatusMeta(_behaviorSummary?['status'] as String?);

    return RefreshIndicator(
      onRefresh: loadProfile,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 24),
        child: Column(
          children: [
            // ── Top row: header + settings gear ──────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerRight,
                child: IconButton(
                  icon: const Icon(Icons.settings_outlined, color: Colors.black54),
                  tooltip: 'Settings',
                  onPressed: _openSettings,
                ),
              ),
            ),

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

            const SizedBox(height: 16),

            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: OutlinedButton.icon(
                onPressed: () async {
                  final saved = await Navigator.push<bool>(
                    context,
                    MaterialPageRoute(
                      builder: (_) => EditProfileScreen(profileData: _profileData ?? {}),
                    ),
                  );
                  if (saved == true) loadProfile();
                },
                icon: const Icon(Icons.edit_outlined, size: 16, color: _primary),
                label: const Text('Edit Profile', style: TextStyle(color: _primary, fontWeight: FontWeight.w600)),
                style: OutlinedButton.styleFrom(
                  side: const BorderSide(color: _primary),
                  minimumSize: const Size.fromHeight(42),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // ── Overview row: streak, health, habit ──────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: GestureDetector(
                onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BehaviorScreen())),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(color: Colors.black.withValues(alpha: 0.04), blurRadius: 10, offset: const Offset(0, 4)),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: _overviewStat(
                          emoji: '🔥',
                          label: 'Streak',
                          value: '$_loggingStreak days',
                          color: const Color(0xFFE67E22),
                        ),
                      ),
                      Container(width: 1, height: 36, color: Colors.grey.shade200),
                      Expanded(
                        child: GestureDetector(
                          onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HealthScreen())),
                          child: _overviewStat(
                            emoji: healthStatus == 'red' ? '🔴' : (healthStatus == 'amber' ? '🟡' : '🟢'),
                            label: 'Health',
                            value: healthStatus == 'red' ? 'Needs attention' : (healthStatus == 'amber' ? 'Stable' : 'Good shape'),
                            color: healthTheme.statusColor,
                          ),
                        ),
                      ),
                      Container(width: 1, height: 36, color: Colors.grey.shade200),
                      Expanded(
                        child: _overviewStat(
                          emoji: habitMeta.emoji,
                          label: 'Habit',
                          value: habitMeta.label,
                          color: habitMeta.color,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(height: 20),

            // ── Achievements preview ──────────────────────────────────────────
            if (_milestones.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Achievements', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
                    GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BehaviorScreen())),
                      child: const Text('See all', style: TextStyle(fontSize: 12.5, color: _primary, fontWeight: FontWeight.w600)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                height: 92,
                child: ListView.separated(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: _milestones.length,
                  separatorBuilder: (_, __) => const SizedBox(width: 10),
                  itemBuilder: (context, i) {
                    final m = _milestones[i] as Map<String, dynamic>;
                    final unlocked = m['unlocked'] == true;
                    final isNew = unlocked && _isRecentlyUnlocked(m['unlockedAt'] as String?);
                    return GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const BehaviorScreen())),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Container(
                            width: 78,
                            padding: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              color: unlocked ? Colors.white : Colors.grey.shade100,
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: unlocked ? const Color(0xFFE67E22).withValues(alpha: 0.3) : Colors.grey.shade300,
                              ),
                            ),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  unlocked ? Icons.emoji_events : Icons.lock_outline,
                                  color: unlocked ? const Color(0xFFE67E22) : Colors.grey.shade400,
                                  size: 26,
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  m['title'] as String? ?? '',
                                  textAlign: TextAlign.center,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                    color: unlocked ? Colors.black87 : Colors.grey.shade500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          if (isNew)
                            Positioned(
                              top: -4,
                              right: -4,
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE0223B),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: const Text('NEW', style: TextStyle(fontSize: 8, color: Colors.white, fontWeight: FontWeight.bold)),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 20),
            ],

            // ── Today's suggestion ─────────────────────────────────────────────
            if (_primaryRecommendation != null) ...[
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: GestureDetector(
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HealthScreen())),
                  child: _suggestionCard(healthTheme, recommendationCopy(_primaryRecommendation!)),
                ),
              ),
              const SizedBox(height: 20),
            ],

            // ── Income / Expense ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const ActivityFeedScreen(initialFilter: 'transactions'),
                        ),
                      ),
                      child: _statCard(
                        icon: Icons.receipt_long_outlined,
                        label: 'This Month Expense',
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
                      ).then((_) => loadProfile()),
                      child: _statCard(
                        icon: Icons.account_balance_wallet_outlined,
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

            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }

  bool _isRecentlyUnlocked(String? unlockedAt) {
    if (unlockedAt == null) return false;
    final parsed = DateTime.tryParse(unlockedAt);
    if (parsed == null) return false;
    return DateTime.now().difference(parsed).inDays <= 7;
  }

  Widget _overviewStat({
    required String emoji,
    required String label,
    required String value,
    required Color color,
  }) {
    return Column(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 20)),
        const SizedBox(height: 6),
        Text(value, style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.bold, color: color), textAlign: TextAlign.center),
        const SizedBox(height: 2),
        Text(label, style: TextStyle(fontSize: 10.5, color: Colors.grey.shade500)),
      ],
    );
  }

  Widget _suggestionCard(HealthTheme theme, ({String headline, String detail}) copy) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.cardTint,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.accent.withValues(alpha: 0.25)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.arrow_circle_right_outlined, color: theme.accent, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text("Today's suggestion", style: TextStyle(fontSize: 11, color: Colors.grey.shade600, fontWeight: FontWeight.w600)),
                const SizedBox(height: 3),
                Text(copy.headline, style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14, color: theme.statusColor)),
                const SizedBox(height: 3),
                Text(copy.detail, style: const TextStyle(fontSize: 12.5, color: Colors.black87, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _statCard({
    required IconData icon,
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
          Icon(icon, color: valueColor, size: 22),
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
}
