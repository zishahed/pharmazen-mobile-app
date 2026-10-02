import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';

/// Thin wrapper over `connectivity_plus` that reports a simple online/offline
/// signal.
///
/// Two deliberate departures from the plugin:
///
/// * An empty result list counts as **online**. `connectivity_plus` reports
///   `[]` when it cannot determine a network, and treating that as offline would
///   permanently block syncing on devices where the plugin cannot answer.
/// * Every call is defensive. The plugin throws `MissingPluginException` in unit
///   tests and on platforms without a network implementation; a sync trigger must
///   never be able to break app launch.
class ConnectivityService {
  ConnectivityService({Connectivity? connectivity})
    : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  static bool _isOnline(List<ConnectivityResult> results) =>
      results.isEmpty ||
      results.any((r) => r != ConnectivityResult.none);

  /// Best-effort current state. Returns true when the platform cannot answer, so
  /// that a failed probe never masquerades as "no network".
  Future<bool> isOnline() async {
    try {
      return _isOnline(await _connectivity.checkConnectivity());
    } on Object {
      return true;
    }
  }

  /// Connectivity transitions, debounced by [debounce] to avoid reacting to a
  /// single flap. Emits only on the offline -> online edge.
  Stream<bool> onOnline({Duration debounce = const Duration(seconds: 3)}) {
    var wasOnline = true;
    Timer? timer;

    late final StreamController<bool> controller;
    StreamSubscription<List<ConnectivityResult>>? subscription;

    Future<void> emit(List<ConnectivityResult> results) async {
      final online = _isOnline(results);
      final regained = online && !wasOnline;
      wasOnline = online;
      if (!regained || controller.isClosed) return;

      timer?.cancel();
      timer = Timer(debounce, () {
        if (!controller.isClosed) controller.add(true);
      });
    }

    controller = StreamController<bool>(
      onListen: () async {
        try {
          subscription = _connectivity.onConnectivityChanged.listen(
            emit,
            onError: (Object _) {},
          );
          emit(await _connectivity.checkConnectivity());
        } on Object {
          // No plugin available; stay silent rather than emit spurious syncs.
        }
      },
      onCancel: () async {
        timer?.cancel();
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  void dispose() {}
}