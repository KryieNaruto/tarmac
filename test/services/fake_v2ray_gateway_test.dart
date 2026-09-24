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
