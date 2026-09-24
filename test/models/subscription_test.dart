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
