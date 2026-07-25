import 'package:flutter/material.dart';
import '../screens/chatbot_page.dart';

class ChatFab extends StatelessWidget {
  const ChatFab({super.key});

  static const Color _primary = Color(0xFF2DBE7F);

  @override
  Widget build(BuildContext context) {
    return FloatingActionButton(
      backgroundColor: _primary,
      tooltip: 'Chat with BachatBot',
      onPressed: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ChatBotPage()),
      ),
      child: const Icon(Icons.smart_toy_outlined, color: Colors.white),
    );
  }
}
