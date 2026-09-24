// lib/widgets/connection_bar.dart
import 'package:flutter/material.dart';
import '../app_controller.dart';

class ConnectionBar extends StatelessWidget {
  const ConnectionBar({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final connected = controller.connectedNode != null;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(child: Text(controller.statusMessage)),
          FilledButton(
            onPressed: controller.busy
                ? null
                : (connected ? controller.disconnectNow : controller.smartConnectNow),
            child: Text(connected ? '断开' : '一键连接'),
          ),
        ],
      ),
    );
  }
}
