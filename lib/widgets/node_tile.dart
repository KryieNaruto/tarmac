// lib/widgets/node_tile.dart
import 'package:flutter/material.dart';
import '../models/proxy_node.dart';

class NodeTile extends StatelessWidget {
  const NodeTile({
    super.key,
    required this.node,
    this.onTap,
    this.isConnected = false,
  });

  final ProxyNode node;
  final VoidCallback? onTap;

  /// 这一行是否就是当前已连接的节点（用于高亮 + 打勾标记）。
  final bool isConnected;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      selected: isConnected,
      title: Text(node.remark),
      leading: Chip(label: Text(node.protocol.toUpperCase())),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 已连接标记：只在当前节点那一行显示，延迟文字与颜色保持不变。
          if (isConnected)
            const Padding(
              padding: EdgeInsets.only(right: 6),
              child: Icon(Icons.check_circle, color: Colors.green, size: 18),
            ),
          Text(
            _delayLabel(node.delayMs),
            style: TextStyle(color: _delayColor(node.delayMs), fontWeight: FontWeight.bold),
          ),
        ],
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
