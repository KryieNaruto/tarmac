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
          body: Column(
            children: [
              // 引导：内置免费源节点存活率低、且多为机房 IP，容易被 X/Twitter 拦，
              // 所以把「自己加机场订阅」这件事直接写在列表上方。
              const Padding(
                padding: EdgeInsets.fromLTRB(16, 12, 16, 8),
                child: Text(
                  '免费公益源节点存活率低，且多为机房 IP（容易被 X/Twitter 拦）。'
                  '想要稳定访问 Google / X，建议在下方添加自己的机场订阅。',
                  style: TextStyle(fontSize: 12, color: Colors.grey),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: controller.subscriptions.length,
                  itemBuilder: (context, index) {
                    final sub = controller.subscriptions[index];
                    return SwitchListTile(
                      value: sub.enabled,
                      onChanged: (_) => controller.toggleSubscription(sub.id),
                      // 标题可点：打开重命名对话框（spec §8「可编辑名字」）。
                      title: InkWell(
                        onTap: () => _showRenameDialog(context, sub),
                        child: Text(sub.name),
                      ),
                      subtitle: Text(_subtitleFor(sub)),
                      secondary: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () => controller.removeSubscription(sub.id),
                      ),
                    );
                  },
                ),
              ),
            ],
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
    showDialog<void>(
      context: context,
      builder: (context) => _AddSubscriptionDialog(controller: controller),
    );
  }

  /// 重命名对话框：预填当前名字，空名字不提交。
  ///
  /// controller 的生命周期交给对话框自己的 State 管（见 `_RenameSubscriptionDialog`），
  /// 这里**不能**在 `showDialog` 之后手动 dispose——Future 在 `Navigator.pop` 时就已经
  /// resolve，而对话框路由的退出动画还没播完，之后 rebuilt 的 TextField 会用到已释放的
  /// controller 而抛「used after being disposed」。
  Future<void> _showRenameDialog(
    BuildContext context,
    ProxySubscription sub,
  ) {
    return showDialog<void>(
      context: context,
      builder: (_) => _RenameSubscriptionDialog(
        sub: sub,
        onSave: (name) => controller.renameSubscription(sub.id, name),
      ),
    );
  }
}

/// 重命名对话框：自己持有 TextEditingController，随 State 一起释放。
class _RenameSubscriptionDialog extends StatefulWidget {
  const _RenameSubscriptionDialog({required this.sub, required this.onSave});

  final ProxySubscription sub;
  final void Function(String name) onSave;

  @override
  State<_RenameSubscriptionDialog> createState() =>
      _RenameSubscriptionDialogState();
}

class _RenameSubscriptionDialogState extends State<_RenameSubscriptionDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.sub.name,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('重命名订阅'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: '名称'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            final newName = _controller.text.trim();
            if (newName.isNotEmpty) {
              widget.onSave(newName);
            }
            Navigator.pop(context);
          },
          child: const Text('保存'),
        ),
      ],
    );
  }
}

/// 添加订阅对话框：点「添加」先**试拉一次**，把「这个源行不行」当场告诉用户，
/// 而不是等加完刷新才发现 0 个节点。失败时对话框不关闭，可改 URL 重试，
/// 也可以「仍然添加」强行入库（源可能只是暂时不可达）。
class _AddSubscriptionDialog extends StatefulWidget {
  const _AddSubscriptionDialog({required this.controller});
  final AppController controller;

  @override
  State<_AddSubscriptionDialog> createState() => _AddSubscriptionDialogState();
}

class _AddSubscriptionDialogState extends State<_AddSubscriptionDialog> {
  final _nameController = TextEditingController();
  final _urlController = TextEditingController();
  bool _checking = false;
  String? _error;

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  /// 名字留空时的兜底：用 URL 的 host（`https://a.com/x` → `a.com`）；
  /// 解析不出 host 就用 URL 原文，绝不让名字变成空串。
  static String _nameFromUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return trimmed;
    final host = Uri.tryParse(trimmed)?.host ?? '';
    return host.isEmpty ? trimmed : host;
  }

  /// 按「填写的名字 > URL host」决定最终名字。
  String get _resolvedName {
    final typed = _nameController.text.trim();
    if (typed.isNotEmpty) return typed;
    return _nameFromUrl(_urlController.text);
  }

  /// 点「添加」：先试拉（不落盘），成功才真正加进去。
  Future<void> _submit() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) {
      setState(() {
        _checking = false;
        _error = '请先填写订阅 URL';
      });
      return;
    }
    final name = _resolvedName;

    setState(() {
      _checking = true;
      _error = null;
    });

    // 只试拉，不落盘：让用户当场知道这个源行不行。
    final probe = ProxySubscription(id: url, name: name, url: url);
    final result = await widget.controller.subscriptionService
        .fetchAndParse(probe, client: widget.controller.httpClient);
    if (!mounted) return;

    if (result.error != null || result.nodes.isEmpty) {
      setState(() {
        _checking = false;
        _error = result.error != null
            ? '✗ 拉取失败：${result.error}'
            : '✗ 这个源没拉到任何节点';
      });
      return;
    }

    await widget.controller.addSubscription(name, url);
    if (!mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    Navigator.pop(context);
    messenger.showSnackBar(
      SnackBar(content: Text('已添加：拉到 ${result.nodes.length} 个节点')),
    );
  }

  /// 拉取失败时的次要出路：源可能只是暂时不可达，允许强制加入。
  Future<void> _forceAdd() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    final name = _resolvedName;
    await widget.controller.addSubscription(name, url);
    if (!mounted) return;
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('添加订阅'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: '名称（可留空）'),
          ),
          TextField(
            controller: _urlController,
            decoration: const InputDecoration(labelText: '订阅 URL'),
          ),
          if (_checking)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text('正在检查这个源…'),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _error!,
                style: const TextStyle(color: Colors.red, fontSize: 13),
              ),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        if (_error != null)
          TextButton(
            onPressed: _checking ? null : _forceAdd,
            child: const Text('仍然添加'),
          ),
        FilledButton(
          onPressed: _checking ? null : _submit,
          child: _checking
              ? const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    SizedBox(width: 8),
                    Text('正在检查这个源…'),
                  ],
                )
              : const Text('添加'),
        ),
      ],
    );
  }
}
