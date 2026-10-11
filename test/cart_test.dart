import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/app/app.dart';
import 'package:pharmazen_mobile_app/data/providers/sync_providers.dart';
import 'package:pharmazen_mobile_app/data/remote/api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/auth_api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/cart_api_client.dart';
import 'package:pharmazen_mobile_app/features/auth/auth_providers.dart';
import 'package:pharmazen_mobile_app/features/cart/cart_providers.dart';
import 'package:pharmazen_mobile_app/features/cart/cart_screen.dart';

class _SignedInAuth extends AuthController {
  @override
  AuthState build() => const AuthSignedIn(
    AuthUser(
      id: 'u-1',
      name: 'Nusrat',
      email: 'n@example.com',
      role: 'customer',
    ),
  );
}

class _SignedOutAuth extends AuthController {
  @override
  AuthState build() => const AuthSignedOut();
}

/// An in-memory cart that mirrors the server's merge/update/remove behaviour and
/// records every write, so tests can assert what the UI asked for.
class _FakeCartClient extends CartApiClient {
  _FakeCartClient([List<CartItem> initial = const <CartItem>[]])
    : _items = [...initial],
      super(ApiClient());

  List<CartItem> _items;
  final calls = <String>[];

  @override
  Future<List<CartItem>> getCart() async => List.unmodifiable(_items);

  @override
  Future<List<CartItem>> add(String medicineId, {int quantity = 1}) async {
    calls.add('add:$medicineId:$quantity');
    final index = _items.indexWhere((item) => item.medicineId == medicineId);
    if (index >= 0) {
      _items[index] = _items[index].copyWith(
        quantity: _items[index].quantity + quantity,
      );
    } else {
      _items = [..._items, _item(id: medicineId, quantity: quantity)];
    }
    return List.unmodifiable(_items);
  }

  @override
  Future<List<CartItem>> setQuantity(String medicineId, int quantity) async {
    calls.add('set:$medicineId:$quantity');
    if (quantity <= 0) {
      _items = _items.where((item) => item.medicineId != medicineId).toList();
    } else {
      _items = [
        for (final item in _items)
          if (item.medicineId == medicineId)
            item.copyWith(quantity: quantity)
          else
            item,
      ];
    }
    return List.unmodifiable(_items);
  }

  @override
  Future<List<CartItem>> remove(String medicineId) async {
    calls.add('remove:$medicineId');
    _items = _items.where((item) => item.medicineId != medicineId).toList();
    return List.unmodifiable(_items);
  }
}

CartItem _item({
  required String id,
  String name = 'Napa',
  String? generic = 'Paracetamol',
  double price = 12.5,
  int quantity = 1,
  bool requiresPrescription = false,
}) => CartItem(
  medicineId: id,
  name: name,
  genericName: generic,
  price: price,
  quantity: quantity,
  stockQuantity: 100,
  requiresPrescription: requiresPrescription,
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  group('CartItem.fromJson', () {
    test('reads the cart DTO and totals the line', () {
      final item = CartItem.fromJson(const {
        'id': 'm-1',
        'name': 'Napa',
        'genericName': 'Paracetamol',
        'price': 12.5,
        'quantity': 2,
        'stockQuantity': 30,
        'requiresPrescription': true,
      });

      expect(item.medicineId, 'm-1');
      expect(item.genericName, 'Paracetamol');
      expect(item.subtotal, 25.0);
      expect(item.requiresPrescription, isTrue);
    });

    test('falls back to the legacy isSensitive key', () {
      final item = CartItem.fromJson(const {'id': 'm-2', 'isSensitive': true});

      expect(item.requiresPrescription, isTrue);
      expect(item.name, 'Unknown medicine');
    });
  });

  group('cart controller', () {
    ProviderContainer buildContainer(
      CartApiClient client, {
      bool signedIn = true,
    }) {
      final container = ProviderContainer(
        overrides: [
          authProvider.overrideWith(
            signedIn ? _SignedInAuth.new : _SignedOutAuth.new,
          ),
          cartApiClientProvider.overrideWithValue(client),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    test('a signed-out cart is empty and never fetched', () async {
      final client = _FakeCartClient([_item(id: 'm-1')]);
      final container = buildContainer(client, signedIn: false);

      expect(await container.read(cartProvider.future), isEmpty);
      expect(client.calls, isEmpty);
    });

    test('adding merges quantities and updates the badge count', () async {
      final client = _FakeCartClient();
      final container = buildContainer(client);
      await container.read(cartProvider.future);

      await container.read(cartProvider.notifier).add('m-1');
      await container.read(cartProvider.notifier).add('m-1');

      expect(client.calls, ['add:m-1:1', 'add:m-1:1']);
      expect(container.read(cartCountProvider), 2);
    });

    test('quantity updates and removals adopt the server cart', () async {
      final container = buildContainer(
        _FakeCartClient([_item(id: 'm-1', quantity: 1)]),
      );
      await container.read(cartProvider.future);

      await container.read(cartProvider.notifier).setQuantity('m-1', 3);
      expect(container.read(cartCountProvider), 3);

      await container.read(cartProvider.notifier).remove('m-1');
      expect(container.read(cartCountProvider), 0);
    });
  });

  group('CartScreen', () {
    Widget host(_FakeCartClient client) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_SignedInAuth.new),
        cartApiClientProvider.overrideWithValue(client),
      ],
      child: const MaterialApp(home: Scaffold(body: CartScreen())),
    );

    testWidgets('lists items with a running total', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host(_FakeCartClient([_item(id: 'm-1', quantity: 2)])),
      );
      await tester.pumpAndSettle();

      expect(find.text('Napa'), findsOneWidget);
      expect(find.text('2 items'), findsOneWidget);
      // Line and order total for 2 x ৳12.50.
      expect(find.text('৳25.00'), findsNWidgets(3));
    });

    testWidgets('the stepper writes through to the cart', (
      WidgetTester tester,
    ) async {
      final client = _FakeCartClient([_item(id: 'm-1', quantity: 1)]);
      await tester.pumpWidget(host(client));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.add_rounded));
      await tester.pumpAndSettle();

      expect(client.calls, ['set:m-1:2']);
      expect(find.text('2 items'), findsOneWidget);
    });

    testWidgets('removing an item empties the cart', (
      WidgetTester tester,
    ) async {
      final client = _FakeCartClient([_item(id: 'm-1')]);
      await tester.pumpWidget(host(client));
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.delete_outline_rounded));
      await tester.pumpAndSettle();

      expect(client.calls, ['remove:m-1']);
      expect(find.text('Your cart is empty'), findsOneWidget);
    });

    testWidgets('signed out, the tab asks the user to sign in', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith(_SignedOutAuth.new),
            cartApiClientProvider.overrideWithValue(_FakeCartClient()),
          ],
          child: const MaterialApp(home: Scaffold(body: CartScreen())),
        ),
      );
      await tester.pump();

      expect(find.text('Sign in to use your cart'), findsOneWidget);
    });
  });

  testWidgets('the cart badge shows the total unit count', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith(_SignedInAuth.new),
          cartApiClientProvider.overrideWithValue(
            _FakeCartClient([
              _item(id: 'm-1', quantity: 2),
              _item(id: 'm-2', quantity: 1),
            ]),
          ),
          connectivityStatusProvider.overrideWith((ref) => Stream.value(false)),
        ],
        child: const PharmaZenApp(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('3'), findsOneWidget);
  });
}
