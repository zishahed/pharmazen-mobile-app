import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/data/providers/sync_providers.dart';
import 'package:pharmazen_mobile_app/features/home/widgets/connectivity_banner.dart';

void main() {
  late StreamController<bool> connectivity;

  setUp(() => connectivity = StreamController<bool>());
  tearDown(() => connectivity.close());

  Widget host() => ProviderScope(
    overrides: [
      connectivityStatusProvider.overrideWith((ref) => connectivity.stream),
    ],
    child: const MaterialApp(
      home: Scaffold(body: Column(children: [ConnectivityBanner()])),
    ),
  );

  testWidgets('offline notice shows and stays on screen', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    connectivity.add(false);
    await tester.pump();

    expect(find.text('You are offline'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_off_rounded), findsOneWidget);

    // Well past the online confirmation's lifetime: offline has no timer, so it
    // must still be there.
    await tester.pump(const Duration(seconds: 10));
    expect(find.text('You are offline'), findsOneWidget);
  });

  testWidgets('online notice disappears after two seconds', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    connectivity.add(true);
    await tester.pump();

    expect(find.text('You are online'), findsOneWidget);
    expect(find.byIcon(Icons.cloud_done_rounded), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();

    expect(find.text('You are online'), findsNothing);
  });

  testWidgets('returning online after a drop shows the confirmation again', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(host());
    connectivity.add(false);
    await tester.pump();
    expect(find.text('You are offline'), findsOneWidget);

    connectivity.add(true);
    await tester.pump();
    expect(find.text('You are online'), findsOneWidget);

    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('You are online'), findsNothing);
  });
}
