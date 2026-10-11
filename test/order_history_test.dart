import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/data/remote/api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/auth_api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/order_api_client.dart';
import 'package:pharmazen_mobile_app/features/auth/auth_providers.dart';
import 'package:pharmazen_mobile_app/features/profile/order_providers.dart';
import 'package:pharmazen_mobile_app/features/profile/widgets/order_history.dart';

/// A signed-in controller whose sign-out needs no network.
class _SignedInAuth extends AuthController {
  @override
  AuthState build() => const AuthSignedIn(
    AuthUser(
      id: 'u-1',
      name: 'Nusrat Jahan',
      email: 'nusrat@example.com',
      role: 'customer',
    ),
  );
}

/// An [OrderApiClient] that answers from memory, so no request leaves the test.
class _FakeOrderClient extends OrderApiClient {
  _FakeOrderClient(this.orders) : super(ApiClient());

  final List<Order> orders;
  final List<String> cancelled = <String>[];

  @override
  Future<List<Order>> listMine() async => orders;

  @override
  Future<void> cancel(String orderId) async => cancelled.add(orderId);
}

Order _order({
  required String id,
  required DateTime createdAt,
  String status = 'pending',
  String paymentStatus = 'unpaid',
  double total = 120,
  List<OrderItem> items = const <OrderItem>[],
}) => Order(
  id: id,
  totalAmount: total,
  status: status,
  paymentStatus: paymentStatus,
  createdAt: createdAt,
  items: items,
);

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  group('Order.fromJson', () {
    test('reads the list-endpoint shape including payment and items', () {
      final order = Order.fromJson(const {
        'id': 'abcdefgh-1234-5678-90ab-cdef01234567',
        'totalAmount': 25.5,
        'status': 'pending',
        'paymentStatus': 'unpaid',
        'createdAt': '2026-10-11T09:30:00.000Z',
        'items': [
          {'medicineId': 'm-1', 'name': 'Napa', 'quantity': 2, 'price': 12.75},
        ],
        'payment': {'transactionId': 'tx-1', 'status': 'pending'},
      });

      expect(order.shortId, 'abcdefgh');
      expect(order.totalAmount, 25.5);
      expect(order.items.single.name, 'Napa');
      expect(order.items.single.subtotal, 25.5);
      expect(order.transactionId, 'tx-1');
      expect(order.canCancel, isTrue);
    });

    test('tolerates a missing payment block', () {
      final order = Order.fromJson(const {
        'id': 'o-1',
        'totalAmount': 10,
        'status': 'pending',
        'paymentStatus': 'unpaid',
        'createdAt': '2026-10-11T09:30:00.000Z',
        'items': <dynamic>[],
      });

      expect(order.transactionId, isNull);
      expect(order.items, isEmpty);
    });

    test('only an unpaid, still-pending order can be cancelled', () {
      expect(
        _order(
          id: 'a',
          createdAt: DateTime(2026, 10, 11),
          status: 'paid',
        ).canCancel,
        isFalse,
      );
      expect(
        _order(
          id: 'b',
          createdAt: DateTime(2026, 10, 11),
          paymentStatus: 'paid',
        ).canCancel,
        isFalse,
      );
      expect(
        _order(
          id: 'c',
          createdAt: DateTime(2026, 10, 11),
          status: 'cancelled',
        ).canCancel,
        isFalse,
      );
    });
  });

  group('order history tab', () {
    Widget host(List<Order> orders) => ProviderScope(
      overrides: [
        authProvider.overrideWith(_SignedInAuth.new),
        orderApiClientProvider.overrideWithValue(_FakeOrderClient(orders)),
      ],
      child: const MaterialApp(
        home: Scaffold(body: SingleChildScrollView(child: OrderHistory())),
      ),
    );
    testWidgets('groups orders under a heading per day', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host([
          _order(id: 'o-1', createdAt: DateTime(2026, 10, 11, 9, 30)),
          _order(id: 'o-2', createdAt: DateTime(2026, 10, 11, 18)),
          _order(id: 'o-3', createdAt: DateTime(2026, 10, 9, 12)),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.text('October 11, 2026'), findsOneWidget);
      expect(find.text('October 9, 2026'), findsOneWidget);
      expect(find.text('Order #o-1'), findsOneWidget);
      expect(find.text('Order #o-2'), findsOneWidget);
      expect(find.text('Order #o-3'), findsOneWidget);
    });

    testWidgets('shows an empty state with no orders', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(host(const <Order>[]));
      await tester.pumpAndSettle();

      expect(find.text('No purchases yet'), findsOneWidget);
    });

    testWidgets('cancelling flips the badge and drops the button', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host([_order(id: 'o-1', createdAt: DateTime(2026, 10, 11, 9, 30))]),
      );
      await tester.pumpAndSettle();

      expect(find.text('Pending'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel order'));
      await tester.pumpAndSettle();

      // Confirm inside the dialog, not the card button.
      await tester.tap(find.widgetWithText(FilledButton, 'Cancel order'));
      await tester.pumpAndSettle();

      expect(find.text('Cancelled'), findsOneWidget);
      expect(
        find.widgetWithText(OutlinedButton, 'Cancel order'),
        findsNothing,
        reason: 'a cancelled order is no longer cancellable',
      );
    });

    testWidgets('caps the history at the most recent 50', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        host([
          for (var i = 1; i <= 60; i++)
            _order(id: 'o-$i', createdAt: DateTime(2026, 10, 11, 9)),
        ]),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('Order #'), findsNWidgets(orderHistoryMax));
      expect(find.text('Order #o-51'), findsNothing);
    });
  });
}
