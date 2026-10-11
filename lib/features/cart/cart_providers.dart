import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/cart_api_client.dart';
import '../auth/auth_providers.dart';

final cartApiClientProvider = Provider<CartApiClient>(
  (ref) => CartApiClient(ref.watch(apiClientProvider)),
);

/// The signed-in user's cart.
///
/// Watches [authProvider] so it is rebuilt (and re-fetched) when the session
/// changes: signing out empties it, and signing in as someone else does not
/// leave the previous user's items on screen.
final cartProvider = AsyncNotifierProvider<CartController, List<CartItem>>(
  CartController.new,
);

class CartController extends AsyncNotifier<List<CartItem>> {
  @override
  Future<List<CartItem>> build() async {
    final auth = ref.watch(authProvider);
    if (auth is! AuthSignedIn) return const <CartItem>[];
    return ref.read(cartApiClientProvider).getCart();
  }

  /// Re-fetches, e.g. after a pull-to-refresh.
  Future<void> refresh() async {
    if (ref.read(authProvider) is! AuthSignedIn) return;
    state = await AsyncValue.guard(
      () => ref.read(cartApiClientProvider).getCart(),
    );
  }

  /// Adds [quantity] units of a medicine and adopts the cart the server returns.
  ///
  /// Failures propagate so the caller can surface the server's own wording —
  /// most importantly the "maximum 5 units" rejection.
  Future<void> add(String medicineId, {int quantity = 1}) async {
    state = AsyncData(
      await ref.read(cartApiClientProvider).add(medicineId, quantity: quantity),
    );
  }

  Future<void> setQuantity(String medicineId, int quantity) async {
    state = AsyncData(
      await ref.read(cartApiClientProvider).setQuantity(medicineId, quantity),
    );
  }

  Future<void> remove(String medicineId) async {
    state = AsyncData(await ref.read(cartApiClientProvider).remove(medicineId));
  }
}

/// The number shown on the cart badge: the total units on order, matching the
/// "n items" figure the cart screen and the website's summary both use.
final cartCountProvider = Provider<int>((ref) {
  final items = ref.watch(cartProvider).value ?? const <CartItem>[];
  return items.fold<int>(0, (sum, item) => sum + item.quantity);
});
