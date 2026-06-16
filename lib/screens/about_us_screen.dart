import 'package:flutter/material.dart';
import '../widgets/chat_fab.dart';

class AboutUsScreen extends StatelessWidget {
  const AboutUsScreen({super.key});

  static const Color _primary = Color(0xFF2DBE7F);

  // ── Features (no emojis — icon + title + desc) ───────────────────────────
  static const List<Map<String, dynamic>> _features = [
    {
      'icon': Icons.record_voice_over_outlined,
      'title': 'Natural Language Tracking',
      'desc':
          'Say "Momo 250" or "Rent 12k pathaye" in Nepali, Roman Nepali, or English — BachatBot saves it instantly. No forms needed.',
    },
    {
      'icon': Icons.account_balance_wallet_outlined,
      'title': 'Budget Management',
      'desc':
          'Set monthly limits per category via chat or the Categories screen. BachatBot warns you before you overspend.',
    },
    {
      'icon': Icons.bar_chart_rounded,
      'title': 'Monthly Reports',
      'desc':
          'Track income vs expense vs savings every month. See Low / Medium / High spending status at a glance.',
    },
    {
      'icon': Icons.translate_outlined,
      'title': 'Bilingual Chat',
      'desc':
          'The chat interface understands Nepali and English — even mixed in the same message. Switch freely, no settings needed.',
    },
    {
      'icon': Icons.edit_note_rounded,
      'title': 'Manual Expense Entry',
      'desc':
          'Prefer tapping over typing? Go to Categories → tap any category → use the Add Expense form for quick manual logging.',
    },
  ];

  // ── Coming Soon ──────────────────────────────────────────────────────────
  static const List<String> _roadmap = [
    'Notification Sync (eSewa / Khalti)',
    'Shared wallets',
    'Recurring expenses',
    'Voice input',
    'WhatsApp bot',
    'AI financial advisor',
    'Export PDF / Excel',
  ];

  // ── Team ─────────────────────────────────────────────────────────────────
  static const List<Map<String, String>> _team = [
    {
      'name': 'Kashish Dhami',
      'role': 'Backend & AI Lead',
      'email': 'kashish_dhami_a25@sunway.edu.np',
    },
    {
      'name': 'Luniva Shrestha',
      'role': 'Database & Architecture',
      'email': 'luniva_shrestha_a25@sunway.edu.np',
    },
    {
      'name': 'Namrata Lamichhane',
      'role': 'Flutter Frontend Lead',
      'email': 'namrata_lamichhane_a25@sunway.edu.np',
    },
    {
      'name': 'Sabitra Pachhai',
      'role': 'Flutter Frontend & DevOps',
      'email': 'sabitra_pachhai_a25@sunway.edu.np',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('About BachatBot',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Hero ────────────────────────────────────────────────────────
            Center(
              child: Column(
                children: [
                  const SizedBox(height: 8),
                  Container(
                    width: 80,
                    height: 80,
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.smart_toy_outlined,
                        color: _primary, size: 44),
                  ),
                  const SizedBox(height: 14),
                  const Text(
                    'BachatBot',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.bold,
                      color: _primary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Know your kharcha, grow your bachat.',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 15,
                      color: Colors.grey,
                      fontStyle: FontStyle.italic,
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Divider(
                      color: _primary, thickness: 1.5, indent: 60, endIndent: 60),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── What is BachatBot? ──────────────────────────────────────────
            _sectionHeading('What is BachatBot?'),
            _card(
              child: const Text(
                'BachatBot is Nepal\'s first truly conversational expense tracker '
                'designed for students and young professionals. Instead of filling '
                'boring forms, you simply chat in Nepali, Roman Nepali, or English '
                '— and BachatBot automatically logs your expenses, tracks budgets, '
                'and gives you smart financial insights.',
                style: TextStyle(
                    fontSize: 14.5, height: 1.6, color: Color(0xFF22252A)),
              ),
            ),

            const SizedBox(height: 20),

            // ── Key Features ────────────────────────────────────────────────
            _sectionHeading('Key Features'),
            ..._features.map((f) => _featureTile(
                  f['icon'] as IconData,
                  f['title'] as String,
                  f['desc'] as String,
                )),

            const SizedBox(height: 20),

            // ── Coming Soon ─────────────────────────────────────────────────
            _sectionHeading('Coming Soon'),
            _card(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _roadmap.map((item) => _chip(item)).toList(),
              ),
            ),

            const SizedBox(height: 20),

            // ── Meet the Team ───────────────────────────────────────────────
            _sectionHeading('Meet the Team'),
            ..._team.map((m) => _teamCard(
                  m['name']!,
                  m['role']!,
                  m['email']!,
                )),

            const SizedBox(height: 28),

            // ── Footer ──────────────────────────────────────────────────────
            Center(
              child: Column(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
                    decoration: BoxDecoration(
                      color: _primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text(
                      'TEAM SANKALPA',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        color: _primary,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    '© 2025 BachatBot — Educational Project, Sunway College',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
            ),
          ],
        ),
      ),
      floatingActionButton: const ChatFab(),
    );
  }

  Widget _sectionHeading(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 10, left: 2),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w700,
            color: Color(0xFF22252A),
          ),
        ),
      );

  Widget _card({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        margin: const EdgeInsets.only(bottom: 4),
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
        child: child,
      );

  Widget _featureTile(IconData icon, String title, String desc) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(16),
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
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: _primary.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: _primary, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF22252A),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    desc,
                    style: const TextStyle(
                        fontSize: 13, color: Colors.black54, height: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      );

  Widget _chip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: _primary.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(
          label,
          style: const TextStyle(
              fontSize: 12.5, color: _primary, fontWeight: FontWeight.w600),
        ),
      );

  Widget _teamCard(String name, String role, String email) {
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
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
      child: Row(
        children: [
          CircleAvatar(
            radius: 24,
            backgroundColor: _primary.withValues(alpha: 0.12),
            child: Text(
              initials,
              style: const TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: _primary),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF22252A)),
                ),
                const SizedBox(height: 2),
                Text(
                  role,
                  style: const TextStyle(fontSize: 12.5, color: Colors.black54),
                ),
                const SizedBox(height: 3),
                Text(
                  email,
                  style: TextStyle(fontSize: 11.5, color: Colors.grey.shade500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
