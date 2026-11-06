import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pharmazen_mobile_app/data/remote/api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/auth_api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/prescription_api_client.dart';
import 'package:pharmazen_mobile_app/features/auth/auth_providers.dart';
import 'package:pharmazen_mobile_app/features/prescription/prescription_providers.dart';
import 'package:pharmazen_mobile_app/features/prescription/prescription_review_screen.dart';
import 'package:pharmazen_mobile_app/features/prescription/prescription_screen.dart';

const _pharmacist = AuthUser(
  id: '22222222-2222-2222-2222-222222222222',
  name: 'Dr. Rahman',
  email: 'rahman@example.com',
  role: 'pharmacist',
);

const _customer = AuthUser(
  id: '11111111-1111-1111-1111-111111111111',
  name: 'Rina',
  email: 'rina@example.com',
  role: 'customer',
);

Prescription _prescription({
  String id = 'rx-1',
  String status = 'pending',
  String? reviewNote,
  String customerName = 'Rina Ahmed',
  String customerEmail = 'rina@example.com',
}) => Prescription(
  id: id,
  medicineId: 'medicine-1',
  medicineName: 'Napa Extra',
  startDate: DateTime(2026, 1, 1),
  endDate: DateTime(2026, 1, 10),
  status: status,
  createdAt: DateTime(2026, 1, 1, 9, 30),
  reviewNote: reviewNote,
  customerName: customerName,
  customerEmail: customerEmail,
);

class _PharmacistAuth extends AuthController {
  @override
  AuthState build() => const AuthSignedIn(_pharmacist);
}

class _CustomerAuth extends AuthController {
  @override
  AuthState build() => const AuthSignedIn(_customer);
}

class _FakePrescriptionClient extends PrescriptionApiClient {
  _FakePrescriptionClient({
    List<Prescription>? pending,
    List<Prescription>? mine,
  }) : pending = pending ?? <Prescription>[],
       mine = mine ?? <Prescription>[],
       super(ApiClient());

  final List<Prescription> pending;
  final List<Prescription> mine;

  String? reviewedId;
  String? reviewedStatus;
  String? reviewedNote;
  int? reviewedQuantity;

  @override
  Future<List<Prescription>> listPending() async => pending;

  @override
  Future<List<Prescription>> listMine() async => mine;

  @override
  Future<Prescription> getById(String id) async =>
      pending.firstWhere((p) => p.id == id);

  @override
  Future<Prescription> review({
    required String id,
    required String status,
    String? reviewNote,
    int? maxQuantity,
  }) async {
    reviewedId = id;
    reviewedStatus = status;
    reviewedNote = reviewNote;
    reviewedQuantity = maxQuantity;
    return pending.firstWhere((p) => p.id == id);
  }
}

Widget _host({
  required Widget child,
  required AuthController Function() auth,
  required PrescriptionApiClient client,
}) {
  return ProviderScope(
    overrides: [
      authProvider.overrideWith(auth),
      prescriptionApiClientProvider.overrideWithValue(client),
    ],
    child: MaterialApp(home: child),
  );
}

/// Opens the detail page from a real route so a successful review can pop back
/// to something instead of leaving the test on an empty navigator.
Widget _detailHost(
  _FakePrescriptionClient client,
  String id,
) {
  return _host(
    auth: _PharmacistAuth.new,
    client: client,
    child: _DetailLauncher(prescriptionId: id),
  );
}

class _DetailLauncher extends StatelessWidget {
  const _DetailLauncher({required this.prescriptionId});

  final String prescriptionId;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: ElevatedButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  PrescriptionReviewScreen(prescriptionId: prescriptionId),
            ),
          ),
          child: const Text('Open request'),
        ),
      ),
    );
  }
}

void main() {
  setUp(() => FlutterSecureStorage.setMockInitialValues(<String, String>{}));

  testWidgets('pharmacist sees the pending queue instead of the upload form', (
    WidgetTester tester,
  ) async {
    final client = _FakePrescriptionClient(pending: [_prescription()]);

    await tester.pumpWidget(
      _host(
        auth: _PharmacistAuth.new,
        client: client,
        child: const Scaffold(body: PrescriptionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Prescription reviews'), findsOneWidget);
    expect(find.text('Napa Extra'), findsOneWidget);
    expect(find.text('Rina Ahmed'), findsOneWidget);
    expect(find.text('New prescription request'), findsNothing);
  });

  testWidgets('tapping a pending request opens details with a back button', (
    WidgetTester tester,
  ) async {
    final client = _FakePrescriptionClient(pending: [_prescription()]);

    await tester.pumpWidget(
      _host(
        auth: _PharmacistAuth.new,
        client: client,
        child: const Scaffold(body: PrescriptionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Napa Extra'));
    await tester.pumpAndSettle();

    expect(find.text('Prescription review'), findsOneWidget);
    expect(find.text('Rina Ahmed'), findsOneWidget);
    expect(find.text('Approve'), findsOneWidget);
    expect(find.text('Reject'), findsOneWidget);
    expect(find.byTooltip('Back'), findsOneWidget);

    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();

    expect(find.text('Prescription reviews'), findsOneWidget);
  });

  testWidgets('rejecting requires a reason before calling the server', (
    WidgetTester tester,
  ) async {
    final client = _FakePrescriptionClient(pending: [_prescription()]);

    await tester.pumpWidget(_detailHost(client, 'rx-1'));
    await tester.tap(find.text('Open request'));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reject'));
    await tester.pump();

    expect(
      find.textContaining('Add a reason for the rejection'),
      findsOneWidget,
    );
    expect(client.reviewedStatus, isNull);
  });

  testWidgets('rejecting sends the note the customer will see', (
    WidgetTester tester,
  ) async {
    final client = _FakePrescriptionClient(pending: [_prescription()]);

    await tester.pumpWidget(_detailHost(client, 'rx-1'));
    await tester.tap(find.text('Open request'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Note for the customer'),
      'The prescription is out of date.',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();

    expect(client.reviewedId, 'rx-1');
    expect(client.reviewedStatus, 'rejected');
    expect(client.reviewedNote, 'The prescription is out of date.');
    expect(find.text('Open request'), findsOneWidget);
  });

  testWidgets('approving sends the authorised quantity', (
    WidgetTester tester,
  ) async {
    final client = _FakePrescriptionClient(pending: [_prescription()]);

    await tester.pumpWidget(_detailHost(client, 'rx-1'));
    await tester.tap(find.text('Open request'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.widgetWithText(TextField, 'Authorised quantity (units)'),
      '12',
    );
    await tester.drag(find.byType(ListView), const Offset(0, -500));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve'));
    await tester.pumpAndSettle();

    expect(client.reviewedStatus, 'approved');
    expect(client.reviewedQuantity, 12);
  });

  testWidgets('customer still sees the upload form and the rejection reason', (
    WidgetTester tester,
  ) async {
    final client = _FakePrescriptionClient(
      mine: [
        _prescription(
          status: 'rejected',
          reviewNote: 'The scan is too blurry to read the dosage.',
        ),
      ],
    );

    await tester.pumpWidget(
      _host(
        auth: _CustomerAuth.new,
        client: client,
        child: const Scaffold(body: PrescriptionScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('New prescription request'), findsOneWidget);
    expect(
      find.textContaining('The scan is too blurry'),
      findsOneWidget,
    );
  });
}
