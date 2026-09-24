// test/fakes/fake_v2ray_gateway.dart
import 'dart:async';
import 'package:tarmac/services/v2ray_gateway.dart';

/// In-memory test double. `delayScript` maps rawLink -> delayMs (null =
/// scripted failure); links not present in the map also resolve to null.
class FakeV2rayGateway implements V2rayGateway {
  FakeV2rayGateway({
    this._delayScript = const {},
    this.permissionGranted = true,
    this.startShouldThrow = false,
  });

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
