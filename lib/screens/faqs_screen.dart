import 'package:flutter/material.dart';
import '../widgets/chat_fab.dart';

class FaqsScreen extends StatefulWidget {
  const FaqsScreen({super.key});

  @override
  State<FaqsScreen> createState() => _FaqsScreenState();
}

class _FaqsScreenState extends State<FaqsScreen> {
  static const Color _primary = Color(0xFF2DBE7F);

  final _searchCtrl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  IconData _sectionIcon(String s) {
    switch (s) {
      case 'Getting Started':   return Icons.rocket_launch_outlined;
      case 'Chat & Logging':    return Icons.chat_bubble_outline;
      case 'Budgets & Categories': return Icons.account_balance_wallet_outlined;
      case 'Reports':           return Icons.bar_chart_rounded;
      case 'Notifications':     return Icons.notifications_outlined;
      default:                  return Icons.shield_outlined;
    }
  }

  Color _sectionColor(String s) {
    switch (s) {
      case 'Getting Started':      return _primary;
      case 'Chat & Logging':       return const Color(0xFF7C4DFF);
      case 'Budgets & Categories': return const Color(0xFF2196F3);
      case 'Reports':              return const Color(0xFFF59E0B);
      case 'Notifications':        return const Color(0xFFEF6C00);
      default:                     return const Color(0xFF009688);
    }
  }

