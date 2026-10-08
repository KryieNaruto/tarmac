import 'dart:async';
import 'package:tarmac/services/connectivity_probe.dart';

/// Controllable test double for [ConnectivityProbe]. It reports the device's
/// current public egress IP.
///
/// - `ips` is consumed in order. Once only **one** entry is left, that entry is
///   returned repeatedly, so tests stay deterministic:
///   `['1.1.1.1']` means the egress IP never changes.
/// - If `pending` is non-null, `egressIp()` waits on that completer instead of
///   resolving immediately, so tests can exercise cancellation races.
class FakeConnectivityProbe implements ConnectivityProbe {
  FakeConnectivityProbe({List<String?> ips = const []}) : _ips = List.of(ips);

  final List<String?> _ips;
  Completer<String?>? pending;

  @override
  Future<String?> egressIp({Duration timeout = const Duration(seconds: 5)}) {
    if (pending != null) return pending!.future;
    if (_ips.isEmpty) return Future.value(null);
    return Future.value(_ips.length == 1 ? _ips.first : _ips.removeAt(0));
  }
}
