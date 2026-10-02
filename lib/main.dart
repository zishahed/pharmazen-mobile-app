import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';
import 'data/providers/sync_providers.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  // The container is created here rather than inside a nested ProviderScope so
  // that the sync triggers can be started from main with a handle on the same
  // instance the widget tree uses — one database, one sync engine.
  final container = ProviderContainer();
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const PharmaZenApp(),
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    startSyncTriggers(container);
  });
}
