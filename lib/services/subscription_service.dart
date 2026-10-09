// lib/services/subscription_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/proxy_node.dart';
import '../models/subscription.dart';
import 'link_meta.dart';

/// Auto-detects whether a subscription body is a base64-encoded blob or
/// already plain-text share links, and returns the plain-text form either way.
String normalizeContent(String rawBody) {
  final trimmed = rawBody.trim();
  try {
    final decoded = utf8.decode(base64.decode(base64.normalize(trimmed)));
    if (decoded.contains('://')) return decoded;
  } catch (_) {
    // not valid base64 — fall through to plain-text handling
  }
  return rawBody;
}

/// GitHub 系内容的前缀式中转镜像(直接把原 URL 拼在后面)。
///
/// 2026-10-08 手机侧实测:`raw.githubusercontent.com` 会被中间盒放行一个
/// 约 32KiB 的突发窗口后停转 —— 小文件偶尔抢在窗口内跑完,大文件基本必卡死。
/// 下列镜像同一时段全部 200 且亚秒级返回,顺序即优先级(gh-proxy.com 最快)。
/// 只对 GitHub 系 URL 生效:前缀式镜像套在别的域名上只会 404。
const List<String> kSubscriptionMirrors = <String>[
  'https://gh-proxy.com/',
  'https://ghproxy.net/',
  'https://ghfast.top/',
];

/// 该 URL 是否指向 GitHub 的原始文件内容。
/// 覆盖 `raw.githubusercontent.com`、`gist.githubusercontent.com`、
/// 以及 `github.com/<owner>/<repo>/raw/<ref>/...` 三种形态。
bool isGitHubRawUrl(Uri uri) {
  // host 大小写不敏感,DNS 层面本就不区分,统一小写后再比。
  final host = uri.host.toLowerCase();
  if (host == 'raw.githubusercontent.com') return true;
  if (host == 'gist.githubusercontent.com') return true;
  // github.com 上只有 /raw/ 这条路径才是原始文件,仓库首页等不是。
  if (host == 'github.com' && uri.path.contains('/raw/')) return true;
  return false;
}

/// 把一个订阅 URL 展开成「依次尝试」的候选链:**直连优先**,其后是镜像。
///
/// 非 GitHub URL 只返回直连本身。已经是镜像格式的 URL 不会被重复套娃
/// —— 镜像域名不满足 [isGitHubRawUrl],自然只回自身。
List<Uri> subscriptionCandidates(Uri original) {
  if (!isGitHubRawUrl(original)) return <Uri>[original];
  // 直接做字符串拼接而非 Uri 的 API 组合:镜像要的就是「原样把整个 URL 接在
  // 域名后面」,用 Uri 组合反而会把嵌套 URL 里的 // 规范化掉。
  return <Uri>[
    original,
    for (final mirror in kSubscriptionMirrors) Uri.parse('$mirror$original'),
  ];
}

class FetchResult {
  FetchResult({required this.nodes, this.error});
  final List<ProxyNode> nodes;
  final String? error;
}

/// 单次请求的内部结果。比 [FetchResult] 多带一个 [retryable] 标志，
/// 只供 [SubscriptionService.fetchAndParse] 判断要不要再试一次；
/// 对外返回的仍然是形状不变的 [FetchResult]。
class _AttemptResult {
  _AttemptResult({required this.nodes, this.error, this.retryable = false});
  final List<ProxyNode> nodes;
  final String? error;
  final bool retryable;
}

