import 'package:flutter/material.dart';
import 'chat_screen.dart';

class ChatBotPage extends StatelessWidget {
  const ChatBotPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const BackButton(),
        title: const Text('Chatbot'),
      ),
      body: const ChatScreen(),
    );
  }
}