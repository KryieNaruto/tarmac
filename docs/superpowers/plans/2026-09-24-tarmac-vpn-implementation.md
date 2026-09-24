# Tarmac Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a Flutter Android app that fetches free proxy nodes from subscription sources, tests each node's latency, and can auto-cascade through the best-latency candidates until a real connection succeeds.

**Architecture:** Layered Flutter app — pure-Dart parsing/service layer (testable without a device) behind two abstractions (`V2rayGateway`, `ConnectivityProbe`) that isolate the real `flutter_v2ray_client` plugin and network probing from a `ChangeNotifier`-based `AppController`, which drives two screens (node list, subscription management).

**Tech Stack:** Flutter (Android only), `flutter_v2ray_client` (Xray core + VPN tunnel), `shared_preferences` (local persistence), `http` (subscription fetch + connectivity probe). No state-management package, no SQLite/Hive.

**Spec:** `docs/superpowers/specs/2026-09-24-tarmac-vpn-design.md`

## Global Constraints

- Platform: Flutter, Android only, `minSdkVersion` 24
- Core plugin: `flutter_v2ray_client` (MIT) — do not hand-roll proxy protocol parsing or `VpnService` logic
- Persistence: `shared_preferences` only — no SQLite/Hive/external state-management package
- Default built-in subscription sources (exact URLs, verified live 2026-09-24):
  - `https://raw.githubusercontent.com/freefq/free/master/v2` (base64)
  - `https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub` (base64)
  - `https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt` (plain text)
  - `https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/airport_merge_base64.txt` (base64)
- Delay-test concurrency cap: 8 concurrent `getServerDelay` calls
- Smart-connect cascade: top 15 candidates by ascending delay, 5s probe timeout per node, 60s total budget, probe target `https://cp.cloudflare.com/generate_204`
- UI language: Chinese
- Settings screen must show verbatim: "免费公益节点可能被运营方记录流量，不建议登录网银/重要账号"

## Review Focus

- Subscription body that is neither valid base64 nor contains any recognizable `scheme://` link (empty page, HTML error page, rate-limit message) — must not throw; must record `lastError` and yield zero nodes for that source without affecting others.
- The same node appearing in two different subscriptions — dedupe must collapse it into one `ProxyNode`, not one per source.
- User triggers smart-connect when no node has a usable `delayMs` yet (fresh install, never tested) — must return a distinct "no candidates" outcome, not throw on an empty list or silently do nothing.
- User taps disconnect while a smart-connect cascade is mid-probe on some candidate — the cascade must observe the cancellation and stop instead of reconnecting to the next candidate after the user's explicit disconnect.
- A malformed/truncated `vmess://` payload (common in scraped free lists) — metadata extraction must degrade to a fallback remark instead of throwing and aborting the rest of that subscription's lines.

---

## Task 1: Project scaffold + core data models

**Files:**
- Create: `mine/tarmac/pubspec.yaml` (via `flutter create`)
- Create: `mine/tarmac/lib/models/proxy_node.dart`
- Create: `mine/tarmac/lib/models/subscription.dart`
- Test: `mine/tarmac/test/models/proxy_node_test.dart`
- Test: `mine/tarmac/test/models/subscription_test.dart`

**Interfaces:**
- Produces: `class ProxyNode { id, remark, protocol, rawLink, sourceSubId, delayMs (int?), lastTestedAt (DateTime?) }` with `toJson()/fromJson(Map)` and `copyWith(...)`
- Produces: `class ProxySubscription { id, name, url, enabled, lastFetchedAt (DateTime?), nodeCount, lastError (String?) }` with `toJson()/fromJson(Map)` and `copyWith(...)`

- [ ] **Step 1: Scaffold the Flutter project**

```bash
cd /ssd/qiansenwei/workspace/mine
flutter create --org com.qiansenwei --project-name tarmac --platforms android tarmac
cd tarmac
flutter pub add flutter_v2ray_client shared_preferences http
```

Delete the default counter-app boilerplate test since it references widgets we're about to replace:

```bash
rm -f test/widget_test.dart
```

- [ ] **Step 2: Write the failing test for `ProxyNode`**

```dart
// test/models/proxy_node_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';

void main() {
  test('ProxyNode round-trips through JSON', () {
    final node = ProxyNode(
      id: 'vmess://abc',
      remark: '🇯🇵 Japan',
      protocol: 'vmess',
      rawLink: 'vmess://abc',
      sourceSubId: 'sub-1',
      delayMs: 120,
      lastTestedAt: DateTime.utc(2026, 9, 24, 12, 0, 0),
    );

    final restored = ProxyNode.fromJson(node.toJson());

    expect(restored.id, node.id);
    expect(restored.remark, node.remark);
    expect(restored.protocol, node.protocol);
    expect(restored.rawLink, node.rawLink);
    expect(restored.sourceSubId, node.sourceSubId);
    expect(restored.delayMs, 120);
    expect(restored.lastTestedAt, DateTime.utc(2026, 9, 24, 12, 0, 0));
  });

  test('ProxyNode handles null delayMs and lastTestedAt', () {
    final node = ProxyNode(
      id: 'vless://xyz',
      remark: 'test',
      protocol: 'vless',
      rawLink: 'vless://xyz',
      sourceSubId: 'manual',
    );

    final restored = ProxyNode.fromJson(node.toJson());

    expect(restored.delayMs, isNull);
    expect(restored.lastTestedAt, isNull);
  });

  test('copyWith overrides only given fields', () {
    final node = ProxyNode(
      id: 'a',
      remark: 'r',
      protocol: 'ss',
      rawLink: 'a',
      sourceSubId: 'manual',
    );
    final updated = node.copyWith(delayMs: 55);
    expect(updated.delayMs, 55);
    expect(updated.remark, 'r');
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/models/proxy_node_test.dart`
Expected: FAIL — `package:tarmac/models/proxy_node.dart` does not exist.

- [ ] **Step 4: Implement `ProxyNode`**

```dart
// lib/models/proxy_node.dart
class ProxyNode {
  ProxyNode({
    required this.id,
    required this.remark,
    required this.protocol,
    required this.rawLink,
    required this.sourceSubId,
    this.delayMs,
    this.lastTestedAt,
  });

  final String id;
  final String remark;
  final String protocol;
  final String rawLink;
  final String sourceSubId;
  final int? delayMs;
  final DateTime? lastTestedAt;

  ProxyNode copyWith({
    String? remark,
    int? delayMs,
    DateTime? lastTestedAt,
  }) {
    return ProxyNode(
      id: id,
      remark: remark ?? this.remark,
      protocol: protocol,
      rawLink: rawLink,
      sourceSubId: sourceSubId,
      delayMs: delayMs ?? this.delayMs,
      lastTestedAt: lastTestedAt ?? this.lastTestedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'remark': remark,
        'protocol': protocol,
        'rawLink': rawLink,
        'sourceSubId': sourceSubId,
        'delayMs': delayMs,
        'lastTestedAt': lastTestedAt?.toIso8601String(),
      };

  factory ProxyNode.fromJson(Map<String, dynamic> json) => ProxyNode(
        id: json['id'] as String,
        remark: json['remark'] as String,
        protocol: json['protocol'] as String,
        rawLink: json['rawLink'] as String,
        sourceSubId: json['sourceSubId'] as String,
        delayMs: json['delayMs'] as int?,
        lastTestedAt: json['lastTestedAt'] == null
            ? null
            : DateTime.parse(json['lastTestedAt'] as String),
      );
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `flutter test test/models/proxy_node_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 6: Write the failing test for `ProxySubscription`, then implement it the same way**

```dart
// test/models/subscription_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/subscription.dart';

void main() {
  test('ProxySubscription round-trips through JSON', () {
    final sub = ProxySubscription(
      id: 'https://example.com/sub',
      name: 'Example',
      url: 'https://example.com/sub',
      enabled: true,
      lastFetchedAt: DateTime.utc(2026, 9, 24),
      nodeCount: 12,
      lastError: null,
    );

    final restored = ProxySubscription.fromJson(sub.toJson());

    expect(restored.id, sub.id);
    expect(restored.name, 'Example');
    expect(restored.enabled, isTrue);
    expect(restored.nodeCount, 12);
    expect(restored.lastError, isNull);
  });

  test('defaults enabled to true and nodeCount to 0 for new subs', () {
    final sub = ProxySubscription(id: 'u', name: 'n', url: 'u');
    expect(sub.enabled, isTrue);
    expect(sub.nodeCount, 0);
  });
}
```