  static const List<Map<String, String>> _faqs = [
    // ── Getting Started ────────────────────────────────────────────────────
    {
      'section': 'Getting Started',
      'q': 'What is BachatBot?',
      'a': 'BachatBot is your personal AI expense tracker built for Nepal. Chat in Nepali, Roman Nepali, or English — and it automatically logs expenses, tracks budgets, and generates monthly reports. No forms. No spreadsheets.',
    },
    {
      'section': 'Getting Started',
      'q': 'How do I log my first expense?',
      'a': 'Two ways:\n\n1. Chat — tap the green button and type naturally:\n   • "Momo 250"\n   • "Bus bhada 40 tiryo"\n   • "Bhatbhateni 3400"\n   BachatBot confirms and saves it instantly.\n\n2. Manual — go to Categories → tap any category → use the Add Expense form to enter the amount.',
    },
    {
      'section': 'Getting Started',
      'q': 'How do I log income?',
      'a': 'Type it naturally:\n• "Salary 45000 aayo"\n• "Freelance 5000 payeu"\n• "3k income save gara"\n\nBachatBot will ask for the income type (salary / freelance / gift) and save it automatically.',
    },
    {
      'section': 'Getting Started',
      'q': 'How do I set a budget?',
      'a': 'Two ways:\n1. Chat: "Set my food budget to 5000" or "Change rent to 12000"\n2. Categories screen → tap any category → tap the Edit button\n\nOnce set, BachatBot alerts you when you\'re getting close to the limit.',
    },
    // ── Chat & Logging ────────────────────────────────────────────────────
    {
      'section': 'Chat & Logging',
      'q': 'What languages can I use?',
      'a': 'All three work equally well — even in the same message:\n• Nepali: "नयाँ मोबाइल ४५०००"\n• Roman Nepali: "Momo khada 250, rent 12k pathaye"\n• English: "Bought groceries for Rs 400"',
    },
    {
      'section': 'Chat & Logging',
      'q': 'Can I log multiple expenses in one message?',
      'a': 'Yes! For example:\n• "200 momo, 20 bus ma kharcha bhayo"\n• "Lunch 350 ra coffee 80"\n\nBachatBot splits them into separate transactions and confirms each one.',
    },
    {
      'section': 'Chat & Logging',
      'q': 'How do I undo an expense or income entry?',
      'a': 'Every transaction has an Undo button:\n\n• Activity screen — tap the orange "Undo" button on any expense or income entry.\n• Category page — each expense in the Recent Activity list has an "Undo" button.\n• Income page — each income entry shows an "Undo" button in the Income History section.\n\nTapping Undo removes the record and reverses the financial effect — the budget spent amount decreases for expenses, or the income total adjusts for income entries.',
    },
    {
      'section': 'Chat & Logging',
      'q': 'What happens when I undo an expense?',
      'a': 'The expense entry is removed and your budget is restored:\n\n1. The expense record disappears from the category activity list.\n2. The category\'s "spent" amount decreases by that exact amount.\n3. Your remaining budget goes back up.\n\nA snackbar confirms the undo with the amount and category.',
    },
    {
      'section': 'Chat & Logging',
      'q': 'What if BachatBot doesn\'t understand me?',
      'a': 'It will ask a follow-up. Just reply directly — if it asks "Expense ho ki income?", say "Expense".\n\nTip: keep messages short and specific. "Momo kharcha gayo 250" is clearer than just "250 gayo".',
    },
    // ── Budgets & Categories ──────────────────────────────────────────────
    {
      'section': 'Budgets & Categories',
      'q': 'Will my expense be saved even if I haven\'t set a budget?',
      'a': 'Yes, always. Budgets are optional — expenses are saved regardless. If no budget is set, the category card shows "No budget set" and you can tap it to add one anytime.',
    },
    {
      'section': 'Budgets & Categories',
      'q': 'Why can\'t I set a budget lower than what I\'ve already spent?',
      'a': 'BachatBot protects your records. If you\'ve already spent Rs 500 on Food this month, your Food budget must be at least Rs 500.\n\nThis prevents "negative remaining" values that would make your reports confusing.',
    },
    {
      'section': 'Budgets & Categories',
      'q': 'What does the Savings amount on the Categories screen show?',
      'a': 'It shows your true net savings for the month:\n• If you have declared income: Savings = Income − Total Spent\n• If no income declared: Savings = Total Budget − Total Spent\n\nThis gives you a real picture of how much money you\'re keeping.',
    },
    // ── Reports ──────────────────────────────────────────────────────────
    {
      'section': 'Reports',
      'q': 'Where can I see my monthly report?',
      'a': 'Tap "Reports" in the bottom nav bar. You\'ll see:\n• Total income & total expense\n• Net savings\n• Category-by-category breakdown\n• Overall spending status (Low / Medium / High)\n\nOr ask in chat: "Yo mahina kati kharcha bhayo?"',
    },
    {
      'section': 'Reports',
      'q': 'What do Low, Medium, and High spending levels mean?',
      'a': 'BachatBot color-codes your overall spending status:\n• Low (green) — well within budget, great job!\n• Medium (yellow) — approaching your limits, be mindful\n• High/Overspent (red) — at or over budget, time to cut back\n\nSee it in Reports → Overall Status card.',
    },
    // ── Notifications ────────────────────────────────────────────────────
    {
      'section': 'Notifications',
      'q': 'Can I tap on a notification?',
      'a': 'Yes! Tap any card in the Activity screen to:\n• Mark it as read (green dot disappears)\n• Jump directly to the related category page for budget and expense alerts\n\nIncome alerts are just marked read — no navigation needed.',
    },
    {
      'section': 'Notifications',
      'q': 'Will bank notification sync be available?',
      'a': 'Automatic eSewa, Khalti, and bank SMS parsing is a planned feature coming in a future update. When available, BachatBot will detect payments in the background and ask you to confirm — no typing needed.\n\nFor now, log expenses via Chat or the manual entry form in Categories.',
    },
    {
      'section': 'Notifications',
      'q': 'What triggers a budget alert?',
      'a': 'Three things trigger budget notifications:\n1. You set or update a budget for a category\n2. Your spending reaches 80% of a category budget\n3. You go over budget in any category\n\nAll alerts appear in the Activity screen and can be tapped.',
    },
    // ── Account & Privacy ────────────────────────────────────────────────
    {
      'section': 'Account & Privacy',
      'q': 'Is my data secure?',
      'a': 'Your data lives under your unique Firebase account and is never shared with others. Every API request is verified with your Firebase token — no one else can read your transactions, budgets, or reports.',
    },
    {
      'section': 'Account & Privacy',
      'q': 'How do I update my profile photo?',
      'a': 'Go to Profile → tap the camera icon on your avatar → choose "Upload from Gallery" or "Take Photo". The photo is saved instantly.',
    },
    {
      'section': 'Account & Privacy',
      'q': 'How do I update my name?',
      'a': 'Go to Profile → tap "Edit Profile". Update First Name or Last Name, then tap "Save Changes".\n\nThe updated name appears immediately on your profile header.',
    },
  ];

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? _faqs
        : _faqs.where((f) {
            final q = _query.toLowerCase();
            return f['q']!.toLowerCase().contains(q) ||
                f['a']!.toLowerCase().contains(q) ||
                f['section']!.toLowerCase().contains(q);
          }).toList();