class SubscriptionService {
  /// 拉取并解析一个订阅源。
  ///
  /// [maxAttempts] 是**总请求次数上限**（含首次），不再指「重试同一个 URL 的
  /// 次数」。GitHub 系 URL 会展开成「直连 + 若干镜像」的候选链依次尝试，
  /// 链走完还有剩余次数就从头再循环；默认 4 恰好覆盖 GitHub 链的一整遍。
  ///
  /// [timeout] 默认 8s:失败模式是「连上、回 200、body 不动」的卡死,
  /// 只能靠短超时快速换道;实测镜像亚秒级返回,8s 足够宽裕。
  ///
  /// 每次尝试之间等待 [retryBackoff]（最后一次失败后不再等待）。
  /// 只有「可重试」的失败才会换下一条候选，见 [_attempt]。
  Future<FetchResult> fetchAndParse(
    ProxySubscription sub, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 8),
    int maxAttempts = 4,
    Duration retryBackoff = const Duration(milliseconds: 500),
  }) async {
    final httpClient = client ?? http.Client();
    // 候选链只算一次:同一批候选在整个尝试过程中保持不变。
    //
    // Uri.parse 对畸形地址（`: //x`、含空格、坏的 IPv6 字面量等）会抛
    // FormatException,必须在这里就地转成 error —— fetchAndParse 的契约是
    // 「绝不抛异常」,而它上游的 refreshSubscriptions 没有 try/finally,
    // 一旦抛出会把 busy 永久卡在 true,连节点点击都会被静默丢弃。
    // 畸形地址不可重试:再解析一万次也还是畸形,也不该发任何网络请求。
    final List<Uri> candidates;
    try {
      candidates = subscriptionCandidates(Uri.parse(sub.url));
    } catch (e) {
      return FetchResult(nodes: const [], error: '订阅地址无法解析:$e');
    }
    var last = FetchResult(nodes: const [], error: '未发起请求');
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      // 链尾之后从头再循环,非 GitHub 的 1 条链等于反复重试同一个 URL。
      final target = candidates[(attempt - 1) % candidates.length];
      final result = await _attempt(httpClient, target, sub.id, timeout);
      last = FetchResult(nodes: result.nodes, error: result.error);
      if (result.error == null) return last;
      if (!result.retryable) return last;
      // 最后一次失败后不再退避等待，直接返回。
      if (attempt < maxAttempts) await Future.delayed(retryBackoff);
    }
    return last;
  }

  /// 对某一条候选 [target] 发起单次请求并解析。失败时标注是否值得换下一条候选
  /// （[maxAttempts] 的每一次循环就是换一条）：
  /// 网络类异常、以及 5xx / 429（限流或服务端临时故障）可重试；
  /// 其余 4xx（404 / 403 / 401 等）重试无意义，不重试。
  Future<_AttemptResult> _attempt(
    http.Client httpClient,
    Uri target,
    String sourceSubId,
    Duration timeout,
  ) async {
    try {
      final response = await httpClient.get(target).timeout(timeout);
      if (response.statusCode != 200) {
        final retryable =
            response.statusCode >= 500 || response.statusCode == 429;
        return _AttemptResult(
          nodes: const [],
          error: 'HTTP ${response.statusCode}',
          retryable: retryable,
        );
      }
      final content = normalizeContent(response.body);
      final nodes = <ProxyNode>[];
      for (final line in content.split('\n')) {
        final trimmedLine = line.trim();
        if (trimmedLine.isEmpty) continue;
        final meta = extractLinkMeta(trimmedLine);
        if (meta == null) continue;
        nodes.add(ProxyNode(
          id: trimmedLine,
          remark: meta.remark,
          protocol: meta.protocol,
          rawLink: trimmedLine,
          sourceSubId: sourceSubId,
        ));
      }
      // 200 但一个节点都解析不出——截断的 body、镜像返回的 HTML 错误页都
      // 落到这里。当作可重试失败换下一条候选,总好过把一个空订阅当成功。
      if (nodes.isEmpty) {
        return _AttemptResult(
          nodes: const [],
          error: '解析出 0 个节点',
          retryable: true,
        );
      }
      return _AttemptResult(nodes: nodes);
    } catch (e) {
      // TimeoutException / SocketException / http.ClientException /
      // HandshakeException 等一律算网络类失败：限流丢连接时，
      // 光等没用，重开一条连接才有用，所以标为可重试。
      return _AttemptResult(
        nodes: const [],
        error: e.toString(),
        retryable: true,
      );
    }
  }
}

/// Collapses nodes with the same rawLink across subscriptions, keeping the
/// first occurrence encountered.
List<ProxyNode> dedupeNodes(List<ProxyNode> nodes) {
  final seen = <String>{};
  final result = <ProxyNode>[];
  for (final node in nodes) {
    if (seen.add(node.id)) result.add(node);
  }
  return result;
}

/// 把缓存的延迟按 rawLink 合回刚拉取的节点。
/// 命中的节点带上 delayMs 与 testedAt；未命中的保持原样（delayMs 仍为 null）。
/// 纯函数，不改入参。
List<ProxyNode> applyCachedDelays(
  List<ProxyNode> nodes,
  Map<String, int> cachedDelays, {
  DateTime? testedAt,
}) {
  // 空缓存直接返回原列表，避免无谓拷贝。
  if (cachedDelays.isEmpty) return nodes;
  return [
    for (final node in nodes)
      if (cachedDelays.containsKey(node.rawLink))
        node.copyWith(
          delayMs: cachedDelays[node.rawLink],
          lastTestedAt: testedAt,
        )
      else
        node,
  ];
}

/// 按延迟排序：可用节点（delayMs 非 null 且 >= 0）按延迟升序排在前面；
/// 未测速（null）与超时（< 0）保持它们原本的相对顺序、整体沉底。
///
/// 注意：这里用「稳定分区」而不是对整条 list 调 sort —— Dart 的 List.sort
/// 不是稳定排序，会把未测速那一段每次打乱，列表会无谓地乱跳。
List<ProxyNode> sortByDelay(List<ProxyNode> nodes) {
  // 稳定分区：只对可用节点排序，其余按原相对顺序沉底。
  final usable = <ProxyNode>[];
  final rest = <ProxyNode>[];
  for (final node in nodes) {
    final delay = node.delayMs;
    if (delay != null && delay >= 0) {
      usable.add(node);
    } else {
      rest.add(node);
    }
  }
  usable.sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
  return [...usable, ...rest];
}
