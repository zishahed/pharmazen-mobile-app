import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/data/remote/api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/auth_api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/order_api_client.dart';
import 'package:pharmazen_mobile_app/features/auth/auth_providers.dart';
import 'package:pharmazen_mobile_app/features/profile/order_providers.dart';
import 'package:pharmazen_mobile_app/features/profile/profile_screen.dart';

const _user = AuthUser(
  id: '11111111-1111-1111-1111-111111111111',
  name: 'Nusrat Jahan',
  email: 'nusrat@example.com',
  role: 'pharmacist',
  createdAt: '2025-01-01T00:00:00.000Z',
);

/// A signed-in controller whose sign-out needs no network.
class _SignedInAuth extends AuthController {
  @override
  AuthState build() => const AuthSignedIn(_user);

  @override
  Future<void> signOut() async => state = const AuthSignedOut();
}

class _SignedOutAuth extends AuthController {
  @override
  AuthState build() => const AuthSignedOut();
}

/// Keeps the profile's order history from reaching the network.
class _FakeOrderClient extends OrderApiClient {
  _FakeOrderClient() : super(ApiClient());

  @override
  Future<List<Order>> listMine() async => const <Order>[];
}

Widget _host(AuthController Function() auth) {
  return ProviderScope(
    overrides: [
      authProvider.overrideWith(auth),
      orderApiClientProvider.overrideWithValue(_FakeOrderClient()),
    ],
    child: const MaterialApp(home: Scaffold(body: ProfileScreen())),
  );
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  testWidgets('signed-out profile is the sign-in form', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_SignedOutAuth.new));
    await tester.pump();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });

  testWidgets('signed-in profile shows name, id, email, role and join date', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_SignedInAuth.new));
    await tester.pump();

    expect(find.text('Nusrat Jahan'), findsOneWidget);
    expect(find.text('nusrat@example.com'), findsOneWidget);
    expect(find.text(_user.id), findsOneWidget);
    // The role appears once on the chip and once in the detail list.
    expect(find.text('Pharmacist'), findsNWidgets(2));

    expect(find.text('MEMBER SINCE'), findsOneWidget);
    expect(find.textContaining('202'), findsWidgets);
  });

  testWidgets('signing out returns the profile tab to the sign-in form', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_host(_SignedInAuth.new));
    await tester.pump();

    await tester.dragUntilVisible(
      find.text('Sign out'),
      find.byType(ListView),
      const Offset(0, -200),
    );
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();

    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Nusrat Jahan'), findsNothing);
  });
}
