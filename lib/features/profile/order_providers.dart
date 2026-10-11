import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/order_api_client.dart';
import '../auth/auth_providers.dart';

/// The most recent orders the profile will show. Older rows are dropped rather
/// than paged, so the section stays a glance rather than an archive.
const int orderHistoryMax = 50;

final orderApiClientProvider = Provider<OrderApiClient>(
  (ref) => OrderApiClient(ref.watch(apiClientProvider)),
);

/// The signed-in user's purchase history, newest first, capped at
/// [orderHistoryMax].
///
/// Watches [authProvider] so it is rebuilt (and re-fetched) when the session
/// changes: signing out returns an empty list, and signing in as someone else
/// does not leave the previous user's orders on screen.
final myOrdersProvider = AsyncNotifierProvider<MyOrdersController, List<Order>>(
  MyOrdersController.new,
);

class MyOrdersController extends AsyncNotifier<List<Order>> {
  @override
  Future<List<Order>> build() async {
    final auth = ref.watch(authProvider);
    if (auth is! AuthSignedIn) return const <Order>[];
    return _fetch();
  }

  /// The endpoint has no server-side paging, so the cap is applied here too,
  /// which also bounds what the app keeps in memory.
  Future<List<Order>> _fetch() async {
    final orders = await ref.read(orderApiClientProvider).listMine();
    return orders.length > orderHistoryMax
        ? orders.sublist(0, orderHistoryMax)
        : orders;
  }

  /// Re-fetches, e.g. after a pull-to-refresh.
  Future<void> refresh() async {
    state = await AsyncValue.guard(_fetch);
  }

  /// Cancels an order and flips its status in place.
  ///
  /// The list is not refetched: the cancel reply omits the order's items, so a
  /// refetch would be the only way to get them back, and the local flip already
  /// reflects exactly what the server changed.
  Future<void> cancel(String orderId) async {
    await ref.read(orderApiClientProvider).cancel(orderId);
    final current = state.value;
    if (current == null) return;
    state = AsyncData<List<Order>>([
      for (final order in current)
        if (order.id == orderId) order.copyWith(status: 'cancelled') else order,
    ]);
  }
}
