import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/connectivity_service.dart';
import '../remote/sync_api_client.dart';
import '../sync/sync_engine.dart';
import 'medicine_providers.dart';

final connectivityServiceProvider = Provider<ConnectivityService>((ref) {
  final service = ConnectivityService();
  ref.onDispose(service.dispose);
  return service;
});

final syncApiClientProvider = Provider<SyncApiClient>(
  (ref) => SyncApiClient(),
);

/// The sync engine. Deliberately a plain [Provider], never `autoDispose`: a run
/// must not be cancelled halfway because the last widget watching it went away,
/// which would leave the cursor un-advanced and force a needless replay on the
/// next trigger.
final syncEngineProvider = Provider<SyncEngine>((ref) {
  return SyncEngine(
    db: ref.watch(databaseProvider),
    client: ref.watch(syncApiClientProvider),
  );
});

/// Owns the automatic triggers: one cold-start run, then a run whenever
/// connectivity comes back.
///
/// Reading this provider starts them; `ref.onDispose` tears the subscription
/// down, which is what keeps the connectivity stream from outliving the
/// container in tests. Nothing here can throw out to the caller — sync is a
/// background nicety and must never interrupt app launch, particularly since the
/// endpoint does not exist until Phase 2.
final syncTriggersProvider = Provider<void>((ref) {
  final engine = ref.watch(syncEngineProvider);
  final connectivity = ref.watch(connectivityServiceProvider);

  unawaited(_ignoreFailures(engine.sync(trigger: SyncTrigger.coldStart)));

  final subscription = connectivity.onOnline().listen((_) {
    unawaited(
      _ignoreFailures(engine.sync(trigger: SyncTrigger.connectivity)),
    );
  });
  ref.onDispose(subscription.cancel);
});

/// Convenience entry point for `main`, so the wiring there is a single call.
void startSyncTriggers(ProviderContainer container) {
  container.read(syncTriggersProvider);
}

Future<void> _ignoreFailures(Future<Object?> future) async {
  try {
    await future;
  } on Object {
    // A failed background sync is not actionable from a trigger.
  }
}