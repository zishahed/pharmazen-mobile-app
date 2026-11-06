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

/// The queue every pharmacist and admin shares.
///
/// It watches [authProvider] so signing in as a customer clears it, and signing
/// in as a pharmacist refetches instead of leaving the previous session's queue
/// on screen.
final pendingPrescriptionsProvider =
    AsyncNotifierProvider<PendingPrescriptionsController, List<Prescription>>(
      PendingPrescriptionsController.new,
    );

class PendingPrescriptionsController
    extends AsyncNotifier<List<Prescription>> {
  @override
  Future<List<Prescription>> build() async {
    final auth = ref.watch(authProvider);
    if (auth is! AuthSignedIn || !auth.user.canReviewPrescriptions) {
      return const <Prescription>[];
    }
    return ref.read(prescriptionApiClientProvider).listPending();
  }

  /// Re-fetches after a review, so a decision made on one device disappears
  /// from every other pharmacist's queue on their next refresh.
  Future<void> refresh() async {
    state = await AsyncValue.guard(
      () => ref.read(prescriptionApiClientProvider).listPending(),
    );
  }
}

/// One request, fetched fresh for the review detail page.
final prescriptionDetailProvider =
    FutureProvider.autoDispose.family<Prescription, String>(
      (ref, id) => ref.watch(prescriptionApiClientProvider).getById(id),
    );