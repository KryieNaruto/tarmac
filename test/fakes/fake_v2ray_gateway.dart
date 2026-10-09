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
    this.gate,
  });

  final Map<String, int?> _delayScript;
  final bool permissionGranted;
  final bool startShouldThrow;

  /// 可选闸门：不为 null 时 `getServerDelay` 会先 await 它再返回脚本值，
  /// 测试可用它卡住猎取中的测速、中途 `cancelHunt()`、再放行。默认 null 行为不变。
  final Completer<void>? gate;

  final _controller = StreamController<V2rayConnectionState>.broadcast();
  bool initialized = false;
  String? lastStartedRawLink;

  @override
  Future<void> initialize() async => initialized = true;

  @override
  Future<bool> requestPermission() async => permissionGranted;

  @override
  Future<int?> getServerDelay(String rawLink) async {
    final gate = this.gate;
    if (gate != null) await gate.future;
    return _delayScript[rawLink];
  }

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

  /// 测试钩子：手工把一条状态推给订阅者，用于模拟隧道意外掉线等场景。
  void emitState(V2rayConnectionState s) => _controller.add(s);
}
