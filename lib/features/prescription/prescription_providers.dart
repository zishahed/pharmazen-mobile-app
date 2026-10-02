import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/remote/prescription_api_client.dart';
import '../auth/auth_providers.dart';

final prescriptionApiClientProvider = Provider<PrescriptionApiClient>(
  (ref) => PrescriptionApiClient(ref.watch(apiClientProvider)),
);

/// The signed-in user's prescriptions, newest first.
///
/// Auto-disposed with the auth session: signing out must not leave one user's
/// prescriptions visible to whoever signs in next.
final myPrescriptionsProvider =
    AsyncNotifierProvider<MyPrescriptionsController, List<Prescription>>(
      MyPrescriptionsController.new,
    );

class MyPrescriptionsController extends AsyncNotifier<List<Prescription>> {
  @override
  Future<List<Prescription>> build() async {
    final auth = ref.watch(authProvider);
    if (auth is! AuthSignedIn) return const <Prescription>[];
    return ref.read(prescriptionApiClientProvider).listMine();
  }

  /// Re-fetches after an upload so the new row appears without a manual pull.
  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => ref.read(prescriptionApiClientProvider).listMine(),
    );
  }
}