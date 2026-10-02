import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/theme/app_theme.dart';
import 'router.dart';
import '../features/auth/auth_providers.dart';
import '../features/auth/login_screen.dart';

class PharmaZenApp extends ConsumerWidget {
  const PharmaZenApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'PharmaZen',
      theme: AppTheme.light,
      routerConfig: appRouter,
      // The gate lives here rather than as a go_router redirect because
      // `appRouter` is a global with no `ref` to watch auth state, and adding a
      // refreshListenable bridge for one condition would be more machinery than
      // the decision is worth.
      builder: (context, child) => _AuthGate(child: child),
    );
  }
}

class _AuthGate extends ConsumerWidget {
  const _AuthGate({this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return switch (ref.watch(authProvider)) {
      // Wait for `restoreSession` rather than flashing the login form on every
      // cold start; an instantly-appearing login screen reads as a signed-out
      // user when the session is in fact still valid.
      AuthUnknown() => const _Splash(),
      AuthSignedOut() => const LoginScreen(),
      AuthSignedIn() => child ?? const SizedBox.shrink(),
    };
  }
}

class _Splash extends StatelessWidget {
  const _Splash();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.local_pharmacy_rounded, size: 48),
            SizedBox(height: 24),
            SizedBox(
              height: 24,
              width: 24,
              child: CircularProgressIndicator(strokeWidth: 2.5),
            ),
          ],
        ),
      ),
    );
  }
}