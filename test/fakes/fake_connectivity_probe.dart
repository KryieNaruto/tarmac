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
