import 'package:flutter/material.dart';
import '../app_controller.dart';
import '../models/subscription.dart';

class SubscriptionScreen extends StatelessWidget {
  const SubscriptionScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('订阅管理')),
          body: ListView.builder(
            itemCount: controller.subscriptions.length,
            itemBuilder: (context, index) {
              final sub = controller.subscriptions[index];
              return SwitchListTile(
                value: sub.enabled,
                onChanged: (_) => controller.toggleSubscription(sub.id),
                title: Text(sub.name),
                subtitle: Text(_subtitleFor(sub)),
                secondary: IconButton(
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => controller.removeSubscription(sub.id),
                ),
              );
            },
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: () => _showAddDialog(context),
            child: const Icon(Icons.add),
          ),
        );
      },
    );
  }

  /// 订阅行副标题：失败 > 未更新 > 更新时间，三者取优先级最高的一条。
  static String _subtitleFor(ProxySubscription sub) {
    if (sub.lastError != null) {
      return '失败：${sub.lastError}';
    }
    if (sub.lastFetchedAt == null) {
      return '节点数：${sub.nodeCount} · 未更新';
    }
    return '节点数：${sub.nodeCount} · 更新于 ${_formatFetchedAt(sub.lastFetchedAt!)}';
  }

  /// 手写时间格式化：M/d HH:mm（月日不补零，时分补零到两位）。
  static String _formatFetchedAt(DateTime time) {
    final hour = time.hour.toString().padLeft(2, '0');
    final minute = time.minute.toString().padLeft(2, '0');
    return '${time.month}/${time.day} $hour:$minute';
  }

  void _showAddDialog(BuildContext context) {
    final nameController = TextEditingController();
    final urlController = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('添加订阅'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: nameController, decoration: const InputDecoration(labelText: '名称')),
            TextField(controller: urlController, decoration: const InputDecoration(labelText: '订阅 URL')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(
            onPressed: () {
              controller.addSubscription(nameController.text, urlController.text);
              Navigator.pop(context);
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
  }
}
