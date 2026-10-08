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
    List<int?> connectedDelays = const [],
    this.connectedDelayByUrl,
    this.pending,
  }) : _connectedDelays = List.of(connectedDelays);

  final Map<String, int?> _delayScript;
  final bool permissionGranted;
  final bool startShouldThrow;

  /// 可选闸门：不为 null 时 `getServerDelay` 会先 await 它再返回脚本值，
  /// 测试可用它卡住测速、中途 `cancelRetest()`、再放行。默认 null 行为不变。
  final Completer<void>? gate;

  /// `getConnectedDelay` 的脚本值，顺序消费；只剩一个时反复返回它
  /// （消费到最后一个元素后即固定返回它，列表不会被耗尽）。
  /// 空列表 = 永远取不到数据（null）。
  final List<int?> _connectedDelays;

  /// 按 URL 指定 getConnectedDelay 的返回值（url -> delayMs；null/缺失 = 取不到）。
  /// 给 null 时退回既有的 `connectedDelays` 顺序消费行为。
  final Map<String, int?>? connectedDelayByUrl;

  /// 可选闸门：不为 null 时 `getConnectedDelay` 会 await 它，测试可用它
  /// 卡住「核心实测」、制造取消竞态。默认 null 行为不变。
  Completer<int?>? pending;

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
  Future<int?> getConnectedDelay(String url) async {
    final pending = this.pending;
    if (pending != null) return pending.future;
    final byUrl = connectedDelayByUrl;
    if (byUrl != null) return byUrl[url];
    if (_connectedDelays.isEmpty) return null;
    return _connectedDelays.length == 1
        ? _connectedDelays.first
        : _connectedDelays.removeAt(0);
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
