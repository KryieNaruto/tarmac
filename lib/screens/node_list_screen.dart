// lib/screens/node_list_screen.dart
import 'package:flutter/material.dart';
import '../app_controller.dart';
import '../widgets/connection_bar.dart';
import '../widgets/node_tile.dart';

class NodeListScreen extends StatelessWidget {
  const NodeListScreen({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(title: const Text('Tarmac')),
          body: Column(
            children: [
              ConnectionBar(controller: controller),
              // 测速进度行：仅在批量测速进行中插入。
              if (controller.retesting) _RetestProgressRow(controller: controller),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: controller.refreshSubscriptions,
                  child: controller.nodes.isEmpty
                      ? _EmptyNodeList(controller: controller)
                      : ListView.builder(
                          itemCount: controller.nodes.length,
                          itemBuilder: (context, index) {
                            final node = controller.nodes[index];
                            // 测速过程中 nodes 会按延迟实时重排，靠 key 让 Flutter
                            // 按节点身份复用 element，避免内容串行/闪跳。
                            return NodeTile(key: ValueKey(node.id), node: node);
                          },
                        ),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: controller.busy ? null : controller.retestAll,
            tooltip: '仅重测',
            child: controller.busy
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.speed),
          ),
        );
      },
    );
  }
}

/// 空态提示。外层刻意保持 ListView（RefreshIndicator 的子节点），
/// 这样节点为空时下拉刷新依然有效——换成 Center/Column 会让下拉失效。
class _EmptyNodeList extends StatelessWidget {
  const _EmptyNodeList({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return ListView(
      children: [
        SizedBox(height: MediaQuery.of(context).size.height / 4),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              controller.busy
                  ? '正在拉取订阅…'
                  : '还没有节点\n下拉刷新订阅，或到「订阅」页检查订阅源',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ],
    );
  }
}

/// 测速进度 + 停止按钮。抽成独立 widget，避免堆进 Column 的 children。
class _RetestProgressRow extends StatelessWidget {
  const _RetestProgressRow({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final total = controller.retestTotal;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: LinearProgressIndicator(
              // total 为 0 时用不确定进度（null），避免除零。
              value: total > 0 ? controller.retestDone / total : null,
            ),
          ),
          const SizedBox(width: 12),
          Text('测速中 ${controller.retestDone}/$total'),
          TextButton(
            onPressed: controller.cancelRetest,
            child: const Text('停止'),
          ),
        ],
      ),
    );
  }
}
