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