```dart
// lib/models/subscription.dart
class ProxySubscription {
  ProxySubscription({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.lastFetchedAt,
    this.nodeCount = 0,
    this.lastError,
  });

  final String id;
  String name;
  String url;
  bool enabled;
  DateTime? lastFetchedAt;
  int nodeCount;
  String? lastError;

  ProxySubscription copyWith({
    bool? enabled,
    DateTime? lastFetchedAt,
    int? nodeCount,
    String? lastError,
    bool clearError = false,
  }) {
    return ProxySubscription(
      id: id,
      name: name,
      url: url,
      enabled: enabled ?? this.enabled,
      lastFetchedAt: lastFetchedAt ?? this.lastFetchedAt,
      nodeCount: nodeCount ?? this.nodeCount,
      lastError: clearError ? null : (lastError ?? this.lastError),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        'lastFetchedAt': lastFetchedAt?.toIso8601String(),
        'nodeCount': nodeCount,
        'lastError': lastError,
      };

  factory ProxySubscription.fromJson(Map<String, dynamic> json) =>
      ProxySubscription(
        id: json['id'] as String,
        name: json['name'] as String,
        url: json['url'] as String,
        enabled: json['enabled'] as bool? ?? true,
        lastFetchedAt: json['lastFetchedAt'] == null
            ? null
            : DateTime.parse(json['lastFetchedAt'] as String),
        nodeCount: json['nodeCount'] as int? ?? 0,
        lastError: json['lastError'] as String?,
      );
}
```

Run: `flutter test test/models/`
Expected: PASS (5 tests total)

- [ ] **Step 7: Commit**

```bash
cd /ssd/qiansenwei/workspace/mine/tarmac
git add -A
git commit -m "feat: scaffold Flutter project and add ProxyNode/ProxySubscription models"
```

---

## Task 2: Share-link metadata extractor

**Files:**
- Create: `mine/tarmac/lib/services/link_meta.dart`
- Test: `mine/tarmac/test/services/link_meta_test.dart`

**Interfaces:**
- Consumes: nothing (pure Dart, `dart:convert` only)
- Produces: `class LinkMeta { final String protocol; final String remark; }` and `LinkMeta? extractLinkMeta(String rawLink)`

- [ ] **Step 1: Write the failing tests**

```dart
// test/services/link_meta_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/services/link_meta.dart';

void main() {
  test('extracts remark from trojan share link fragment', () {
    final link = 'trojan://uuid@host:443?security=tls#%F0%9F%87%AF%F0%9F%87%B5Japan';
    final meta = extractLinkMeta(link);
    expect(meta, isNotNull);
    expect(meta!.protocol, 'trojan');
    expect(meta.remark, '🇯🇵Japan');
  });

  test('extracts remark from vless share link fragment', () {
    final link = 'vless://uuid@host:443?encryption=none#US-node';
    final meta = extractLinkMeta(link);
    expect(meta!.protocol, 'vless');
    expect(meta.remark, 'US-node');
  });

  test('falls back to generic remark when fragment missing', () {
    final link = 'ss://base64stuff@host:8388';
    final meta = extractLinkMeta(link);
    expect(meta!.protocol, 'ss');
    expect(meta.remark, 'ss节点');
  });

  test('decodes vmess base64 json payload for remark', () {
    final payload = base64Encode(utf8.encode(jsonEncode({
      'v': '2',
      'ps': '🇸🇬 Singapore',
      'add': 'host.example',
      'port': '443',
      'id': 'uuid',
      'aid': '0',
      'net': 'ws',
    })));
    final link = 'vmess://$payload';
    final meta = extractLinkMeta(link);
    expect(meta!.protocol, 'vmess');
    expect(meta.remark, '🇸🇬 Singapore');
  });

  test('malformed vmess payload degrades to fallback remark instead of throwing', () {
    final link = 'vmess://not-valid-base64!!!';
    final meta = extractLinkMeta(link);
    expect(meta, isNotNull);
    expect(meta!.protocol, 'vmess');
    expect(meta.remark, '未知节点');
  });

  test('vmess payload missing ps field falls back to generic remark', () {
    final payload = base64Encode(utf8.encode(jsonEncode({
      'add': 'host.example',
      'port': '443',
      'id': 'uuid',
    })));
    final meta = extractLinkMeta('vmess://$payload');
    expect(meta!.remark, 'vmess节点');
  });

  test('returns null for unrecognized scheme', () {
    expect(extractLinkMeta('http://example.com'), isNull);
  });

  test('returns null for unparsable garbage line', () {
    expect(extractLinkMeta('not a link at all, just noise'), isNull);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/services/link_meta_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement `extractLinkMeta`**

```dart
// lib/services/link_meta.dart
import 'dart:convert';

class LinkMeta {
  LinkMeta({required this.protocol, required this.remark});
  final String protocol;
  final String remark;
}

const _knownSchemes = {'vmess', 'vless', 'trojan', 'ss', 'socks'};

LinkMeta? extractLinkMeta(String rawLink) {
  final schemeEnd = rawLink.indexOf('://');
  if (schemeEnd == -1) return null;
  final scheme = rawLink.substring(0, schemeEnd).toLowerCase();
  if (!_knownSchemes.contains(scheme)) return null;

  if (scheme == 'vmess') {
    return LinkMeta(protocol: 'vmess', remark: _vmessRemark(rawLink.substring(schemeEnd + 3)));
  }

  final uri = Uri.tryParse(rawLink);
  final fragment = uri?.fragment ?? '';
  final remark = fragment.isNotEmpty ? Uri.decodeComponent(fragment) : '$scheme节点';
  return LinkMeta(protocol: scheme, remark: remark);
}

