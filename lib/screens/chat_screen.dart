import 'package:flutter/material.dart';
import '../api_service.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final controller = TextEditingController();
  final List<Map<String, dynamic>> messages = [];

  Future<void> send() async {
    final text = controller.text.trim();
    if (text.isEmpty) return;

    controller.clear();

    setState(() {
      messages.add({
        "role": "user",
        "content": text,
      });
    });

    final response =
        await ApiService.post("/chat", {"message": text, "source": "chat"});

    final data = response["data"];

    setState(() {
      messages.add({
        "role": "bot",
        "content": data["reply"],
        "intent": data["intent"],
      });
    });
  }

  Widget buildBubble(Map msg) {
    final isUser = msg["role"] == "user";

    return Align(
      alignment:
          isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.all(8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isUser ? Colors.green : Colors.grey[300],
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(
          msg["content"],
          style: TextStyle(
              color: isUser ? Colors.white : Colors.black),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: messages.map(buildBubble).toList(),
            ),
          ),
          Row(
            children: [
              Expanded(child: TextField(controller: controller)),
              IconButton(onPressed: send, icon: const Icon(Icons.send))
            ],
          )
        ],
      ),
    );
  }
}