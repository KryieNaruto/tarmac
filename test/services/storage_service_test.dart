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

  test('defaultSubscriptions returns the three verified built-in sources, enabled', () {
    final subs = defaultSubscriptions();
    expect(subs, hasLength(3));
    expect(subs.every((s) => s.enabled), isTrue);
    expect(
      subs.map((s) => s.url),
      containsAll([
        'https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub',
        'https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt',
        'https://raw.githubusercontent.com/mohammadaz2/v2rayConfigsForYou/main/configs.txt',
      ]),
    );
  });

  test('migrateDefaultSubscriptions drops retired sources and backfills missing defaults', () {
    // 存量列表：两个已退役的死源 + 两个仍在用的默认源，且缺了后来新增的 mohammadaz2。
    final stored = [
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

    // 输入确实含退役源，因此迁移必然触发 → 收窄为非空。
    final migrated = migrateDefaultSubscriptions(stored)!;

    // 两个死源被摘掉，mohammadaz2 被补上，Pawdroid / ermaozi 原样保留（引用相等即未重建）。
    expect(migrated, hasLength(3));
    expect(migrated.map((s) => s.id), isNot(contains(
      'https://raw.githubusercontent.com/freefq/free/master/v2',
    )));
    expect(migrated.map((s) => s.id), isNot(contains(
      'https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/airport_merge_base64.txt',
    )));
    expect(migrated.map((s) => s.id), containsAll([
      'https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub',
      'https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt',
      'https://raw.githubusercontent.com/mohammadaz2/v2rayConfigsForYou/main/configs.txt',
    ]));
    expect(migrated[0], same(stored[1]));
    expect(migrated[1], same(stored[2]));
  });

  test('migrateDefaultSubscriptions returns null when no retired source is present', () {
    // 纯自建列表里没有退役 id —— 无需迁移，返回 null，调用方原样返回且不落盘。
    final userSub = ProxySubscription(
      id: 'https://my-airport.example.com/sub',
      name: '我的机场',
      url: 'https://my-airport.example.com/sub',
      enabled: false,
    );

    expect(migrateDefaultSubscriptions([userSub]), isNull);
  });

  test('migrateDefaultSubscriptions keeps user-added subscriptions when it does migrate', () {
    // 既有退役源、又有用户自建源：退役的被摘掉、默认源被补齐，
    // 而用户自建的那条仍原样留在结果里（未被子重建）。
    final retired = ProxySubscription(
      id: 'https://raw.githubusercontent.com/freefq/free/master/v2',
      name: 'freefq',
      url: 'https://raw.githubusercontent.com/freefq/free/master/v2',
    );
    final userSub = ProxySubscription(
      id: 'https://my-airport.example.com/sub',
      name: '我的机场',
      url: 'https://my-airport.example.com/sub',
      enabled: false,
    );

    final migrated = migrateDefaultSubscriptions([retired, userSub]);

    expect(migrated, isNotNull);
    expect(migrated!.map((s) => s.id), isNot(contains(retired.id)));
    expect(migrated.any((s) => identical(s, userSub)), isTrue);
    expect(migrated, hasLength(1 + defaultSubscriptions().length));
  });

  test('loadSubscriptions returns defaults when nothing saved yet', () async {
    final storage = StorageService();
    final subs = await storage.loadSubscriptions();
    expect(subs, hasLength(3));
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

  test('loadSubscriptions does not rewrite prefs when no migration is needed', () async {
    // 手写一份 prefs 里的原始 JSON，故意多带一个 toJson() 不会产生的 __marker 键。
    // 只要 saveSubscriptions 被调用过，字符串就会被重新编码、额外键随之消失。
    const storedJson =
        '[{"id":"https://my-airport.example.com/sub","name":"我的机场",'
        '"url":"https://my-airport.example.com/sub","enabled":true,'
        '"lastFetchedAt":null,"nodeCount":0,"lastError":null,'
        '"__marker":"untouched"}]';
    SharedPreferences.setMockInitialValues({'tarmac.subscriptions': storedJson});

    final loaded = await StorageService().loadSubscriptions();

    // 存量的自建源里没有退役 id → 无需迁移，原样返回。
    expect(loaded, hasLength(1));
    expect(loaded.first.id, 'https://my-airport.example.com/sub');

    final raw = (await SharedPreferences.getInstance())
        .getString('tarmac.subscriptions');
    // 额外键仍在 = 根本没落盘（区分「没写」与「写了但内容一样」）。
    expect(raw, contains('__marker'));
  });

  test('loadSubscriptions rewrites prefs once when a retired source is present', () async {
    // 与上一条配对的对照：这里存量确实含退役源 → 迁移必然触发 → 必然落盘重编码。
    const storedJson =
        '[{"id":"https://raw.githubusercontent.com/freefq/free/master/v2",'
        '"name":"freefq","url":"https://raw.githubusercontent.com/freefq/free/master/v2",'
        '"enabled":true,"lastFetchedAt":null,"nodeCount":0,"lastError":null,'
        '"__marker":"untouched"}]';
    SharedPreferences.setMockInitialValues({'tarmac.subscriptions': storedJson});

    final loaded = await StorageService().loadSubscriptions();

    // 退役源被摘掉、当前默认源被补齐。
    expect(loaded.map((s) => s.id), isNot(contains(
      'https://raw.githubusercontent.com/freefq/free/master/v2',
    )));
    expect(loaded, hasLength(defaultSubscriptions().length));

    final raw = (await SharedPreferences.getInstance())
        .getString('tarmac.subscriptions');
    // 落过盘 → 重新编码 → 手写 JSON 的额外键被抹掉。
    expect(raw, isNot(contains('__marker')));
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

  test('node delays round-trip together with the last retest time', () async {
    final storage = StorageService();
    final testedAt = DateTime.parse('2026-10-07T12:34:56');

    await storage.saveNodeDelays({'vless://a@x:443#A': 42}, testedAt);

    expect(await storage.loadNodeDelays(), {'vless://a@x:443#A': 42});
    expect(await storage.loadLastRetestAt(), testedAt);
  });

  test('node delays default to empty map and null retest time when unset', () async {
    final storage = StorageService();
    expect(await storage.loadNodeDelays(), isEmpty);
    expect(await storage.loadLastRetestAt(), isNull);
  });

  test('node delays loaders tolerate corrupt data without throwing', () async {
    SharedPreferences.setMockInitialValues({
      'tarmac.node_delays': 'not json at all',
      'tarmac.last_retest_at': 'not a date',
    });
    final storage = StorageService();

    expect(await storage.loadNodeDelays(), isEmpty);
    expect(await storage.loadLastRetestAt(), isNull);
  });

  test('node delays loader handles non-map JSON without throwing', () async {
    SharedPreferences.setMockInitialValues({
      'tarmac.node_delays': '[1, 2, 3]',
    });
    final storage = StorageService();

    expect(await storage.loadNodeDelays(), isEmpty);
  });

  test('node delays loader converts JSON numbers and skips null/non-numeric values', () async {
    SharedPreferences.setMockInitialValues({
      'tarmac.node_delays': '{"a": 42.0, "b": null, "c": "x", "d": 7}',
    });
    final storage = StorageService();

    expect(await storage.loadNodeDelays(), {'a': 42, 'd': 7});
  });
}
