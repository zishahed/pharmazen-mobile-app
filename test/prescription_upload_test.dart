import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:pharmazen_mobile_app/data/remote/api_client.dart';
import 'package:pharmazen_mobile_app/data/remote/prescription_api_client.dart';

/// A photo-shaped payload: noise compresses badly, so this reaches a realistic
/// multi-megabyte size the way a real camera roll photo does.
Uint8List _noiseJpeg({int dimension = 2400, int quality = 100}) {
  final image = img.Image(width: dimension, height: dimension);
  final random = Random(7);
  for (final pixel in image) {
    final v = random.nextInt(256);
    pixel
      ..r = v
      ..g = random.nextInt(256)
      ..b = random.nextInt(256);
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: quality));
}

PrescriptionAttachment _image(Uint8List bytes, {String name = 'photo.jpg'}) =>
    PrescriptionAttachment(
      bytes: bytes,
      filename: name,
      mediaType: 'image/jpeg',
    );

void main() {
  group('prepare', () {
    test('brings an oversized photo under the 2MB upload ceiling', () async {
      final original = _noiseJpeg();
      expect(
        original.length,
        greaterThan(kMaxUploadBytes),
        reason: 'fixture must start over the ceiling to be meaningful',
      );

      final prepared = await prepare(_image(original));

      expect(
        prepared.bytes.length,
        lessThanOrEqualTo(kMaxUploadBytes),
      );
      expect(prepared.wasCompressed, isTrue);
    });

    test('downsizes rather than only re-encoding', () async {
      final prepared = await prepare(_image(_noiseJpeg()));
      final decoded = img.decodeJpg(prepared.bytes)!;

      // The 2000px cap exists to bound decode memory on a low-end phone, not
      // just to satisfy the byte limit.
      expect(decoded.width, lessThanOrEqualTo(2000));
      expect(decoded.height, lessThanOrEqualTo(2000));
    });

    test('converts the upload to jpeg with a matching filename', () async {
      final prepared = await prepare(_image(_noiseJpeg(), name: 'scan.png'));

      expect(prepared.mediaType, 'image/jpeg');
      expect(prepared.filename, 'scan.jpg');
    });

    test('leaves a small image alone rather than flattening it', () async {
      final small = _noiseJpeg(dimension: 400, quality: 92);
      expect(small.length, lessThan(kMaxUploadBytes));

      final prepared = await prepare(_image(small));

      expect(prepared.bytes.length, lessThanOrEqualTo(small.length));
      expect(prepared.originalBytes, small.length);
    });

    test('passes a PDF through byte-for-byte', () async {
      final pdf = Uint8List.fromList(
        List<int>.generate(2048, (i) => i % 256),
      );

      final prepared = await prepare(
        PrescriptionAttachment(
          bytes: pdf,
          filename: 'script.pdf',
          mediaType: 'application/pdf',
        ),
      );

      expect(prepared.bytes, pdf);
      expect(prepared.filename, 'script.pdf');
      expect(prepared.mediaType, 'application/pdf');
    });

    test('rejects an oversized PDF instead of trying to re-encode it', () {
      final pdf = Uint8List(kMaxUploadBytes + 1);

      expect(
        () => prepare(
          PrescriptionAttachment(
            bytes: pdf,
            filename: 'big.pdf',
            mediaType: 'application/pdf',
          ),
        ),
        throwsA(isA<PrescriptionException>()),
      );
    });

    test('reports undecodable image bytes clearly', () {
      final junk = Uint8List.fromList(List<int>.filled(512, 7));

      expect(
        () => prepare(_image(junk, name: 'broken.jpg')),
        throwsA(
          isA<PrescriptionException>().having(
            (e) => e.message,
            'message',
            contains('could not be read'),
          ),
        ),
      );
    });
  });

  group('upload validation', () {
    test('refuses a request with no attachments', () {
      // Guarded before any network call, so a default client is enough.
      final client = PrescriptionApiClient(ApiClient());

      expect(
        () => client.upload(
          files: const <PrescriptionAttachment>[],
          medicineId: 'uuid',
          medicineName: 'Napa',
          startDate: DateTime(2026, 1, 1),
          endDate: DateTime(2026, 1, 7),
        ),
        throwsA(isA<PrescriptionException>()),
      );
    });

    test('refuses more files than multer will accept', () {
      final client = PrescriptionApiClient(ApiClient());
      final many = List<PrescriptionAttachment>.generate(
        kMaxUploadFiles + 1,
        (_) => PrescriptionAttachment(
          bytes: Uint8List.fromList([1]),
          filename: 'a.jpg',
          mediaType: 'image/jpeg',
        ),
      );

      expect(
        () => client.upload(
          files: many,
          medicineId: 'uuid',
          medicineName: 'Napa',
          startDate: DateTime(2026, 1, 1),
          endDate: DateTime(2026, 1, 7),
        ),
        throwsA(
          isA<PrescriptionException>().having(
            (e) => e.message,
            'message',
            contains('at most'),
          ),
        ),
      );
    });
  });

  group('Prescription.fromJson', () {
    test('reads the DTO shape including Phase 7b fields', () {
      final p = Prescription.fromJson({
        'id': 'abc',
        'medicineId': '11111111-1111-1111-1111-111111111111',
        'medicineName': 'Napa Extra',
        'startDate': '2026-01-01T00:00:00.000Z',
        'endDate': '2026-01-07T00:00:00.000Z',
        'status': 'approved',
        'createdAt': '2026-01-01T10:00:00.000Z',
        'maxQuantity': 10,
        'consumedQuantity': 3,
        'remainingQuantity': 7,
        'files': [
          {'fileUrl': 'https://cdn/a.jpg'},
          {'fileUrl': 'https://cdn/b.jpg'},
        ],
      });

      expect(p.isApproved, isTrue);
      expect(p.isPending, isFalse);
      expect(p.remainingQuantity, 7);
      expect(p.fileUrls, hasLength(2));
    });

    test('treats a missing remainingQuantity as unknown, not zero', () {
      final p = Prescription.fromJson({
        'id': 'abc',
        'medicineId': 'uuid',
        'medicineName': 'Napa',
        'startDate': '2026-01-01T00:00:00.000Z',
        'endDate': '2026-01-07T00:00:00.000Z',
        'status': 'pending',
        'createdAt': '2026-01-01T10:00:00.000Z',
      });

      // Zero would read as "nothing left", which is a different claim.
      expect(p.remainingQuantity, isNull);
      expect(p.isPending, isTrue);
    });
  });
}