String _vmessRemark(String base64Payload) {
  try {
    final normalized = base64.normalize(base64Payload.trim());
    final jsonStr = utf8.decode(base64.decode(normalized));
    final map = jsonDecode(jsonStr) as Map<String, dynamic>;
    final ps = map['ps'] as String?;
    if (ps != null && ps.trim().isNotEmpty) return ps;
    return 'vmess节点';
  } catch (_) {
    return '未知节点';
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/services/link_meta_test.dart`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add share-link metadata extractor with graceful malformed-input handling"
```

---

## Task 3: Subscription fetch, format auto-detection, and cross-source dedupe

**Files:**
- Create: `mine/tarmac/lib/services/subscription_service.dart`
- Test: `mine/tarmac/test/services/subscription_service_test.dart`

**Interfaces:**
- Consumes: `LinkMeta? extractLinkMeta(String)` from Task 2; `ProxyNode`, `ProxySubscription` from Task 1
- Produces:
  - `String normalizeContent(String rawBody)` — auto base64/plain detection
  - `class FetchResult { final List<ProxyNode> nodes; final String? error; }`
  - `class SubscriptionService { Future<FetchResult> fetchAndParse(ProxySubscription sub, {http.Client? client}); }`
  - `List<ProxyNode> dedupeNodes(List<ProxyNode> nodes)` — later tasks (AppController) call this across the combined list from all sources

- [ ] **Step 1: Write the failing tests**

```dart
// test/services/subscription_service_test.dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tarmac/models/subscription.dart';
import 'package:tarmac/services/subscription_service.dart';

void main() {
  group('normalizeContent', () {
    test('decodes a base64 blob containing share links', () {
      final raw = 'trojan://a@b:443#x\nvless://c@d:443#y';
      final encoded = base64Encode(utf8.encode(raw));
      expect(normalizeContent(encoded), raw);
    });

    test('passes through plain-text share links unchanged', () {
      const raw = 'vless://c@d:443#y\nvmess://abc';
      expect(normalizeContent(raw), raw);
    });

    test('falls back to raw content for garbage that is not valid base64', () {
      const raw = 'not base64 at all !!! ###';
      expect(normalizeContent(raw), raw);
    });

    test('falls back to raw content when base64-decodable but not link-shaped', () {
      final encoded = base64Encode(utf8.encode('just some unrelated english text'));
      expect(normalizeContent(encoded), encoded);
    });
  });

  group('SubscriptionService.fetchAndParse', () {
    test('parses a base64 subscription body into nodes', () async {
      final raw = 'trojan://a@b:443#Node1\nvless://c@d:443#Node2';
      final body = base64Encode(utf8.encode(raw));
      final client = MockClient((request) async => http.Response(body, 200));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u1', name: 'S1', url: 'https://x/sub');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.error, isNull);
      expect(result.nodes, hasLength(2));
      expect(result.nodes.first.sourceSubId, 'u1');
      expect(result.nodes.first.remark, 'Node1');
    });

    test('parses a plain-text subscription body into nodes', () async {
      const body = 'vless://c@d:443#Node2\nvmess://not-valid!!!';
      final client = MockClient((request) async => http.Response(body, 200));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u2', name: 'S2', url: 'https://x/sub2');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.error, isNull);
      // one valid vless link + one vmess link with a degraded fallback remark
      expect(result.nodes, hasLength(2));
    });

    test('records lastError and yields zero nodes on HTTP failure, without throwing', () async {
      final client = MockClient((request) async => http.Response('', 404));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u3', name: 'S3', url: 'https://x/dead');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.nodes, isEmpty);
      expect(result.error, isNotNull);
    });

    test('records lastError and yields zero nodes on network exception', () async {
      final client = MockClient((request) async => throw Exception('network down'));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u4', name: 'S4', url: 'https://x/unreachable');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.nodes, isEmpty);
      expect(result.error, isNotNull);
    });

    test('empty/garbage body with no recognizable links yields zero nodes, no error thrown', () async {
      final client = MockClient((request) async => http.Response('<html>rate limited</html>', 200));
      final service = SubscriptionService();
      final sub = ProxySubscription(id: 'u5', name: 'S5', url: 'https://x/garbage');

      final result = await service.fetchAndParse(sub, client: client);

      expect(result.nodes, isEmpty);
    });
  });

  group('dedupeNodes', () {
    test('collapses the same rawLink appearing across two different subscriptions', () {
      final a = ProxyNode(id: 'vless://x', remark: 'A', protocol: 'vless', rawLink: 'vless://x', sourceSubId: 'sub-a');
      final b = ProxyNode(id: 'vless://x', remark: 'A-dup', protocol: 'vless', rawLink: 'vless://x', sourceSubId: 'sub-b');
      final c = ProxyNode(id: 'vless://y', remark: 'C', protocol: 'vless', rawLink: 'vless://y', sourceSubId: 'sub-b');

      final result = dedupeNodes([a, b, c]);

      expect(result, hasLength(2));
      expect(result.map((n) => n.id).toSet(), {'vless://x', 'vless://y'});
    });
  });
}
```

Add `import 'package:tarmac/models/proxy_node.dart';` at the top alongside the other imports.

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/services/subscription_service_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement `subscription_service.dart`**

```dart
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

class FetchResult {
  FetchResult({required this.nodes, this.error});
  final List<ProxyNode> nodes;
  final String? error;
}

class SubscriptionService {
  Future<FetchResult> fetchAndParse(
    ProxySubscription sub, {
    http.Client? client,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final httpClient = client ?? http.Client();
    try {
      final response = await httpClient.get(Uri.parse(sub.url)).timeout(timeout);
      if (response.statusCode != 200) {
        return FetchResult(nodes: const [], error: 'HTTP ${response.statusCode}');
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
          sourceSubId: sub.id,
        ));
      }
      return FetchResult(nodes: nodes, error: null);
    } catch (e) {
      return FetchResult(nodes: const [], error: e.toString());
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/services/subscription_service_test.dart`
Expected: PASS (11 tests)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add subscription fetch, base64/plain auto-detection, and cross-source dedupe"
```

---

## Task 4: Local persistence

**Files:**
- Create: `mine/tarmac/lib/services/storage_service.dart`
- Test: `mine/tarmac/test/services/storage_service_test.dart`

**Interfaces:**
- Consumes: `ProxyNode`, `ProxySubscription` from Task 1
- Produces:
  - `List<ProxySubscription> defaultSubscriptions()`
  - `class StorageService { Future<List<ProxySubscription>> loadSubscriptions(); Future<void> saveSubscriptions(List<ProxySubscription>); Future<List<ProxyNode>> loadManualNodes(); Future<void> saveManualNodes(List<ProxyNode>); Future<String?> loadLastConnectedNodeId(); Future<void> saveLastConnectedNodeId(String?); }`

- [ ] **Step 1: Write the failing tests**

```dart
// test/services/storage_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/models/subscription.dart';
import 'package:tarmac/services/storage_service.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('defaultSubscriptions returns the four verified built-in sources, enabled', () {
    final subs = defaultSubscriptions();
    expect(subs, hasLength(4));
    expect(subs.every((s) => s.enabled), isTrue);
    expect(
      subs.map((s) => s.url),
      containsAll([
        'https://raw.githubusercontent.com/freefq/free/master/v2',
        'https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub',
        'https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt',
        'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/airport_merge_base64.txt',
      ]),
    );
  });

  test('loadSubscriptions returns defaults when nothing saved yet', () async {
    final storage = StorageService();
    final subs = await storage.loadSubscriptions();
    expect(subs, hasLength(4));
  });

  test('saveSubscriptions then loadSubscriptions round-trips custom list', () async {
    final storage = StorageService();
    final custom = [ProxySubscription(id: 'x', name: 'Custom', url: 'https://x', enabled: false)];

    await storage.saveSubscriptions(custom);
    final loaded = await storage.loadSubscriptions();

    expect(loaded, hasLength(1));
    expect(loaded.first.name, 'Custom');
    expect(loaded.first.enabled, isFalse);
  });

  test('manual nodes round-trip and default to empty list', () async {
    final storage = StorageService();
    expect(await storage.loadManualNodes(), isEmpty);

    final node = ProxyNode(id: 'a', remark: 'r', protocol: 'ss', rawLink: 'a', sourceSubId: 'manual');
    await storage.saveManualNodes([node]);

    final loaded = await storage.loadManualNodes();
    expect(loaded, hasLength(1));
    expect(loaded.first.id, 'a');
  });

  test('last connected node id round-trips and defaults to null', () async {
    final storage = StorageService();
    expect(await storage.loadLastConnectedNodeId(), isNull);

    await storage.saveLastConnectedNodeId('vless://x');
    expect(await storage.loadLastConnectedNodeId(), 'vless://x');

    await storage.saveLastConnectedNodeId(null);
    expect(await storage.loadLastConnectedNodeId(), isNull);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/services/storage_service_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement `storage_service.dart`**

```dart
// lib/services/storage_service.dart
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/proxy_node.dart';
import '../models/subscription.dart';

const _kSubscriptionsKey = 'tarmac.subscriptions';
const _kManualNodesKey = 'tarmac.manual_nodes';
const _kLastConnectedKey = 'tarmac.last_connected_node_id';

List<ProxySubscription> defaultSubscriptions() => [
      ProxySubscription(
        id: 'https://raw.githubusercontent.com/freefq/free/master/v2',
        name: 'freefq',
        url: 'https://raw.githubusercontent.com/freefq/free/master/v2',
      ),
      ProxySubscription(
        id: 'https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub',
        name: 'Pawdroid',
        url: 'https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub',
      ),
      ProxySubscription(
        id: 'https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt',
        name: 'ermaozi',
        url: 'https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt',
      ),
      ProxySubscription(
        id: 'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/airport_merge_base64.txt',
        name: 'V2RayAggregator',
        url: 'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/airport_merge_base64.txt',
      ),
    ];

class StorageService {
  Future<List<ProxySubscription>> loadSubscriptions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kSubscriptionsKey);
    if (raw == null) return defaultSubscriptions();
    final list = jsonDecode(raw) as List<dynamic>;
    return list
        .map((e) => ProxySubscription.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  Future<void> saveSubscriptions(List<ProxySubscription> subs) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kSubscriptionsKey,
      jsonEncode(subs.map((s) => s.toJson()).toList()),
    );
  }

  Future<List<ProxyNode>> loadManualNodes() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_kManualNodesKey);
    if (raw == null) return [];
    final list = jsonDecode(raw) as List<dynamic>;
    return list.map((e) => ProxyNode.fromJson(e as Map<String, dynamic>)).toList();
  }

  Future<void> saveManualNodes(List<ProxyNode> nodes) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _kManualNodesKey,
      jsonEncode(nodes.map((n) => n.toJson()).toList()),
    );
  }

  Future<String?> loadLastConnectedNodeId() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_kLastConnectedKey);
  }

  Future<void> saveLastConnectedNodeId(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    if (id == null) {
      await prefs.remove(_kLastConnectedKey);
    } else {
      await prefs.setString(_kLastConnectedKey, id);
    }
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/services/storage_service_test.dart`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add shared_preferences-backed storage service with default subscriptions"
```

---

## Task 5: V2ray gateway abstraction (real + fake)

**Files:**
- Create: `mine/tarmac/lib/services/v2ray_gateway.dart`
- Create: `mine/tarmac/test/fakes/fake_v2ray_gateway.dart`
- Test: `mine/tarmac/test/services/fake_v2ray_gateway_test.dart`

**Interfaces:**
- Produces: `enum V2rayConnectionState { disconnected, connecting, connected }`
- Produces: `abstract class V2rayGateway { Future<void> initialize(); Future<bool> requestPermission(); Future<int?> getServerDelay(String rawLink); Future<void> start({required String remark, required String rawLink}); Future<void> stop(); Stream<V2rayConnectionState> get stateStream; }`
- Produces: `class FlutterV2rayGateway implements V2rayGateway` (thin wrapper over `flutter_v2ray_client`; not directly unit-testable — platform channel dependent, exercised only in the on-device check in the final task)
- Produces (test helper): `class FakeV2rayGateway implements V2rayGateway` with scriptable delay results and connect outcomes, used by Tasks 6-7

This task's own tests exercise the fake (to prove the test double behaves correctly before later tasks rely on it) — the real gateway is validated on-device later, not here.

- [ ] **Step 1: Write the failing test for the fake gateway's scripted behavior**

```dart
// test/services/fake_v2ray_gateway_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/services/v2ray_gateway.dart';
import '../fakes/fake_v2ray_gateway.dart';

void main() {
  test('returns scripted delay per rawLink, null for unscripted links', () async {
    final gateway = FakeV2rayGateway(delayScript: {'a': 100, 'b': null});
    expect(await gateway.getServerDelay('a'), 100);
    expect(await gateway.getServerDelay('b'), isNull);
    expect(await gateway.getServerDelay('unscripted'), isNull);
  });

  test('start() emits connecting then connected on the state stream', () async {
    final gateway = FakeV2rayGateway();
    final states = <V2rayConnectionState>[];
    gateway.stateStream.listen(states.add);

    await gateway.start(remark: 'r', rawLink: 'a');
    await Future<void>.delayed(Duration.zero);

    expect(states, [V2rayConnectionState.connecting, V2rayConnectionState.connected]);
  });

  test('stop() emits disconnected', () async {
    final gateway = FakeV2rayGateway();
    final states = <V2rayConnectionState>[];
    gateway.stateStream.listen(states.add);

    await gateway.start(remark: 'r', rawLink: 'a');
    await gateway.stop();
    await Future<void>.delayed(Duration.zero);

    expect(states.last, V2rayConnectionState.disconnected);
  });

  test('requestPermission returns the scripted grant value, default true', () async {
    final granted = FakeV2rayGateway();
    expect(await granted.requestPermission(), isTrue);

    final denied = FakeV2rayGateway(permissionGranted: false);
    expect(await denied.requestPermission(), isFalse);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/services/fake_v2ray_gateway_test.dart`
Expected: FAIL — `v2ray_gateway.dart` and `fake_v2ray_gateway.dart` don't exist.

- [ ] **Step 3: Implement the abstraction, the real wrapper, and the fake**

```dart
// lib/services/v2ray_gateway.dart
import 'package:flutter_v2ray_client/flutter_v2ray.dart';

enum V2rayConnectionState { disconnected, connecting, connected }

abstract class V2rayGateway {
  Future<void> initialize();
  Future<bool> requestPermission();
  Future<int?> getServerDelay(String rawLink);
  Future<void> start({required String remark, required String rawLink});
  Future<void> stop();
  Stream<V2rayConnectionState> get stateStream;
}

/// Thin wrapper over flutter_v2ray_client. Platform-channel dependent —
/// validated on a real device (see the on-device check at the end of this
/// plan), not by host-machine unit tests.
class FlutterV2rayGateway implements V2rayGateway {
  FlutterV2rayGateway() {
    _v2ray = FlutterV2ray(onStatusChanged: (status) {
      _controller.add(
        status.state == 'CONNECTED'
            ? V2rayConnectionState.connected
            : V2rayConnectionState.disconnected,
      );
    });
  }

  late final FlutterV2ray _v2ray;
  final _controller = StreamController<V2rayConnectionState>.broadcast();

  @override
  Future<void> initialize() => _v2ray.initialize(
        notificationIconResourceType: 'mipmap',
        notificationIconResourceName: 'ic_launcher',
      );

  @override
  Future<bool> requestPermission() => _v2ray.requestPermission();

  @override
  Future<int?> getServerDelay(String rawLink) async {
    try {
      final parser = FlutterV2ray.parseFromURL(rawLink);
      return await _v2ray.getServerDelay(config: parser.getFullConfiguration());
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> start({required String remark, required String rawLink}) async {
    _controller.add(V2rayConnectionState.connecting);
    final parser = FlutterV2ray.parseFromURL(rawLink);
    await _v2ray.startV2Ray(
      remark: remark,
      config: parser.getFullConfiguration(),
      blockedApps: null,
      bypassSubnets: null,
      proxyOnly: false,
    );
  }

  @override
  Future<void> stop() async {
    await _v2ray.stopV2Ray();
    _controller.add(V2rayConnectionState.disconnected);
  }

  @override
  Stream<V2rayConnectionState> get stateStream => _controller.stream;
}
```

```dart
// test/fakes/fake_v2ray_gateway.dart
import 'dart:async';
import 'package:tarmac/services/v2ray_gateway.dart';

/// In-memory test double. `delayScript` maps rawLink -> delayMs (null =
/// scripted failure); links not present in the map also resolve to null.
class FakeV2rayGateway implements V2rayGateway {
  FakeV2rayGateway({
    Map<String, int?> delayScript = const {},
    this.permissionGranted = true,
    this.startShouldThrow = false,
  }) : _delayScript = delayScript;

  final Map<String, int?> _delayScript;
  final bool permissionGranted;
  final bool startShouldThrow;

  final _controller = StreamController<V2rayConnectionState>.broadcast();
  bool initialized = false;
  String? lastStartedRawLink;

  @override
  Future<void> initialize() async => initialized = true;

  @override
  Future<bool> requestPermission() async => permissionGranted;

  @override
  Future<int?> getServerDelay(String rawLink) async => _delayScript[rawLink];

  @override
  Future<void> start({required String remark, required String rawLink}) async {
    _controller.add(V2rayConnectionState.connecting);
    if (startShouldThrow) {
      throw Exception('scripted start failure');
    }
    lastStartedRawLink = rawLink;
    _controller.add(V2rayConnectionState.connected);
  }

  @override
  Future<void> stop() async {
    lastStartedRawLink = null;
    _controller.add(V2rayConnectionState.disconnected);
  }

  @override
  Stream<V2rayConnectionState> get stateStream => _controller.stream;
}
```

Add the `import 'dart:async';` to `v2ray_gateway.dart` for `StreamController`.

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/services/fake_v2ray_gateway_test.dart`
Expected: PASS (4 tests)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add V2rayGateway abstraction with real flutter_v2ray_client wrapper and fake test double"
```

---

## Task 6: Connectivity probe + V2rayService (batch delay testing)

**Files:**
- Create: `mine/tarmac/lib/services/connectivity_probe.dart`
- Create: `mine/tarmac/lib/services/v2ray_service.dart`
- Create: `mine/tarmac/test/fakes/fake_connectivity_probe.dart`
- Test: `mine/tarmac/test/services/v2ray_service_test.dart`

**Interfaces:**
- Consumes: `V2rayGateway`, `V2rayConnectionState`, `FakeV2rayGateway` from Task 5; `ProxyNode` from Task 1
- Produces: `abstract class ConnectivityProbe { Future<bool> check({Duration timeout}); }`, `class HttpConnectivityProbe implements ConnectivityProbe`
- Produces: `class V2rayService { Future<void> initialize(); Future<List<ProxyNode>> testDelays(List<ProxyNode> nodes, {int concurrency = 8}); Future<bool> connect(ProxyNode node); Future<void> disconnect(); Stream<V2rayConnectionState> get stateStream; }`
- Produces (test helper): `class FakeConnectivityProbe implements ConnectivityProbe` with a scriptable/controllable result, used by Task 7

- [ ] **Step 1: Write the failing tests**

```dart
// test/services/v2ray_service_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_v2ray_gateway.dart';

ProxyNode _node(String link) => ProxyNode(
      id: link,
      remark: link,
      protocol: 'vless',
      rawLink: link,
      sourceSubId: 'manual',
    );

void main() {
  group('testDelays', () {
    test('fills in delayMs for each node, -1 for failed/timed-out ones', () async {
      final gateway = FakeV2rayGateway(delayScript: {'a': 50, 'b': null, 'c': 300});
      final service = V2rayService(gateway);

      final result = await service.testDelays([_node('a'), _node('b'), _node('c')]);

      final byId = {for (final n in result) n.id: n.delayMs};
      expect(byId['a'], 50);
      expect(byId['b'], -1);
      expect(byId['c'], 300);
    });

    test('sets lastTestedAt on every tested node', () async {
      final gateway = FakeV2rayGateway(delayScript: {'a': 50});
      final service = V2rayService(gateway);

      final result = await service.testDelays([_node('a')]);

      expect(result.single.lastTestedAt, isNotNull);
    });

    test('respects the concurrency cap without dropping any node', () async {
      final links = List.generate(20, (i) => 'link$i');
      final script = {for (final l in links) l: 10};
      final gateway = FakeV2rayGateway(delayScript: script);
      final service = V2rayService(gateway);

      final result = await service.testDelays(
        links.map(_node).toList(),
        concurrency: 8,
      );

      expect(result, hasLength(20));
      expect(result.every((n) => n.delayMs == 10), isTrue);
    });
  });

  group('connect/disconnect', () {
    test('connect() requests permission then starts, returns true on success', () async {
      final gateway = FakeV2rayGateway();
      final service = V2rayService(gateway);

      final ok = await service.connect(_node('a'));

      expect(ok, isTrue);
      expect(gateway.lastStartedRawLink, 'a');
    });

    test('connect() returns false without starting when permission denied', () async {
      final gateway = FakeV2rayGateway(permissionGranted: false);
      final service = V2rayService(gateway);

      final ok = await service.connect(_node('a'));

      expect(ok, isFalse);
      expect(gateway.lastStartedRawLink, isNull);
    });

    test('disconnect() stops the gateway', () async {
      final gateway = FakeV2rayGateway();
      final service = V2rayService(gateway);
      await service.connect(_node('a'));

      await service.disconnect();

      expect(gateway.lastStartedRawLink, isNull);
    });
  });
}
```

```dart
// test/fakes/fake_connectivity_probe.dart
import 'dart:async';
import 'package:tarmac/services/connectivity_probe.dart';

/// Controllable test double. Each call to `check()` consumes the next
/// entry in `results` (defaults to `false` once exhausted). If
/// `pending` is non-null, `check()` waits on that completer instead of
/// resolving immediately, so tests can exercise cancellation races.
class FakeConnectivityProbe implements ConnectivityProbe {
  FakeConnectivityProbe({List<bool> results = const []}) : _results = List.of(results);

  final List<bool> _results;
  Completer<bool>? pending;

  @override
  Future<bool> check({Duration timeout = const Duration(seconds: 5)}) {
    if (pending != null) return pending!.future;
    if (_results.isEmpty) return Future.value(false);
    return Future.value(_results.removeAt(0));
  }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/services/v2ray_service_test.dart`
Expected: FAIL — `v2ray_service.dart` and `connectivity_probe.dart` don't exist.

- [ ] **Step 3: Implement `connectivity_probe.dart` and `v2ray_service.dart`**

```dart
// lib/services/connectivity_probe.dart
import 'package:http/http.dart' as http;

abstract class ConnectivityProbe {
  Future<bool> check({Duration timeout = const Duration(seconds: 5)});
}

class HttpConnectivityProbe implements ConnectivityProbe {
  HttpConnectivityProbe({http.Client? client}) : _client = client ?? http.Client();

  static const _probeUrl = 'https://cp.cloudflare.com/generate_204';
  final http.Client _client;

  @override
  Future<bool> check({Duration timeout = const Duration(seconds: 5)}) async {
    try {
      final response = await _client.get(Uri.parse(_probeUrl)).timeout(timeout);
      return response.statusCode == 204 || response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}
```

```dart
// lib/services/v2ray_service.dart
import '../models/proxy_node.dart';
import 'v2ray_gateway.dart';

class V2rayService {
  V2rayService(this._gateway);
  final V2rayGateway _gateway;

  Future<void> initialize() => _gateway.initialize();

  Future<List<ProxyNode>> testDelays(
    List<ProxyNode> nodes, {
    int concurrency = 8,
  }) async {
    final results = <ProxyNode>[];
    for (var i = 0; i < nodes.length; i += concurrency) {
      final batch = nodes.sublist(i, (i + concurrency).clamp(0, nodes.length));
      final tested = await Future.wait(batch.map((node) async {
        final delay = await _gateway.getServerDelay(node.rawLink);
        return node.copyWith(delayMs: delay ?? -1, lastTestedAt: DateTime.now());
      }));
      results.addAll(tested);
    }
    return results;
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
```

Note: `ProxyNode.copyWith` from Task 1 only overrides `remark`/`delayMs`/`lastTestedAt` — that already covers what `testDelays` needs.

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/services/v2ray_service_test.dart`
Expected: PASS (6 tests)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add connectivity probe and V2rayService with concurrency-capped delay testing"
```

---

## Task 7: Smart-connect cascade

**Files:**
- Create: `mine/tarmac/lib/services/smart_connect_service.dart`
- Test: `mine/tarmac/test/services/smart_connect_service_test.dart`

**Interfaces:**
- Consumes: `V2rayService` from Task 6, `ConnectivityProbe`/`FakeConnectivityProbe` from Task 6, `FakeV2rayGateway` from Task 5, `ProxyNode` from Task 1
- Produces: `enum SmartConnectResult { success, allFailed, noCandidates, cancelled }`, `class SmartConnectOutcome { final SmartConnectResult result; final ProxyNode? node; }`, `class SmartConnectService { void cancel(); Future<SmartConnectOutcome> connectBest(List<ProxyNode> nodes, {int maxCandidates = 15, Duration probeTimeout = const Duration(seconds: 5), Duration totalBudget = const Duration(seconds: 60), void Function(ProxyNode)? onAttempt}); }`

This is the task that directly covers Review Focus items 3 (no candidates) and 4 (cancel mid-flight) — their tests live here.

- [ ] **Step 1: Write the failing tests**

```dart
// test/services/smart_connect_service_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_connectivity_probe.dart';
import '../fakes/fake_v2ray_gateway.dart';

ProxyNode _node(String link, int delayMs) => ProxyNode(
      id: link,
      remark: link,
      protocol: 'vless',
      rawLink: link,
      sourceSubId: 'manual',
      delayMs: delayMs,
    );

void main() {
  test('connects to the lowest-latency candidate when its probe succeeds', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [true]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('slow', 300), _node('fast', 50)];

    final outcome = await service.connectBest(nodes);

    expect(outcome.result, SmartConnectResult.success);
    expect(outcome.node!.id, 'fast');
    expect(gateway.lastStartedRawLink, 'fast');
  });

  test('falls through to the next candidate when the first probe fails', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [false, true]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('fast', 50), _node('slow', 300)];

    final outcome = await service.connectBest(nodes);

    expect(outcome.result, SmartConnectResult.success);
    expect(outcome.node!.id, 'slow');
    expect(gateway.lastStartedRawLink, 'slow');
  });

  test('returns allFailed when every candidate probe fails', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [false, false]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 50), _node('b', 60)];

    final outcome = await service.connectBest(nodes);

    expect(outcome.result, SmartConnectResult.allFailed);
    expect(gateway.lastStartedRawLink, isNull); // last attempt was stopped
  });

  test('returns noCandidates when no node has a usable delayMs yet', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe();
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [
      ProxyNode(id: 'a', remark: 'a', protocol: 'vless', rawLink: 'a', sourceSubId: 'manual'), // delayMs null
      ProxyNode(id: 'b', remark: 'b', protocol: 'vless', rawLink: 'b', sourceSubId: 'manual', delayMs: -1), // timed out
    ];

    final outcome = await service.connectBest(nodes);

    expect(outcome.result, SmartConnectResult.noCandidates);
  });

  test('returns noCandidates for an empty node list without throwing', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe();
    final service = SmartConnectService(V2rayService(gateway), probe);

    final outcome = await service.connectBest([]);

    expect(outcome.result, SmartConnectResult.noCandidates);
  });

  test('only tries the top maxCandidates nodes by ascending delay', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [false]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('only-candidate', 10), _node('excluded', 20)];

    final outcome = await service.connectBest(nodes, maxCandidates: 1);

    expect(outcome.result, SmartConnectResult.allFailed);
    // 'excluded' was never attempted because maxCandidates capped the list at 1
  });

  test('cancel() while a probe is pending stops the cascade and disconnects', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe();
    probe.pending = Completer<bool>();
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 10), _node('b', 20)];

    final future = service.connectBest(nodes);
    // Let connectBest reach the pending probe, then cancel before it resolves.
    await Future<void>.delayed(Duration.zero);
    service.cancel();
    probe.pending!.complete(true); // even if it "would have" succeeded, cancel wins

    final outcome = await future;

    expect(outcome.result, SmartConnectResult.cancelled);
    expect(gateway.lastStartedRawLink, isNull);
  });

  test('onAttempt callback fires once per candidate tried', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [false, true]);
    final service = SmartConnectService(V2rayService(gateway), probe);
    final nodes = [_node('a', 10), _node('b', 20)];
    final attempted = <String>[];

    await service.connectBest(nodes, onAttempt: (n) => attempted.add(n.id));

    expect(attempted, ['a', 'b']);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/services/smart_connect_service_test.dart`
Expected: FAIL — file does not exist.

- [ ] **Step 3: Implement `smart_connect_service.dart`**

```dart
// lib/services/smart_connect_service.dart
import '../models/proxy_node.dart';
import 'connectivity_probe.dart';
import 'v2ray_service.dart';

