import 'package:flutter/material.dart';
import '../api_service.dart';

class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key});

  @override
  State<TransactionsScreen> createState() =>
      _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  List transactions = [];

  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    final response = await ApiService.get("/transactions");

    setState(() {
      transactions = response["data"]["transactions"];
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Transactions")),
      body: ListView.builder(
        itemCount: transactions.length,
        itemBuilder: (context, index) {
          final t = transactions[index];

          return ListTile(
            leading: Icon(
              t["type"] == "expense"
                  ? Icons.arrow_downward
                  : Icons.arrow_upward,
              color: t["type"] == "expense"
                  ? Colors.red
                  : Colors.green,
            ),
            title: Text(t["category"]),
            subtitle: Text(t["description"] ?? ""),
            trailing: Text("Rs ${t["amount"]}"),
          );
        },
      ),
    );
  }
}