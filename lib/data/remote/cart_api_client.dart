import 'package:dio/dio.dart';

import 'api_client.dart';

/// The cart's per-medicine quantity ceiling, mirrored from the backend
/// (`cart.service.js` MAX_QUANTITY) so the UI cannot offer a step the server
/// would reject.
const int cartMaxQuantity = 5;

/// One line of the cart, as returned by `/api/cart`.
///
/// The cart is server-owned: the endpoint joins the live medicine row, so the
/// name, price, stock and restricted flag here are current rather than the
/// snapshot an order keeps.
class CartItem {
  const CartItem({
    required this.medicineId,
    required this.name,
    required this.price,
    required this.quantity,
    required this.stockQuantity,
    required this.requiresPrescription,
    this.genericName,
  });

  /// The server-side UUID, which is what every cart write names.
  final String medicineId;
  final String name;
  final String? genericName;
  final double price;
  final int quantity;
  final int stockQuantity;
  final bool requiresPrescription;

  double get subtotal => price * quantity;

  CartItem copyWith({int? quantity}) => CartItem(
    medicineId: medicineId,
    name: name,
    genericName: genericName,
    price: price,
    quantity: quantity ?? this.quantity,
    stockQuantity: stockQuantity,
    requiresPrescription: requiresPrescription,
  );

  factory CartItem.fromJson(Map<String, dynamic> json) => CartItem(
    medicineId: (json['id'] as String?) ?? '',
    name: (json['name'] as String?) ?? 'Unknown medicine',
    genericName: json['genericName'] as String?,
    price: (json['price'] as num?)?.toDouble() ?? 0,
    quantity: (json['quantity'] as num?)?.toInt() ?? 0,
    stockQuantity: (json['stockQuantity'] as num?)?.toInt() ?? 0,
    // Served under both names during the transition; `requiresPrescription`
    // is the one the React checkout reads.
    requiresPrescription:
        (json['requiresPrescription'] as bool?) ??
        (json['isSensitive'] as bool?) ??
        false,
  );
}

/// A failure from the cart endpoints, carrying the server's own wording.
class CartException implements Exception {
  const CartException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Reads and writes `/api/cart`.
///
/// Every endpoint is authenticated and answers with the whole cart, so a write
/// never needs a follow-up read: the reply is the new state.
class CartApiClient {
  CartApiClient(this._api);

  final ApiClient _api;

  /// The signed-in user's cart.
  Future<List<CartItem>> getCart() async {
    final response = await _send(
      () => _api.dio.get<Map<String, dynamic>>('/cart'),
      'Could not load your cart.',
    );
    return _items(response);
  }

  /// Adds [quantity] units, merging with any existing line.
  Future<List<CartItem>> add(String medicineId, {int quantity = 1}) async {
    final response = await _send(
      () => _api.dio.post<Map<String, dynamic>>(
        '/cart',
        data: {'medicineId': medicineId, 'quantity': quantity},
      ),
      'Could not add the medicine to your cart.',
    );
    return _items(response);
  }

  /// Sets a line to an exact quantity. Zero removes it server-side, but the UI
  /// removes explicitly instead, so this is only ever called with 1..5.
  Future<List<CartItem>> setQuantity(String medicineId, int quantity) async {
    final response = await _send(
      () => _api.dio.put<Map<String, dynamic>>(
        '/cart',
        data: {'medicineId': medicineId, 'quantity': quantity},
      ),
      'Could not update the quantity.',
    );
    return _items(response);
  }

  Future<List<CartItem>> remove(String medicineId) async {
    final response = await _send(
      () => _api.dio.delete<Map<String, dynamic>>('/cart/$medicineId'),
      'Could not remove the medicine.',
    );
    return _items(response);
  }

  Future<Response<Map<String, dynamic>>> _send(
    Future<Response<Map<String, dynamic>>> Function() request,
    String rejected,
  ) async {
    try {
      return await request();
    } on DioException catch (error) {
      throw CartException(
        ApiClient.serverMessageOf(error) ??
            (ApiClient.wasAnswered(error)
                ? rejected
                : 'Could not reach the server. Check your connection.'),
        statusCode: error.response?.statusCode,
      );
    }
  }

  List<CartItem> _items(Response<Map<String, dynamic>> response) {
    final data = response.data?['data'];
    final items = data is Map<String, dynamic> ? data['items'] : null;
    return (items as List<dynamic>? ?? const <dynamic>[])
        .whereType<Map<String, dynamic>>()
        .map(CartItem.fromJson)
        .toList(growable: false);
  }
}
