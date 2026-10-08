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

  /// 连上之后让核心经该节点实测一次请求的默认目标。
  /// 用被墙的域名：能取到就说明流量**真的穿过了该节点**（与所在网络是否封它无关，
  /// 因为这是核心经代理发出的请求，不是本机直连）。
  static const kVerifyUrl = 'https://www.google.com/generate_204';

  /// 连通性校验的目标集合。**全部**通过才算「完全可用」。
  /// 用 twitter.com 主站（不是 abs.twimg.com —— 那个 CDN 域名对机房 IP 是通的，
  /// 拿它校验会把「过不了 X」的节点误判为可用）。
  static const kVerifyUrls = <String>[
    'https://www.google.com/generate_204',
    'https://twitter.com/robots.txt',
  ];

  /// 主校验目标：至少要能过它，才谈得上「能用」。
  static const kPrimaryVerifyUrl = 'https://www.google.com/generate_204';

  /// 连上后经核心实测一次；成功返回毫秒数，取不到数据返回 null。
  Future<int?> verifyConnected({String url = kVerifyUrl}) =>
      _gateway.getConnectedDelay(url);

  /// 经核心逐个实测 [urls]；**全部**成功才返回 true（任一失败即 false）。
  Future<bool> verifyAll(List<String> urls) async {
    for (final url in urls) {
      final delay = await verifyConnected(url: url);
      if (delay == null || delay <= 0) return false;
    }
    return true;
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