enum SmartConnectResult { success, allFailed, noCandidates, cancelled }

class SmartConnectOutcome {
  SmartConnectOutcome({required this.result, this.node});
  final SmartConnectResult result;
  final ProxyNode? node;
}

class SmartConnectService {
  SmartConnectService(this._v2ray, this._probe);
  final V2rayService _v2ray;
  final ConnectivityProbe _probe;

  bool _cancelled = false;

  void cancel() => _cancelled = true;

  Future<SmartConnectOutcome> connectBest(
    List<ProxyNode> nodes, {
    int maxCandidates = 15,
    Duration probeTimeout = const Duration(seconds: 5),
    Duration totalBudget = const Duration(seconds: 60),
    void Function(ProxyNode)? onAttempt,
  }) async {
    _cancelled = false;

    final candidates = nodes.where((n) => n.delayMs != null && n.delayMs! >= 0).toList()
      ..sort((a, b) => a.delayMs!.compareTo(b.delayMs!));
    if (candidates.isEmpty) {
      return SmartConnectOutcome(result: SmartConnectResult.noCandidates);
    }

    final deadline = DateTime.now().add(totalBudget);
    for (final node in candidates.take(maxCandidates)) {
      if (_cancelled) {
        await _v2ray.disconnect();
        return SmartConnectOutcome(result: SmartConnectResult.cancelled);
      }
      if (DateTime.now().isAfter(deadline)) break;

      onAttempt?.call(node);
      final started = await _v2ray.connect(node);
      if (!started) continue;

      final ok = await _probe.check(timeout: probeTimeout);

      if (_cancelled) {
        await _v2ray.disconnect();
        return SmartConnectOutcome(result: SmartConnectResult.cancelled);
      }

      if (ok) {
        return SmartConnectOutcome(result: SmartConnectResult.success, node: node);
      }
      await _v2ray.disconnect();
    }

    return SmartConnectOutcome(result: SmartConnectResult.allFailed);
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/services/smart_connect_service_test.dart`
Expected: PASS (8 tests)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "feat: add smart-connect cascade with candidate ranking, probing, and cancellation"
```

---

## Task 8: AppController wiring

**Files:**
- Create: `mine/tarmac/lib/app_controller.dart`
- Test: `mine/tarmac/test/app_controller_test.dart`

**Interfaces:**
- Consumes: `StorageService` (Task 4), `SubscriptionService`/`dedupeNodes` (Task 3), `V2rayService` (Task 6), `SmartConnectService`/`SmartConnectResult` (Task 7), `V2rayConnectionState` (Task 5)
- Produces: `class AppController extends ChangeNotifier` with fields `subscriptions`, `nodes`, `connectionState`, `connectedNode`, `statusMessage`, `busy`, and methods `loadInitial()`, `refreshSubscriptions()`, `retestAll()`, `smartConnectNow()`, `disconnectNow()`, `addSubscription(name, url)`, `toggleSubscription(id)`, `removeSubscription(id)`

- [ ] **Step 1: Write the failing tests**

```dart
// test/app_controller_test.dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tarmac/app_controller.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/storage_service.dart';
import 'package:tarmac/services/subscription_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
import 'fakes/fake_connectivity_probe.dart';
import 'fakes/fake_v2ray_gateway.dart';

ProxyNode _testNode(String link, int delayMs) => ProxyNode(
      id: link,
      remark: link,
      protocol: 'vless',
      rawLink: link,
      sourceSubId: 'manual',
      delayMs: delayMs,
    );

AppController _buildController({
  http.Client? httpClient,
  FakeV2rayGateway? gateway,
  FakeConnectivityProbe? probe,
}) {
  final v2rayGateway = gateway ?? FakeV2rayGateway();
  final v2rayService = V2rayService(v2rayGateway);
  return AppController(
    storage: StorageService(),
    subscriptionService: SubscriptionService(),
    v2rayService: v2rayService,
    smartConnect: SmartConnectService(v2rayService, probe ?? FakeConnectivityProbe()),
    httpClient: httpClient ?? MockClient((_) async => http.Response('', 404)),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loadInitial populates subscriptions from storage defaults', () async {
    final controller = _buildController();
    await controller.loadInitial();
    expect(controller.subscriptions, hasLength(4));
  });

  test('refreshSubscriptions fetches all enabled subs and dedupes nodes across them', () async {
    final body = 'vless://shared@x:443#Shared\nvless://only-a@x:443#OnlyA';
    final client = MockClient((request) async => http.Response(body, 200));
    final controller = _buildController(httpClient: client);
    await controller.loadInitial();

    await controller.refreshSubscriptions();

    // 4 default subs x 2 links each = 8 raw, but 'shared' link repeats
    // across every source and must collapse to a single node.
    final ids = controller.nodes.map((n) => n.id).toSet();
    expect(ids, contains('vless://shared@x:443#Shared'));
    expect(ids, contains('vless://only-a@x:443#OnlyA'));
    expect(controller.nodes.length, ids.length);
  });

  test('a subscription that fails to fetch records lastError without blocking others', () async {
    var call = 0;
    final client = MockClient((request) async {
      call++;
      if (call == 1) return http.Response('', 404);
      return http.Response('vless://ok@x:443#OK', 200);
    });
    final controller = _buildController(httpClient: client);
    await controller.loadInitial();

    await controller.refreshSubscriptions();

    expect(controller.subscriptions.first.lastError, isNotNull);
    expect(controller.nodes, isNotEmpty);
  });

  test('smartConnectNow with no tested nodes yields a friendly noCandidates status', () async {
    final controller = _buildController();
    await controller.loadInitial();

    await controller.smartConnectNow();

    expect(controller.statusMessage, contains('先测速'));
  });

  test('smartConnectNow success updates connectedNode and status message', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe(results: [true]);
    final controller = _buildController(gateway: gateway, probe: probe);
    await controller.loadInitial();
    controller.debugSetNodesForTest([
      _testNode('vless://a', 10),
    ]);

    await controller.smartConnectNow();

    expect(controller.connectedNode?.id, 'vless://a');
    expect(controller.statusMessage, contains('已连接'));
  });

  test('disconnectNow cancels an in-flight smart connect and resets status', () async {
    final gateway = FakeV2rayGateway();
    final probe = FakeConnectivityProbe();
    probe.pending = Completer<bool>(); // first check() hangs until completed below
    final controller = _buildController(gateway: gateway, probe: probe);
    await controller.loadInitial();
    controller.debugSetNodesForTest([_testNode('vless://a', 10)]);

    final future = controller.smartConnectNow();
    await Future<void>.delayed(Duration.zero);
    await controller.disconnectNow();
    // Let the still-pending probe resolve so smartConnectNow's awaited
    // connectBest() can observe the cancellation and return.
    probe.pending!.complete(true);
    await future;

    expect(controller.connectedNode, isNull);
    expect(controller.statusMessage, '未连接');
  });
}
```

Note: the test calls `controller.debugSetNodesForTest(...)`. Add this as a small `@visibleForTesting` seam on `AppController` so tests can set up node state without going through a full network-backed `refreshSubscriptions()` — see the implementation below.

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/app_controller_test.dart`
Expected: FAIL — `app_controller.dart` does not exist.

- [ ] **Step 3: Implement `AppController`**

```dart
// lib/app_controller.dart
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'models/proxy_node.dart';
import 'models/subscription.dart';
import 'services/smart_connect_service.dart';
import 'services/storage_service.dart';
import 'services/subscription_service.dart';
import 'services/v2ray_gateway.dart';
import 'services/v2ray_service.dart';

class AppController extends ChangeNotifier {
  AppController({
    required this.storage,
    required this.subscriptionService,
    required this.v2rayService,
    required this.smartConnect,
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  final StorageService storage;
  final SubscriptionService subscriptionService;
  final V2rayService v2rayService;
  final SmartConnectService smartConnect;
  final http.Client? _httpClient;

  List<ProxySubscription> subscriptions = [];
  List<ProxyNode> nodes = [];
  V2rayConnectionState connectionState = V2rayConnectionState.disconnected;
  ProxyNode? connectedNode;
  String statusMessage = '未连接';
  bool busy = false;

  @visibleForTesting
  void debugSetNodesForTest(List<ProxyNode> testNodes) {
    nodes = testNodes;
    notifyListeners();
  }

  Future<void> loadInitial() async {
    subscriptions = await storage.loadSubscriptions();
    final manual = await storage.loadManualNodes();
    nodes = manual;
    notifyListeners();
  }

  Future<void> refreshSubscriptions() async {
    busy = true;
    notifyListeners();

    final fetched = <ProxyNode>[];
    final updatedSubs = <ProxySubscription>[];
    for (final sub in subscriptions) {
      if (!sub.enabled) {
        updatedSubs.add(sub);
        continue;
      }
      final result = await subscriptionService.fetchAndParse(sub, client: _httpClient);
      fetched.addAll(result.nodes);
      updatedSubs.add(sub.copyWith(
        lastFetchedAt: DateTime.now(),
        nodeCount: result.nodes.length,
        lastError: result.error,
        clearError: result.error == null,
      ));
    }

    subscriptions = updatedSubs;
    final manualOnly = nodes.where((n) => n.sourceSubId == 'manual').toList();
    nodes = dedupeNodes([...fetched, ...manualOnly]);

    await storage.saveSubscriptions(subscriptions);
    busy = false;
    notifyListeners();
  }

  Future<void> retestAll() async {
    busy = true;
    notifyListeners();
    nodes = await v2rayService.testDelays(nodes);
    busy = false;
    notifyListeners();
  }

  Future<void> smartConnectNow() async {
    final hasCandidates = nodes.any((n) => n.delayMs != null && n.delayMs! >= 0);
    if (!hasCandidates) {
      statusMessage = '还没有可用延迟数据，请先测速';
      notifyListeners();
      return;
    }

    statusMessage = '智能连接中…';
    notifyListeners();

    final outcome = await smartConnect.connectBest(
      nodes,
      onAttempt: (node) {
        statusMessage = '正在尝试 · ${node.remark}';
        notifyListeners();
      },
    );

    switch (outcome.result) {
      case SmartConnectResult.success:
        connectedNode = outcome.node;
        connectionState = V2rayConnectionState.connected;
        statusMessage = '已连接 · ${outcome.node!.remark}';
        await storage.saveLastConnectedNodeId(outcome.node!.id);
        break;
      case SmartConnectResult.allFailed:
        connectedNode = null;
        connectionState = V2rayConnectionState.disconnected;
        statusMessage = '全部节点不可用，请刷新订阅重试';
        break;
      case SmartConnectResult.noCandidates:
        connectedNode = null;
        connectionState = V2rayConnectionState.disconnected;
        statusMessage = '还没有可用延迟数据，请先测速';
        break;
      case SmartConnectResult.cancelled:
        connectedNode = null;
        connectionState = V2rayConnectionState.disconnected;
        statusMessage = '未连接';
        break;
    }
    notifyListeners();
  }

  Future<void> disconnectNow() async {
    smartConnect.cancel();
    await v2rayService.disconnect();
    connectedNode = null;
    connectionState = V2rayConnectionState.disconnected;
    statusMessage = '未连接';
    await storage.saveLastConnectedNodeId(null);
    notifyListeners();
  }

  Future<void> addSubscription(String name, String url) async {
    subscriptions = [
      ...subscriptions,
      ProxySubscription(id: url, name: name, url: url),
    ];
    await storage.saveSubscriptions(subscriptions);
    notifyListeners();
  }

  Future<void> toggleSubscription(String id) async {
    subscriptions = subscriptions
        .map((s) => s.id == id ? s.copyWith(enabled: !s.enabled) : s)
        .toList();
    await storage.saveSubscriptions(subscriptions);
    notifyListeners();
  }

  Future<void> removeSubscription(String id) async {
    subscriptions = subscriptions.where((s) => s.id != id).toList();
    await storage.saveSubscriptions(subscriptions);
    notifyListeners();
  }
}
```

`ProxySubscription.copyWith` needs the `clearError` param already defined in Task 1 — confirm it's present (it is, per Task 1's implementation above).

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/app_controller_test.dart`
Expected: PASS (6 tests)

- [ ] **Step 5: Run the full test suite so far**

Run: `flutter test`
Expected: PASS (all tests across Tasks 1-8)

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add AppController wiring subscriptions, delay testing, and smart connect"
```

---

## Task 9: Node list screen

**Files:**
- Create: `mine/tarmac/lib/widgets/connection_bar.dart`
- Create: `mine/tarmac/lib/widgets/node_tile.dart`
- Create: `mine/tarmac/lib/screens/node_list_screen.dart`
- Test: `mine/tarmac/test/widgets/node_tile_test.dart`
- Test: `mine/tarmac/test/screens/node_list_screen_test.dart`

**Interfaces:**
- Consumes: `AppController`, `ProxyNode`, `V2rayConnectionState` from earlier tasks
- Produces: `Widget buildConnectionBar(AppController controller)` (as `ConnectionBar` widget), `class NodeTile extends StatelessWidget` (takes a `ProxyNode`), `class NodeListScreen extends StatefulWidget` (takes an `AppController`)

- [ ] **Step 1: Write the failing widget test for `NodeTile`**

```dart
// test/widgets/node_tile_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/models/proxy_node.dart';
import 'package:tarmac/widgets/node_tile.dart';

ProxyNode _node({int? delayMs}) => ProxyNode(
      id: 'a',
      remark: '🇯🇵 Japan',
      protocol: 'vless',
      rawLink: 'a',
      sourceSubId: 'manual',
      delayMs: delayMs,
    );

void main() {
  testWidgets('shows remark, protocol badge, and green delay text under 150ms', (tester) async {
    await tester.pumpWidget(MaterialApp(home: NodeTile(node: _node(delayMs: 80))));

    expect(find.text('🇯🇵 Japan'), findsOneWidget);
    expect(find.text('VLESS'), findsOneWidget);
    expect(find.text('80ms'), findsOneWidget);
  });

  testWidgets('shows 超时 for a timed-out node (delayMs == -1)', (tester) async {
    await tester.pumpWidget(MaterialApp(home: NodeTile(node: _node(delayMs: -1))));
    expect(find.text('超时'), findsOneWidget);
  });

  testWidgets('shows 未测速 for an untested node (delayMs == null)', (tester) async {
    await tester.pumpWidget(MaterialApp(home: NodeTile(node: _node())));
    expect(find.text('未测速'), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/widgets/node_tile_test.dart`
Expected: FAIL — `node_tile.dart` does not exist.

- [ ] **Step 3: Implement `NodeTile`**

```dart
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/widgets/node_tile_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Write the failing test for `NodeListScreen`, then implement it and `ConnectionBar`**

```dart
// test/screens/node_list_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tarmac/app_controller.dart';
import 'package:tarmac/screens/node_list_screen.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/storage_service.dart';
import 'package:tarmac/services/subscription_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_connectivity_probe.dart';
import '../fakes/fake_v2ray_gateway.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('shows 未连接 status and a 一键连接 button by default', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService, FakeConnectivityProbe()),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();

    await tester.pumpWidget(MaterialApp(home: NodeListScreen(controller: controller)));

    expect(find.text('未连接'), findsOneWidget);
    expect(find.text('一键连接'), findsOneWidget);
  });
}
```

```dart
// lib/widgets/connection_bar.dart
import 'package:flutter/material.dart';
import '../app_controller.dart';

class ConnectionBar extends StatelessWidget {
  const ConnectionBar({super.key, required this.controller});
  final AppController controller;

  @override
  Widget build(BuildContext context) {
    final connected = controller.connectedNode != null;
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          Expanded(child: Text(controller.statusMessage)),
          FilledButton(
            onPressed: controller.busy
                ? null
                : (connected ? controller.disconnectNow : controller.smartConnectNow),
            child: Text(connected ? '断开' : '一键连接'),
          ),
        ],
      ),
    );
  }
}
```

```dart
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
              Expanded(
                child: RefreshIndicator(
                  onRefresh: controller.refreshSubscriptions,
                  child: ListView.builder(
                    itemCount: controller.nodes.length,
                    itemBuilder: (context, index) => NodeTile(node: controller.nodes[index]),
                  ),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton(
            onPressed: controller.retestAll,
            tooltip: '仅重测',
            child: const Icon(Icons.speed),
          ),
        );
      },
    );
  }
}
```

- [ ] **Step 6: Run to verify all pass**

Run: `flutter test test/widgets/ test/screens/`
Expected: PASS (4 tests)

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "feat: add node list screen with connection bar and node tiles"
```

---

## Task 10: Subscription management screen, settings, and app wiring

**Files:**
- Create: `mine/tarmac/lib/screens/subscription_screen.dart`
- Create: `mine/tarmac/lib/screens/settings_screen.dart`
- Modify: `mine/tarmac/lib/main.dart`
- Test: `mine/tarmac/test/screens/subscription_screen_test.dart`
- Test: `mine/tarmac/test/screens/settings_screen_test.dart`

**Interfaces:**
- Consumes: `AppController` and everything it exposes from Task 8
- Produces: `class SubscriptionScreen extends StatelessWidget`, `class SettingsScreen extends StatelessWidget`, wired `main.dart` entry point

- [ ] **Step 1: Write the failing tests**

```dart
// test/screens/subscription_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tarmac/app_controller.dart';
import 'package:tarmac/screens/subscription_screen.dart';
import 'package:tarmac/services/smart_connect_service.dart';
import 'package:tarmac/services/storage_service.dart';
import 'package:tarmac/services/subscription_service.dart';
import 'package:tarmac/services/v2ray_service.dart';
import '../fakes/fake_connectivity_probe.dart';
import '../fakes/fake_v2ray_gateway.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('lists the four default subscriptions by name', (tester) async {
    final v2rayService = V2rayService(FakeV2rayGateway());
    final controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: v2rayService,
      smartConnect: SmartConnectService(v2rayService, FakeConnectivityProbe()),
      httpClient: MockClient((_) async => http.Response('', 404)),
    );
    await controller.loadInitial();

    await tester.pumpWidget(MaterialApp(home: SubscriptionScreen(controller: controller)));

    expect(find.text('freefq'), findsOneWidget);
    expect(find.text('Pawdroid'), findsOneWidget);
    expect(find.text('ermaozi'), findsOneWidget);
    expect(find.text('V2RayAggregator'), findsOneWidget);
  });
}
```

```dart
// test/screens/settings_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tarmac/screens/settings_screen.dart';

void main() {
  testWidgets('shows the free-node risk disclaimer verbatim', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: SettingsScreen()));

    expect(
      find.text('免费公益节点可能被运营方记录流量，不建议登录网银/重要账号'),
      findsOneWidget,
    );
  });
}
```

- [ ] **Step 2: Run to verify failure**

Run: `flutter test test/screens/subscription_screen_test.dart test/screens/settings_screen_test.dart`
Expected: FAIL — files don't exist.

- [ ] **Step 3: Implement both screens**

```dart
// lib/screens/subscription_screen.dart
import 'package:flutter/material.dart';
import '../app_controller.dart';

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
                subtitle: Text(
                  sub.lastError != null
                      ? '失败：${sub.lastError}'
                      : '节点数：${sub.nodeCount}',
                ),
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
```

```dart
// lib/screens/settings_screen.dart
import 'package:flutter/material.dart';

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: const Padding(
        padding: EdgeInsets.all(16),
        child: Text(
          '免费公益节点可能被运营方记录流量，不建议登录网银/重要账号',
          style: TextStyle(color: Colors.orange),
        ),
      ),
    );
  }
}
```

```dart
// lib/main.dart
import 'package:flutter/material.dart';
import 'app_controller.dart';
import 'screens/node_list_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/subscription_screen.dart';
import 'services/smart_connect_service.dart';
import 'services/storage_service.dart';
import 'services/subscription_service.dart';
import 'services/v2ray_gateway.dart';
import 'services/v2ray_service.dart';
import 'services/connectivity_probe.dart';

