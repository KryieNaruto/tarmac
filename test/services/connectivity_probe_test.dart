// test/services/connectivity_probe_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tarmac/services/connectivity_probe.dart';

void main() {
  test('parses the ip= line out of a normal cdn-cgi/trace body', () async {
    const body = 'fl=123abc\nh=cp.cloudflare.com\nip=203.0.113.7\nts=1700000000.0\n';
    final probe = HttpConnectivityProbe(
      client: MockClient((_) async => http.Response(body, 200)),
    );

    expect(await probe.egressIp(), '203.0.113.7');
  });

  test('returns null on a non-200 response', () async {
    final probe = HttpConnectivityProbe(
      client: MockClient((_) async => http.Response('ip=203.0.113.7', 500)),
    );

    expect(await probe.egressIp(), isNull);
  });

  test('returns null when the body has no ip= line', () async {
    const body = 'fl=123abc\nh=cp.cloudflare.com\nts=1700000000.0\n';
    final probe = HttpConnectivityProbe(
      client: MockClient((_) async => http.Response(body, 200)),
    );

    expect(await probe.egressIp(), isNull);
  });

  test('returns null when the client throws', () async {
    final probe = HttpConnectivityProbe(
      client: MockClient((_) async => throw Exception('network down')),
    );

    expect(await probe.egressIp(), isNull);
  });

  test('returns null when the request times out', () async {
    final probe = HttpConnectivityProbe(
      client: MockClient((_) async {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        return http.Response('ip=203.0.113.7', 200);
      }),
    );

    expect(await probe.egressIp(timeout: const Duration(milliseconds: 1)), isNull);
  });
}
