import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/app/app.dart';
import 'package:pharmazen_mobile_app/data/remote/auth_api_client.dart';
import 'package:pharmazen_mobile_app/features/auth/auth_providers.dart';

/// Stands in for a valid session so the gate lets the router render.
///
/// Overrides [AuthController.build] entirely, which also skips the deferred
/// `restoreSession` — otherwise the real controller would overwrite this state
/// with `AuthSignedOut` on the first microtask.
class _SignedInAuth extends AuthController {
  @override
  AuthState build() => const AuthSignedIn(
    AuthUser(
      id: 'test-user',
      name: 'Test User',
      email: 'test@example.com',
      role: 'customer',
    ),
  );
}

void main() {
  testWidgets('home screen renders search actions and bottom nav', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [authProvider.overrideWith(_SignedInAuth.new)],
        child: const PharmaZenApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Drug by generic'), findsOneWidget);
    expect(find.text('Drug by category'), findsOneWidget);
    expect(find.text('Drug by Indication'), findsOneWidget);

    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Cart'), findsOneWidget);
    expect(find.text('Prescription'), findsOneWidget);
    expect(find.text('Favorites'), findsOneWidget);
  });

  testWidgets('signed-out users see the sign-in screen, not the home tabs', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(() => _AlwaysSignedOut()),
        ],
        child: const PharmaZenApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Sign in to upload prescriptions'), findsOneWidget);
    expect(find.text('Favorites'), findsNothing);
  });
}

class _AlwaysSignedOut extends AuthController {
  @override
  AuthState build() => const AuthSignedOut();
}