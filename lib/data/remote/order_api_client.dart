import 'package:dio/dio.dart';

import 'api_client.dart';

/// One line of an order, as returned by `/api/orders`.
///
/// The list endpoint only selects `id` and `name` off the medicine, so an order
/// is a historical record rather than a live catalogue lookup: it keeps the name
/// and the price paid, both of which survive the medicine being renamed or
/// removed.
class OrderItem {
  const OrderItem({
    required this.medicineId,
    required this.name,
    required this.quantity,
    required this.price,
  });

  final String medicineId;
  final String name;
  final int quantity;

  /// Price per unit at the time of purchase.
  final double price;

  double get subtotal => price * quantity;

  factory OrderItem.fromJson(Map<String, dynamic> json) => OrderItem(
    medicineId: (json['medicineId'] as String?) ?? '',
    name: (json['name'] as String?) ?? 'Unknown medicine',
    quantity: (json['quantity'] as num?)?.toInt() ?? 0,
    price: (json['price'] as num?)?.toDouble() ?? 0,
  );
}

/// One of the user's orders, as returned by `GET /api/orders`.
class Order {
  const Order({
    required this.id,
    required this.totalAmount,
    required this.status,
    required this.paymentStatus,
    required this.createdAt,
    required this.items,
    this.transactionId,
  });

  final String id;
  final double totalAmount;
  final String status;
  final String paymentStatus;
  final DateTime createdAt;
  final List<OrderItem> items;

  /// Present only when a payment row exists.
  final String? transactionId;

  /// The website's rule, reused so the app cannot offer a cancel the server
  /// would reject: only an unpaid, still-pending order can be cancelled.
  bool get canCancel => status == 'pending' && paymentStatus != 'paid';

  /// Short form for display; a UUID is unreadable in full.
  String get shortId => id.length > 8 ? id.substring(0, 8) : id;

  Order copyWith({String? status, String? paymentStatus}) => Order(
    id: id,
    totalAmount: totalAmount,
    status: status ?? this.status,
    paymentStatus: paymentStatus ?? this.paymentStatus,
    createdAt: createdAt,
    items: items,
    transactionId: transactionId,
  );

  factory Order.fromJson(Map<String, dynamic> json) {
    final payment = json['payment'];
    return Order(
      id: (json['id'] as String?) ?? '',
      totalAmount: (json['totalAmount'] as num?)?.toDouble() ?? 0,
      status: (json['status'] as String?) ?? 'pending',
      paymentStatus: (json['paymentStatus'] as String?) ?? 'unpaid',
      createdAt:
          DateTime.tryParse((json['createdAt'] as String?) ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      items: (json['items'] as List<dynamic>? ?? const <dynamic>[])
          .whereType<Map<String, dynamic>>()
          .map(OrderItem.fromJson)
          .toList(growable: false),
      transactionId: payment is Map<String, dynamic>
          ? payment['transactionId'] as String?
          : null,
    );
  }
}

/// A failure from the order endpoints, carrying the server's own wording.
class OrderException implements Exception {
  const OrderException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Reads and cancels `/api/orders`.
///
/// Authenticated: the endpoint returns whichever user the bearer token belongs
/// to, so there is no user id in the path.
class OrderApiClient {
  OrderApiClient(this._api);

  final ApiClient _api;

  /// The signed-in user's orders, newest first (the server orders by `createdAt`
  /// descending).
  Future<List<Order>> listMine() async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _api.dio.get<Map<String, dynamic>>('/orders');
    } on DioException catch (error) {
      throw _asOrderError(error, 'Could not load your orders.');
    }

    if (response.statusCode != 200) {
      throw OrderException(
        ApiClient.messageOf(response.data) ?? 'Could not load your orders.',
        statusCode: response.statusCode,
      );
    }
    final data =
        (response.data?['data'] as List<dynamic>?) ?? const <dynamic>[];
    return data
        .whereType<Map<String, dynamic>>()
        .map(Order.fromJson)
        .toList(growable: false);
  }

  /// Cancels an unpaid, pending order.
  ///
  /// Returns nothing on purpose: the endpoint's reply is the raw order row
  /// without its items, so parsing it back would drop the lines from the list.
  /// The caller flips the status locally instead.
  Future<void> cancel(String orderId) async {
    final Response<Map<String, dynamic>> response;
    try {
      response = await _api.dio.put<Map<String, dynamic>>(
        '/orders/$orderId/cancel',
      );
    } on DioException catch (error) {
      throw _asOrderError(error, 'Could not cancel the order.');
    }

    if (response.statusCode != 200) {
      throw OrderException(
        ApiClient.messageOf(response.data) ?? 'Could not cancel the order.',
        statusCode: response.statusCode,
      );
    }
  }

  static OrderException _asOrderError(DioException error, String rejected) =>
      OrderException(
        ApiClient.serverMessageOf(error) ??
            (ApiClient.wasAnswered(error)
                ? rejected
                : 'Could not reach the server. Check your connection.'),
        statusCode: error.response?.statusCode,
      );
}
