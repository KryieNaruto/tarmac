// lib/widgets/node_tile.dart
import 'package:flutter/material.dart';
import '../models/proxy_node.dart';

class NodeTile extends StatelessWidget {
  const NodeTile({super.key, required this.node, this.onTap});

  final ProxyNode node;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      title: Text(node.remark),
      leading: Chip(label: Text(node.protocol.toUpperCase())),
      trailing: Text(
        _delayLabel(node.delayMs),
        style: TextStyle(color: _delayColor(node.delayMs), fontWeight: FontWeight.bold),
      ),
    );
  }

  static String _delayLabel(int? delayMs) {
    if (delayMs == null) return '未测速';
    if (delayMs < 0) return '超时';
    return '${delayMs}ms';
  }

  static Color _delayColor(int? delayMs) {
    if (delayMs == null) return Colors.grey;
    if (delayMs < 0) return Colors.grey;
    if (delayMs < 150) return Colors.green;
    if (delayMs < 400) return Colors.orange;
    return Colors.red;
  }
}
