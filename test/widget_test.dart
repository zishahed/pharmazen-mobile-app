import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/app/app.dart';
import 'package:pharmazen_mobile_app/data/providers/sync_providers.dart';
import 'package:pharmazen_mobile_app/data/remote/api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/auth_api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/cart_api_client.dart';
import 'package:pharmazen_mobile_app/features/auth/auth_providers.dart';
import 'package:pharmazen_mobile_app/features/cart/cart_providers.dart';

/// Stands in for a valid session.
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
      createdAt: '2025-01-01T00:00:00.000Z',
    ),
  );
}

class _AlwaysSignedOut extends AuthController {
  @override
  AuthState build() => const AuthSignedOut();
}

/// Keeps the cart badge from reaching the network.
class _EmptyCartClient extends CartApiClient {
  _EmptyCartClient() : super(ApiClient());

  @override
  Future<List<CartItem>> getCart() async => const <CartItem>[];
}

void main() {
  testWidgets('home screen renders search actions and bottom nav', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_SignedInAuth.new),
          cartApiClientProvider.overrideWithValue(_EmptyCartClient()),
          // Offline keeps the banner free of its 2s hide timer, so the test
          // does not have to wait it out.
          connectivityStatusProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: const PharmaZenApp(),
      ),
    );
    await tester.pump();

    expect(find.text('Search'), findsOneWidget);
    expect(find.text('Drug by generic'), findsOneWidget);
    expect(find.text('Drug by category'), findsOneWidget);
    expect(find.text('Drug by Indication'), findsOneWidget);

    expect(find.text('Home'), findsOneWidget);
    expect(find.text('Profile'), findsOneWidget);
    expect(find.text('Cart'), findsOneWidget);
    expect(find.text('Prescription'), findsOneWidget);
  });

  testWidgets(
    'a signed-out user still lands on Home, with sign-in in Profile',
    (WidgetTester tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(_AlwaysSignedOut.new),
            connectivityStatusProvider.overrideWith(
              (ref) => Stream.value(false),
            ),
          ],
          child: const PharmaZenApp(),
        ),
      );
      await tester.pump();

      // The shell is reachable without a session; there is no forced login.
      expect(find.text('Home'), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);
      expect(find.text('Sign in'), findsNothing);

      await tester.tap(find.text('Profile'));
      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsOneWidget);
      expect(
        find.text('Sign in to view your profile and prescriptions'),
        findsOneWidget,
      );
    },
  );
}
