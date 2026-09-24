import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          '免费公益节点可能被运营方记录流量，不建议登录网银/重要账号',
          style: TextStyle(color: Colors.orange),
        ),
      ),
    );
  }
}
