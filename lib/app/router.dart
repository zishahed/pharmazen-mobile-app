import 'package:go_router/go_router.dart';

import '../data/repositories/medicine_repository.dart';
import '../features/browse/browse_results_screen.dart';
import '../features/browse/browse_screen.dart';
import '../features/home/home_screen.dart';
import '../features/medicines/medicines_screen.dart';

MedicineSearchMode _modeFromType(String? type) {
  return switch (type) {
    'category' => MedicineSearchMode.category,
    'indication' => MedicineSearchMode.indication,
    _ => MedicineSearchMode.generic,
  };
}

final appRouter = GoRouter(
  initialLocation: '/',
  routes: [
    GoRoute(
      path: '/',
      builder: (context, state) {
        return const HomeScreen();
      },
    ),
    GoRoute(
      path: '/medicines',
      builder: (context, state) {
        final mode = switch (state.uri.queryParameters['mode']) {
          'category' => MedicineSearchMode.category,
          'generic' => MedicineSearchMode.generic,
          'indication' => MedicineSearchMode.indication,
          _ => MedicineSearchMode.name,
        };
        return MedicinesScreen(mode: mode);
      },
    ),
    GoRoute(
      path: '/browse',
      builder: (context, state) {
        return BrowseScreen(
          mode: _modeFromType(state.uri.queryParameters['type']),
        );
      },
    ),
    GoRoute(
      path: '/browse/results',
      builder: (context, state) {
        return BrowseResultsScreen(
          mode: _modeFromType(state.uri.queryParameters['type']),
          value: state.uri.queryParameters['value'] ?? '',
        );
      },
    ),
  ],
);