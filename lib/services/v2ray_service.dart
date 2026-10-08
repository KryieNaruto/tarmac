import '../models/proxy_node.dart';
import 'tunnel_probe.dart';
import 'v2ray_gateway.dart';

/// 全量测速的默认并发数。
///
/// 背景：原生侧是 `Executors.newCachedThreadPool()`（**无上限**线程池），每个测速
/// 还会在 Go 核心起一个 outbound，所以"能开多大"没有理论答案，只能在真机上量。
///
/// 32 是真机实测选定的档位（Realme RMX3700，456 个节点，debug 包，
/// `--dart-define=TARMAC_TEST_CONCURRENCY=32`）：全量测速 208 秒，摊到每节点
/// 0.456 秒；对比改动前的基线（~26 分钟 / 554 节点，约 2.82 秒每节点）约快 6.2 倍，
/// 且无崩溃、结果完整（456 条全部落盘）。
///
/// 没有继续往上加的原因：实测中已出现 UI 帧提交超时告警
/// （`SurfaceView didn't commit buffer within 3000ms`），说明 32 已对 UI 线程造成
/// 压力，再加大风险大于收益。
///
/// 换设备 / 换网络还想重测最优档时，可用
/// `flutter build apk --dart-define=TARMAC_TEST_CONCURRENCY=<n>` 在**不改代码**的
/// 前提下扫档（读取仍走 `int.fromEnvironment`）。
const int kTestConcurrency =
    int.fromEnvironment('TARMAC_TEST_CONCURRENCY', defaultValue: 32);

class V2rayService {
  V2rayService(this._gateway, {TunnelProbe? probe})
      : _probe = probe ?? SocksTunnelProbe();
  final V2rayGateway _gateway;
  final TunnelProbe _probe;

  Future<void> initialize() => _gateway.initialize();

  /// 并发测速（滑动窗口 worker 池）。返回值长度恒等于输入 `nodes` 的长度，
  /// 顺序也与输入一致。
  ///
  /// 已测结果按**原索引**回填（worker 是乱序领任务的，不是按前缀推进），
  /// 因此 `onProgress` 的 `current` 是完整列表且与输入同序，但已测/未测
  /// **不是连续前缀**——已测到的位置是实测结果、还没测到的位置保持原样。
  ///
  /// 被 `shouldStop` 提前中断时，未测到的节点原样返回（`delayMs` 仍为 null），
  /// 绝不编造延迟。
  Future<List<ProxyNode>> testDelays(
    List<ProxyNode> nodes, {
    int concurrency = kTestConcurrency,
    void Function(List<ProxyNode> current, int done, int total)? onProgress,
    bool Function()? shouldStop,
  }) async {
    final total = nodes.length;
    if (total == 0) return const [];

    // 已测结果按索引回填；null 表示还没测到。
    final slots = List<ProxyNode?>.filled(total, null);
    var next = 0;   // 下一个待领的索引（Dart 单线程事件循环，自增本身不需要加锁）
    var done = 0;

    Future<void> worker() async {
      while (true) {
        if (shouldStop?.call() ?? false) return;
        final i = next;
        if (i >= total) return;
        next = i + 1;
        final node = nodes[i];
        final delay = await _gateway.getServerDelay(node.rawLink);
        slots[i] = node.copyWith(
          delayMs: delay ?? -1,
          lastTestedAt: DateTime.now(),
        );
        done++;
        onProgress?.call(
          [for (var k = 0; k < total; k++) slots[k] ?? nodes[k]],
          done,
          total,
        );
      }
    }

    // 并发数夹在 [1, total]：既不会开 0 个 worker，也不会开得比节点还多。
    final workers = concurrency.clamp(1, total);
    await Future.wait(List.generate(workers, (_) => worker()));

    // 被 shouldStop 中断时，未测到的节点**原样返回**（delayMs 仍是 null），绝不编造延迟。
    return [for (var k = 0; k < total; k++) slots[k] ?? nodes[k]];
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

  /// 连上后经核心的 SOCKS5 inbound 实测一次「能否到达该目标」。
  ///
  /// 返回的 `1` 只是「通」的占位，**不是真实毫秒数** —— 延迟数字在这里已无意义
  /// （校验只关心通/不通）。返回 null 表示不通。保留 `Future<int?>` 的返回类型，
  /// 是因为 [SmartConnectService] 依赖它（非 null 即「通」）。
  Future<int?> verifyConnected({String url = kVerifyUrl}) async {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return null;
    final ok = await _probe.canReach(
      uri.host,
      port: uri.hasPort ? uri.port : (uri.scheme == 'https' ? 443 : 80),
      path: uri.path.isEmpty ? '/' : uri.path,
    );
    return ok ? 1 : null; // 只表达「通/不通」
  }

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
