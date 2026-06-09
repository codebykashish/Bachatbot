import 'package:flutter/material.dart';

class FaqsScreen extends StatelessWidget {
  const FaqsScreen({super.key});

  static const Color _primary = Color(0xFF2DBE7F);

  static const List<Map<String, String>> _faqs = [
    {
      'q': 'What is BachatBot?',
      'a': 'BachatBot is a conversational AI expense tracker for Nepal. '
          'You chat in Nepali, Roman Nepali, or English, and it automatically '
          'logs your expenses, sets budgets, and generates monthly reports — '
          'all without filling any forms.',
    },
    {
      'q': 'What languages can I use?',
      'a': 'You can use:\n'
          '• Nepali Devanagari (नयाँ मोबाइल ४५०००)\n'
          '• Roman Nepali (Momo khada 250 gayo, Rent 12k pathaye)\n'
          '• English (Bought groceries for Rs 400)\n'
          'All three work equally well in the same chat.',
    },
    {
      'q': 'How do I log an expense?',
      'a': 'Just type it naturally in the chat. Examples:\n'
          '• "Momo 250"\n'
          '• "Bus bhada 40 tiryo"\n'
          '• "Bhatbhateni ma 3400 shopping gareko"\n'
          '• "200 momo, 20 bus ma kharcha bhayo"\n'
          'BachatBot will extract the amount and category and confirm with you.',
    },
    {
      'q': 'How do I log income?',
      'a': 'Type it naturally. Examples:\n'
          '• "Salary 45000 aayo"\n'
          '• "Freelance 5000 payeu"\n'
          '• "3k income ma save gara"\n'
          'BachatBot will ask for the type (salary/gift/other) and save it.',
    },
    {
      'q': 'How do I set a budget?',
      'a': 'Two ways:\n'
          '1. Chat: "Set my food budget to 5000" or "Change rent budget to 12000"\n'
          '2. Category page in the app — tap any category to set its budget.',
    },
    {
      'q': 'Will my expense be saved even if I haven\'t set a budget?',
      'a': 'Yes, always. Budgets are optional guidance — expenses are saved '
          'regardless. If no budget is set, the category will show 0/0 on '
          'the cards, and you can set one anytime from the category page.',
    },
    {
      'q': 'How does bank notification sync work?',
      'a': 'When you receive an eSewa, Khalti, or bank SMS, BachatBot detects it '
          'in the background, parses the amount and category, and asks you to '
          'confirm. Once you confirm, it\'s saved as a transaction. You never '
          'have to type anything for digital payments.',
    },
    {
      'q': 'Can I undo an expense I logged by mistake?',
      'a': 'Yes. In the chat, just say:\n'
          '• "Undo last expense"\n'
          '• "Food ko last kharcha hatau"\n'
          'BachatBot will find and remove the most recent matching transaction.',
    },
    {
      'q': 'Where can I see my monthly report?',
      'a': 'Tap "Reports" in the bottom navigation bar. You can also ask '
          'BachatBot directly: "Yo mahina kati kharcha bhayo?" and it will '
          'give you a category breakdown instantly.',
    },
    {
      'q': 'Is my data secure?',
      'a': 'Yes. Your data is stored under your unique Firebase account and '
          'is never shared with other users. The backend verifies your '
          'identity on every request using your Firebase token. No one else '
          'can access your transactions.',
    },
    {
      'q': 'What expense categories are available?',
      'a': 'Food, Transport, Rent, Shopping, Health, Education, Bills, '
          'Entertainment, and Others. BachatBot maps your message to the '
          'right category automatically.',
    },
    {
      'q': 'Can I change my profile photo?',
      'a': 'Yes. Go to Profile → tap the camera icon on your avatar → '
          'choose from Gallery or take a new photo. It\'s saved instantly.',
    },
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('Frequently Asked Questions',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
        backgroundColor: _primary,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      body: ListView.separated(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        itemCount: _faqs.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (context, i) {
          final faq = _faqs[i];
          return Container(
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
              data: Theme.of(context).copyWith(
                dividerColor: Colors.transparent,
              ),
              child: ExpansionTile(
                leading: Container(
                  width: 30,
                  height: 30,
                  decoration: BoxDecoration(
                    color: _primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: _primary,
                      ),
                    ),
                  ),
                ),
                title: Text(
                  faq['q']!,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF22252A),
                  ),
                ),
                expandedAlignment: Alignment.topLeft,
                childrenPadding:
                    const EdgeInsets.fromLTRB(16, 0, 16, 16),
                iconColor: _primary,
                collapsedIconColor: Colors.grey,
                children: [
                  const Divider(height: 1),
                  const SizedBox(height: 10),
                  Text(
                    faq['a']!,
                    style: const TextStyle(
                      fontSize: 13.5,
                      color: Colors.black54,
                      height: 1.65,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