    // Build ordered section list preserving original order
    final sections = <String>[];
    final grouped = <String, List<Map<String, String>>>{};
    for (final faq in filtered) {
      final s = faq['section']!;
      if (!grouped.containsKey(s)) {
        sections.add(s);
        grouped[s] = [];
      }
      grouped[s]!.add(faq);
    }

    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        title: const Text('FAQs',
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 17)),
        backgroundColor: Colors.white,
        foregroundColor: Colors.black87,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: Container(
            color: Colors.white,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _query = v.trim()),
              style: const TextStyle(fontSize: 14),
              decoration: InputDecoration(
                hintText: 'Search questions...',
                hintStyle:
                    TextStyle(color: Colors.grey.shade400, fontSize: 14),
                prefixIcon: Icon(Icons.search, size: 19, color: Colors.grey.shade400),
                suffixIcon: _query.isNotEmpty
                    ? GestureDetector(
                        onTap: () {
                          _searchCtrl.clear();
                          setState(() => _query = '');
                        },
                        child: Icon(Icons.close_rounded,
                            size: 17, color: Colors.grey.shade400),
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFFF1F3F5),
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 0, horizontal: 4),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
        ),
      ),
      body: filtered.isEmpty
          ? Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.search_off_rounded,
                      size: 54, color: Colors.grey.shade200),
                  const SizedBox(height: 12),
                  Text(
                    'No results for "$_query"',
                    style: TextStyle(
                        color: Colors.grey.shade400,
                        fontSize: 15,
                        fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Try different keywords',
                    style: TextStyle(color: Colors.grey.shade300, fontSize: 13),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding:
                  const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
              itemCount: sections.length,
              itemBuilder: (ctx, sIdx) {
                final section = sections[sIdx];
                final items = grouped[section]!;
                final icon = _sectionIcon(section);
                final color = _sectionColor(section);

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (sIdx > 0) const SizedBox(height: 22),
                    // ── Section header ────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.only(left: 2, bottom: 10),
                      child: Row(
                        children: [
                          Container(
                            width: 34,
                            height: 34,
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(icon, color: color, size: 17),
                          ),
                          const SizedBox(width: 10),
                          Text(
                            section,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: color,
                              letterSpacing: 0.1,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 7, vertical: 2),
                            decoration: BoxDecoration(
                              color: color.withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Text(
                              '${items.length}',
                              style: TextStyle(
                                  fontSize: 11,
                                  color: color,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // ── FAQ cards ─────────────────────────────────────────
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.04),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Theme(
                        data: Theme.of(context)
                            .copyWith(dividerColor: Colors.transparent),
                        child: Column(
                          children: items.asMap().entries.map((e) {
                            final isLast = e.key == items.length - 1;
                            return Column(
                              children: [
                                ExpansionTile(
                                  tilePadding: const EdgeInsets.symmetric(
                                      horizontal: 16, vertical: 2),
                                  title: Text(
                                    e.value['q']!,
                                    style: const TextStyle(
                                      fontSize: 13.5,
                                      fontWeight: FontWeight.w600,
                                      color: Color(0xFF22252A),
                                      height: 1.4,
                                    ),
                                  ),
                                  iconColor: color,
                                  collapsedIconColor: Colors.grey.shade400,
                                  expandedAlignment: Alignment.topLeft,
                                  childrenPadding:
                                      const EdgeInsets.fromLTRB(16, 0, 16, 16),
                                  children: [
                                    Divider(
                                        height: 1,
                                        color: Colors.grey.shade100),
                                    const SizedBox(height: 10),
                                    Text(
                                      e.value['a']!,
                                      style: TextStyle(
                                        fontSize: 13.5,
                                        color: Colors.grey.shade600,
                                        height: 1.75,
                                      ),
                                    ),
                                  ],
                                ),
                                if (!isLast)
                                  Divider(
                                      height: 1,
                                      indent: 16,
                                      endIndent: 16,
                                      color: Colors.grey.shade100),
                              ],
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
      floatingActionButton: const ChatFab(),
    );
  }
}
