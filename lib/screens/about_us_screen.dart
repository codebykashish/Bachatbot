import 'package:flutter/material.dart';

class AboutUsScreen extends StatelessWidget {
  const AboutUsScreen({super.key});

  static const Color _primary = Color(0xFF2DBE7F);

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
            // ── Hero ──────────────────────────────────────────────────────
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
                    child: const Icon(Icons.account_balance_wallet_rounded,
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
                  const Divider(color: _primary, thickness: 1.5, indent: 60, endIndent: 60),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // ── What is BachatBot? ────────────────────────────────────────
            _sectionHeading('What is BachatBot?'),
            _card(
              child: const Text(
                'BachatBot is Nepal\'s first truly conversational expense tracker '
                'designed for students and young professionals. Instead of filling '
                'boring forms, you simply chat in Nepali, Roman Nepali, or English '
                '— and BachatBot automatically logs your expenses, tracks budgets, '
                'and gives you smart financial insights.',
                style: TextStyle(fontSize: 14.5, height: 1.6, color: Color(0xFF22252A)),
              ),
            ),

            const SizedBox(height: 20),

            // ── Key Features ──────────────────────────────────────────────
            _sectionHeading('Key Features'),
            ..._features.map((f) => _featureTile(f['emoji']!, f['title']!, f['desc']!)),

            const SizedBox(height: 20),

            // ── Roadmap ───────────────────────────────────────────────────
            _sectionHeading('Coming Soon'),
            _card(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: _roadmap
                    .map((item) => _chip(item))
                    .toList(),
              ),
            ),

            const SizedBox(height: 20),

            // ── Team ──────────────────────────────────────────────────────
            _sectionHeading('Meet the Team'),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.6,
              children: _team
                  .map((m) => _teamCard(m['name']!, m['role']!))
                  .toList(),
            ),

            const SizedBox(height: 28),

            // ── Footer ────────────────────────────────────────────────────
            Center(
              child: Column(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
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
    );
  }

  static const List<Map<String, String>> _features = [
    {
      'emoji': '🗣️',
      'title': 'Natural Language Tracking',
      'desc': 'Just say "Momo 250" or "Rent 12k pathaye" — BachatBot understands and saves it instantly.',
    },
    {
      'emoji': '📲',
      'title': 'Smart Notification Sync',
      'desc': 'eSewa, Khalti, and bank SMS are auto-parsed. Just confirm with a tap — zero manual typing.',
    },
    {
      'emoji': '💰',
      'title': 'Budget Alerts',
      'desc': 'Set monthly budgets per category. Get warned before you overspend, not after.',
    },
    {
      'emoji': '📊',
      'title': 'Monthly Reports',
      'desc': 'See your income vs expense vs savings every month with a full category breakdown.',
    },
    {
      'emoji': '🌐',
      'title': 'Multi-language Support',
      'desc': 'Works in Nepali (देवनागरी), Roman Nepali, and English.',
    },
  ];

  static const List<String> _roadmap = [
    'Shared wallets',
    'Recurring expenses',
    'Voice input',
    'WhatsApp bot',
    'AI financial advisor',
    'Export PDF / Excel',
  ];

  static const List<Map<String, String>> _team = [
    {'name': 'Kashish', 'role': 'Backend & AI Lead'},
    {'name': 'Namrata', 'role': 'Flutter Frontend Lead'},
    {'name': 'Luniva', 'role': 'Database & Architecture'},
    {'name': 'Sabitra', 'role': 'DevOps & Testing'},
  ];

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

  Widget _featureTile(String emoji, String title, String desc) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
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
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFF22252A))),
                  const SizedBox(height: 4),
                  Text(desc,
                      style: const TextStyle(
                          fontSize: 13, color: Colors.black54, height: 1.5)),
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
              fontSize: 12.5,
              color: _primary,
              fontWeight: FontWeight.w600),
        ),
      );

  Widget _teamCard(String name, String role) {
    final initials = name.isNotEmpty ? name[0].toUpperCase() : '?';
    return Container(
      padding: const EdgeInsets.all(14),
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
            radius: 22,
            backgroundColor: _primary.withValues(alpha: 0.12),
            child: Text(
              initials,
              style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: _primary),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(name,
                    style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF22252A))),
                const SizedBox(height: 2),
                Text(role,
                    style: const TextStyle(
                        fontSize: 11.5, color: Colors.grey),
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
