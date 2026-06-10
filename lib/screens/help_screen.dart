import 'package:flutter/material.dart';
import '../widgets/chat_fab.dart';

class HelpScreen extends StatelessWidget {
  const HelpScreen({super.key});

  static const Color _primary = Color(0xFF2DBE7F);

  static const List<Map<String, String>> _items = [
    // Getting Started
    {
      'section': 'Getting Started',
      'title': 'How to log your first expense',
      'content': 'Open the Chat screen. Type your expense naturally: '
          '"Momo 250" or "Bus bhada 40 tiryo". BachatBot confirms it and '
          'saves it. That\'s it — no forms, no dropdowns.',
    },
    {
      'section': 'Getting Started',
      'title': 'How to set a budget',
      'content': 'Say "Set food budget to 5000" in the chat, or go to '
          'the Categories screen and tap any category to set its budget. '
          'Once set, BachatBot alerts you when you\'re close to the limit.',
    },
    // Understanding the Chat
    {
      'section': 'Understanding the Chat',
      'title': 'What if BachatBot doesn\'t understand me?',
      'content': 'If your message is unclear, BachatBot will ask a '
          'follow-up question. Answer it directly — for example, if it '
          'asks "Expense ho ki income?", just reply "Expense" or "Income". '
          'Keep messages short and specific for best results.',
    },
    {
      'section': 'Understanding the Chat',
      'title': 'Ambiguous messages — what to do',
      'content': 'For messages like "400 bhada" (could be bus fare or '
          'rent), BachatBot will ask for clarification. Just reply: '
          '"Bus bhada" (Transport) or "Ghar bhada" (Rent). It learns from '
          'your answer.',
    },
    // Managing Transactions
    {
      'section': 'Managing Transactions',
      'title': 'How to undo a logged expense',
      'content': 'In the chat, say "Undo last expense" or "Food ko last '
          'kharcha hatau". BachatBot will find and remove the most recent '
          'matching transaction. You can also delete transactions from the '
          'Transactions screen.',
    },
    {
      'section': 'Managing Transactions',
      'title': 'Understanding pending transactions',
      'content': 'When a bank notification arrives, the transaction '
          'shows as \'pending\' until you confirm. Say "Yes" or "Ho" to '
          'confirm, or "No" to reject. Pending transactions do not count '
          'toward your budget until confirmed.',
    },
    // Bank Notifications
    {
      'section': 'Bank Notifications',
      'title': 'Setting up notification sync',
      'content': 'BachatBot listens to SMS from eSewa, Khalti, IME Pay, '
          'and Nepali banks in the background. Grant notification access '
          'when prompted at app launch. Once enabled, all digital payments '
          'are auto-detected and sent to the chat for confirmation.',
    },
    // Reports & Budgets
    {
      'section': 'Reports & Budgets',
      'title': 'How to view monthly reports',
      'content': 'Tap "Reports" in the bottom navigation. You can see '
          'total income, total expense, net savings, and a full category '
          'breakdown. You can also ask in chat: "Yo mahina ko report '
          'dekhau" or "Kaha dherai kharcha bhayo?"',
    },
    {
      'section': 'Reports & Budgets',
      'title': 'Budget alerts — what do they mean?',
      'content': 'When you\'ve used 80% of a category budget, BachatBot '
          'sends a warning. At 100%, it notifies you that you\'ve overspent. '
          'These alerts appear in the Notifications section. '
          'Budget limits can be changed any time.',
    },
    // Account & Privacy
    {
      'section': 'Account & Privacy',
      'title': 'How to change my profile photo',
      'content': 'Go to Profile → tap the camera icon on your avatar. '
          'Choose "Upload from Gallery" or "Take Photo". The photo is saved '
          'to your account and appears everywhere in the app.',
    },
    {
      'section': 'Account & Privacy',
      'title': 'How to update my name',
      'content': 'Go to Profile → tap "Edit Profile" (pencil icon). '
          'Update First Name or Last Name and tap "Save Changes".',
    },
    {
      'section': 'Account & Privacy',
      'title': 'How to log out',
      'content': 'Scroll to the bottom of the Profile page and tap '
          '"Logout" (shown in red). You will be signed out and taken to '
          'the login screen. Your data is safely stored and will be there '
          'when you log back in.',
    },
  ];

  @override
  Widget build(BuildContext context) {
    // Group items by section
    final sections = <String, List<Map<String, String>>>{};
    for (final item in _items) {
      final s = item['section']!;
      sections.putIfAbsent(s, () => []).add(item);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Help & Guide',
            style: TextStyle(fontWeight: FontWeight.bold)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        children: sections.entries.map((entry) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Section header
              Padding(
                padding: const EdgeInsets.only(left: 4, bottom: 8, top: 4),
                child: Text(
                  entry.key,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _primary,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              Container(
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: Theme(
                  data: Theme.of(context)
                      .copyWith(dividerColor: Colors.transparent),
                  child: Column(
                    children: entry.value.asMap().entries.map((e) {
                      final isLast = e.key == entry.value.length - 1;
                      return Column(
                        children: [
                          ExpansionTile(
                            leading: Container(
                              width: 30,
                              height: 30,
                              decoration: BoxDecoration(
                                color: _primary.withValues(alpha: 0.10),
                                shape: BoxShape.circle,
                              ),
                              child: const Icon(Icons.help_outline,
                                  color: _primary, size: 16),
                            ),
                            title: Text(
                              e.value['title']!,
                              style: const TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: Color(0xFF22252A),
                              ),
                            ),
                            iconColor: _primary,
                            collapsedIconColor: Colors.grey,
                            expandedAlignment: Alignment.topLeft,
                            childrenPadding:
                                const EdgeInsets.fromLTRB(16, 0, 16, 16),
                            children: [
                              const Divider(height: 1),
                              const SizedBox(height: 10),
                              Text(
                                e.value['content']!,
                                style: const TextStyle(
                                  fontSize: 13.5,
                                  color: Colors.black54,
                                  height: 1.65,
                                ),
                              ),
                            ],
                          ),
                          if (!isLast)
                            const Divider(
                                height: 1, indent: 16, endIndent: 16),
                        ],
                      );
                    }).toList(),
                  ),
                ),
              ),
              const SizedBox(height: 14),
            ],
          );
        }).toList(),
      ),
      floatingActionButton: const ChatFab(),
    );
  }
}
