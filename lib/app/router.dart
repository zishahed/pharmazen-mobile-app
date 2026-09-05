import 'package:go_router/go_router.dart';

import '../data/repositories/medicine_repository.dart';
import '../features/home/home_screen.dart';
import '../features/medicines/medicines_screen.dart';

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
          _ => MedicineSearchMode.name,
        };
        return MedicinesScreen(mode: mode);
      },
    ),
  ],
);