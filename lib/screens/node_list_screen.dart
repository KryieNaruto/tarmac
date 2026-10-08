// lib/screens/node_list_screen.dart
import 'package:flutter/material.dart';
import '../app_controller.dart';
import '../models/proxy_node.dart';
import '../widgets/connection_bar.dart';
import '../widgets/node_tile.dart';

class NodeListScreen extends StatefulWidget {
  const NodeListScreen({super.key, required this.controller});
  final AppController controller;

  @override
  State<NodeListScreen> createState() => _NodeListScreenState();
}

class _NodeListScreenState extends State<NodeListScreen> {
  /// 超时分区是否展开。默认收起：打开列表先看可用 + 未测的节点。
  /// 刻意不持久化——每次进页面都回到收起态。
  bool _showTimedOut = false;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        // 按 delayMs 语义分区，两组的相对顺序都保持 nodes 的原始顺序
        // （nodes 已按延迟升序排好，所以可用/未测在前、超时垫底）。
        //   delayMs == null  → 未测速，算可见
        //   delayMs >= 0     → 可用，算可见
        //   delayMs < 0      → 超时，进收起分区
        //
        // 注意（有意为之）：测速进行中，节点被逐个测出「超时」后会立刻跳进
        // 这个收起分区、从可见列表消失。列表因此在测速时不断"缩水"，这正
        // 是想要的效果——坏节点自动沉下去，可用的往上浮，不必等整轮测速结束。
        // 进度行不在 ListView 内，不受此影响。
        final visible = <ProxyNode>[];
        final timedOut = <ProxyNode>[];
        for (final node in controller.nodes) {
          final delay = node.delayMs;
          if (delay != null && delay < 0) {
            timedOut.add(node);
          } else {
            visible.add(node);
          }
        }

        // 分区头只在超时组非空时占据一个 item 位；超时行仅展开时计入。
        final hasTimedOut = timedOut.isNotEmpty;
        final itemCount =
            visible.length + (hasTimedOut ? 1 : 0) + (_showTimedOut ? timedOut.length : 0);

        return Scaffold(
          appBar: AppBar(title: const Text('Tarmac')),
          body: Column(
            children: [
              ConnectionBar(controller: controller),
              // 上次测速时间：有记录且当前不在测速中才显示（测速中看进度行即可）。
              if (controller.lastRetestAt != null && !controller.retesting)
                _LastRetestRow(controller: controller),
              // 测速进度行：仅在批量测速进行中插入。
              if (controller.retesting) _RetestProgressRow(controller: controller),
              Expanded(
                child: RefreshIndicator(
                  onRefresh: controller.refreshSubscriptions,
                  // 空态只在「一个节点都没有」时用；全是超时节点时 nodes 非空、
                  // 可见组为空，这时照常渲染分区头，绝不当成空列表。
                  child: controller.nodes.isEmpty
                      ? _EmptyNodeList(controller: controller)
                      : ListView.builder(
                          itemCount: itemCount,
                          itemBuilder: (context, index) {
                            if (index < visible.length) {
                              return _buildTile(controller, visible[index]);
                            }
                            final headerIndex = visible.length;
                            if (index == headerIndex) {
                              return _TimedOutHeader(
                                count: timedOut.length,
                                expanded: _showTimedOut,
                                onTap: () => setState(() => _showTimedOut = !_showTimedOut),
                              );
                            }
                            return _buildTile(controller, timedOut[index - headerIndex - 1]);
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

  /// 单行节点。测速过程中 nodes 会按延迟实时重排，靠 key 让 Flutter
  /// 按节点身份复用 element，避免内容串行/闪跳。
  Widget _buildTile(AppController controller, ProxyNode node) {
    final isConnected = controller.connectedNode?.id == node.id;
    return NodeTile(
      key: ValueKey(node.id),
      node: node,
      isConnected: isConnected,
      // 已连接的那行点了不做事（"断开"仍由顶部按钮负责，避免误触断开）。
      onTap: isConnected ? null : () => controller.connectToNode(node),
    );
  }
}

/// 超时节点分区头。刻意做成浅灰、带计时器图标的样子，一眼能看出是可点的
/// 分区开关，而不是又一个节点行。
class _TimedOutHeader extends StatelessWidget {
  const _TimedOutHeader({
    required this.count,
    required this.expanded,
    required this.onTap,
  });

  final int count;
  final bool expanded;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      onTap: onTap,
      leading: const Icon(Icons.timer_off_outlined, color: Colors.grey),
      title: Text(
        expanded ? '收起 $count 个超时节点' : '已收起 $count 个超时节点',
        style: const TextStyle(fontSize: 13, color: Colors.grey),
      ),
      trailing: Icon(expanded ? Icons.expand_less : Icons.expand_more, color: Colors.grey),
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

/// 「上次测速 M/d HH:mm」小号灰字行。仅在历史存在且当前不在测速中时插入。
class _LastRetestRow extends StatelessWidget {
  const _LastRetestRow({required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          '上次测速 ${_formatTime(controller.lastRetestAt!)}',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
      ),
    );
  }
}

/// 手写时间格式化：M/d HH:mm（月日不补零、时分补零两位），例如 10/8 09:05。
/// 刻意不复用 subscription_screen.dart 里的同款函数——那个是 private，跨文件用不了。
String _formatTime(DateTime time) {
  final hour = time.hour.toString().padLeft(2, '0');
  final minute = time.minute.toString().padLeft(2, '0');
  return '${time.month}/${time.day} $hour:$minute';
}
