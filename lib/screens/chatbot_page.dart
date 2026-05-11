import 'package:flutter/material.dart';
import 'chat_screen.dart';

/// Wrapper page for the chat screen.
/// Pops with `true` when the user sends at least one message so the caller
/// (MainScreen) knows to refresh the home totals and budget categories.
class ChatBotPage extends StatelessWidget {
  const ChatBotPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFF6F7F9),
      appBar: AppBar(
        backgroundColor: Colors.white,
        elevation: 0.5,
        leading: BackButton(
          color: Colors.black87,
          onPressed: () => Navigator.pop(context, ChatScreen.messageSent),
        ),
        title: const Text(
          'BachatBot AI',
          style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
        ),
        foregroundColor: Colors.black87,
      ),
      body: const ChatScreen(),
    );
  }
}