void main() {
  runApp(const TarmacApp());
}

class TarmacApp extends StatefulWidget {
  const TarmacApp({super.key});

  @override
  State<TarmacApp> createState() => _TarmacAppState();
}

class _TarmacAppState extends State<TarmacApp> {
  late final AppController _controller;
  late final V2rayService _v2rayService;
  int _tabIndex = 0;

  @override
  void initState() {
    super.initState();
    final gateway = FlutterV2rayGateway();
    _v2rayService = V2rayService(gateway);
    _controller = AppController(
      storage: StorageService(),
      subscriptionService: SubscriptionService(),
      v2rayService: _v2rayService,
      smartConnect: SmartConnectService(_v2rayService, HttpConnectivityProbe()),
    );
    _v2rayService.initialize();
    _controller.loadInitial();
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      NodeListScreen(controller: _controller),
      SubscriptionScreen(controller: _controller),
      const SettingsScreen(),
    ];
    return MaterialApp(
      title: 'Tarmac',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      home: Scaffold(
        body: screens[_tabIndex],
        bottomNavigationBar: NavigationBar(
          selectedIndex: _tabIndex,
          onDestinationSelected: (i) => setState(() => _tabIndex = i),
          destinations: const [
            NavigationDestination(icon: Icon(Icons.list), label: '节点'),
            NavigationDestination(icon: Icon(Icons.rss_feed), label: '订阅'),
            NavigationDestination(icon: Icon(Icons.settings), label: '设置'),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test`
Expected: PASS (every test across Tasks 1-10)

- [ ] **Step 5: Static analysis**

Run: `flutter analyze`
Expected: "No issues found!" — fix any lints before proceeding.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat: add subscription management screen, settings disclaimer, and wire up main.dart"
```

---

## Final on-device check (after Task 10)

The host-machine test suite validates every layer except the real `FlutterV2rayGateway` (platform-channel dependent) and the real network behavior of the four subscription sources. Dispatch this to the `verify-green` subagent rather than running it inline:

- `flutter analyze` and `flutter test` are green (should already be true from Task 10)
- `flutter build apk --debug` succeeds
- Install to the real device via the established adb tunnel workflow (`adb -P <tunnel-port> install build/app/outputs/flutter-apk/app-debug.apk`) — port is *not* fixed, re-establish per the user's tunnel procedure, device must be `XCD1205AF826201978`
- Manually confirm: node list populates after pull-to-refresh, at least one node shows a real delay number, 一键连接 either connects or reports "全部节点不可用" without crashing, 断开 returns to "未连接"
