import '../models/proxy_node.dart';
import 'v2ray_gateway.dart';

class V2rayService {
  V2rayService(this._gateway);
  final V2rayGateway _gateway;

  Future<void> initialize() => _gateway.initialize();

  /// 并发测速。返回值长度恒等于输入 `nodes` 的长度，顺序也与输入一致；
  /// 被 `shouldStop` 提前中断时，未测到的节点原样（delayMs 仍为 null）
  /// 接在已测前缀后面，绝不编造延迟。
  Future<List<ProxyNode>> testDelays(
    List<ProxyNode> nodes, {
    int concurrency = 8,
    void Function(List<ProxyNode> current, int done, int total)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final total = nodes.length;
    final results = <ProxyNode>[];
    for (var i = 0; i < total; i += concurrency) {
      if (shouldStop?.call() ?? false) break;
      final batch = nodes.sublist(i, (i + concurrency).clamp(0, total));
      final tested = await Future.wait(batch.map((node) async {
        final delay = await _gateway.getServerDelay(node.rawLink);
        return node.copyWith(delayMs: delay ?? -1, lastTestedAt: DateTime.now());
      }));
      results.addAll(tested);
      // 每批结束后回调一次；current 恒为「已测前缀 + 未测余量」的完整列表。
      onProgress?.call(
        [...results, ...nodes.sublist(results.length)],
        results.length,
        total,
      );
    }
    return [...results, ...nodes.sublist(results.length)];
  }

  Future<bool> connect(ProxyNode node) async {
    final granted = await _gateway.requestPermission();
    if (!granted) return false;
    await _gateway.start(remark: node.remark, rawLink: node.rawLink);
    return true;
  }

  Future<void> disconnect() => _gateway.stop();

  Stream<V2rayConnectionState> get stateStream => _gateway.stateStream;
}
