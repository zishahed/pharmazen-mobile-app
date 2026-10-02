import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:image/image.dart' as img;

import 'api_client.dart';

/// Server-side ceiling from `src/utils/uploadLimits.js`. Kept as a literal
/// rather than fetched: it is a property of the deploy, and an upload that
/// exceeds it fails with a platform-level 413 that no API error body describes.
const int kMaxUploadBytes = 2 * 1024 * 1024;

/// `upload.array('files', MAX_FILES)` — the field name is `files`, not `images`.
const int kMaxUploadFiles = 2;

/// Comfortably under [kMaxUploadBytes] so a borderline encode is not rejected
/// by multer after the round trip.
const int _kTargetBytes = 1800 * 1024;

const int _kMaxDimension = 2000;

/// Geometry of the extra shrinking passes. Each attempt removes a quarter of
/// the longest side, so four attempts take 2000px down to ~630px, which is
/// enough for any image the picker can return.
const double _kShrinkFactor = 0.75;
const int _kMaxShrinkAttempts = 4;

/// JPEG quality floor for a single pass. Kept well above the point where
/// prescription text becomes unreadable.
const int _kMinQuality = 40;

/// One of the user's prescriptions, as returned by `/api/prescriptions`.
class Prescription {
  const Prescription({
    required this.id,
    required this.medicineId,
    required this.medicineName,
    required this.startDate,
    required this.endDate,
    required this.status,
    required this.createdAt,
    this.comment,
    this.reviewNote,
    this.maxQuantity = 5,
    this.consumedQuantity = 0,
    this.remainingQuantity,
    this.fileUrls = const <String>[],
  });

  final String id;
  final String medicineId;
  final String medicineName;
  final DateTime startDate;
  final DateTime endDate;
  final String status;
  final DateTime createdAt;
  final String? comment;
  final String? reviewNote;
  final int maxQuantity;
  final int consumedQuantity;

  /// Phase 7b. Null only if the server predates the field.
  final int? remainingQuantity;

  final List<String> fileUrls;

  bool get isPending => status == 'pending';
  bool get isApproved => status == 'approved' || status == 'verified';
  bool get isRejected => status == 'rejected';

  factory Prescription.fromJson(Map<String, dynamic> json) => Prescription(
    id: json['id'] as String,
    medicineId: (json['medicineId'] as String?) ?? '',
    medicineName: (json['medicineName'] as String?) ?? 'Unknown medicine',
    startDate: DateTime.parse(json['startDate'] as String),
    endDate: DateTime.parse(json['endDate'] as String),
    status: (json['status'] as String?) ?? 'pending',
    createdAt: DateTime.parse(json['createdAt'] as String),
    comment: json['comment'] as String?,
    reviewNote: json['reviewNote'] as String?,
    maxQuantity: (json['maxQuantity'] as int?) ?? 5,
    consumedQuantity: (json['consumedQuantity'] as int?) ?? 0,
    remainingQuantity: json['remainingQuantity'] as int?,
    fileUrls: (json['files'] as List<dynamic>? ?? const <dynamic>[])
        .map((f) => (f as Map<String, dynamic>)['fileUrl'] as String)
        .toList(growable: false),
  );
}

/// A rejected upload, carrying the server's own wording.
///
/// The prescriptions controller answers with an `error` key rather than the
/// `message` key the auth controller uses, so both are read.
class PrescriptionException implements Exception {
  const PrescriptionException(this.message, {this.statusCode});

  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

/// Reads and writes `/api/prescriptions`.
///
/// Online-only by design: a prescription is reviewed server-side and the local
/// catalogue has no prescription state to stay consistent with, so there is
/// nothing meaningful to queue offline.
class PrescriptionApiClient {
  PrescriptionApiClient(this._api);

  final ApiClient _api;

  /// Compresses and uploads a prescription request.
  ///
  /// Throws [PrescriptionException] on any non-2xx, including multer's 400 for
  /// a rejected file type.
  Future<Prescription> upload({
    required List<PrescriptionAttachment> files,
    required String medicineId,
    required String medicineName,
    required DateTime startDate,
    required DateTime endDate,
    String? comment,
  }) async {
    if (files.isEmpty) {
      throw const PrescriptionException('Attach at least one photo or PDF.');
    }
    if (files.length > kMaxUploadFiles) {
      throw const PrescriptionException(
        'Attach at most $kMaxUploadFiles files.',
      );
    }

    final parts = <MultipartFile>[];
    for (final file in files) {
      final prepared = await prepare(file);
      parts.add(
        MultipartFile.fromBytes(
          prepared.bytes,
          filename: prepared.filename,
          contentType: DioMediaType.parse(prepared.mediaType),
        ),
      );
    }

    final form = FormData.fromMap(<String, dynamic>{
      'files': parts,
      'medicineId': medicineId,
      'medicineName': medicineName,
      // Date-only columns server-side; send calendar dates, not timestamps, so
      // a timezone west of UTC cannot shift the course start by a day.
      'startDate': _dateOnly(startDate),
      'endDate': _dateOnly(endDate),
      if (comment != null && comment.trim().isNotEmpty)
        'comment': comment.trim(),
    });

    final response = await _api.dio.post<Map<String, dynamic>>(
      '/prescriptions',
      data: form,
      options: Options(
        // The sync client's 15s timeout is tuned for catalogue reads; a
        // multipart upload over mobile data needs longer.
        sendTimeout: const Duration(seconds: 60),
        receiveTimeout: const Duration(seconds: 60),
      ),
    );

    if (response.statusCode != 201) {
      throw PrescriptionException(
        ApiClient.messageOf(response.data) ??
            'Could not upload the prescription.',
        statusCode: response.statusCode,
      );
    }

    final data = response.data?['data'] as Map<String, dynamic>?;
    if (data == null) {
      throw const PrescriptionException('The server sent an unexpected reply.');
    }
    return Prescription.fromJson(data);
  }

  Future<List<Prescription>> listMine() async {
    final response = await _api.dio.get<Map<String, dynamic>>('/prescriptions');
    if (response.statusCode != 200) {
      throw PrescriptionException(
        ApiClient.messageOf(response.data) ?? 'Could not load your prescriptions.',
        statusCode: response.statusCode,
      );
    }
    final data = (response.data?['data'] as List<dynamic>?) ?? const <dynamic>[];
    return data
        .map((e) => Prescription.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
  }

  static String _dateOnly(DateTime value) {
    final m = value.month.toString().padLeft(2, '0');
    final d = value.day.toString().padLeft(2, '0');
    return '${value.year}-$m-$d';
  }
}

/// A file chosen from the device, before it has been made upload-safe.
class PrescriptionAttachment {
  const PrescriptionAttachment({
    required this.bytes,
    required this.filename,
    required this.mediaType,
  });

  final Uint8List bytes;
  final String filename;
  final String mediaType;

  bool get isPdf => mediaType == 'application/pdf';
}

/// The bytes actually sent, after compression.
class PreparedFile {
  const PreparedFile({
    required this.bytes,
    required this.filename,
    required this.mediaType,
    required this.originalBytes,
  });

  final Uint8List bytes;
  final String filename;
  final String mediaType;
  final int originalBytes;

  bool get wasCompressed => bytes.length < originalBytes;
}

/// Makes a picked file satisfy multer's limits.
///
/// PDFs pass through untouched — re-encoding a document as JPEG would destroy
/// it, and `image` cannot decode one anyway.
///
/// Images are downscaled and re-encoded *before* the size check rather than
/// after, because the failure this avoids is the common one: a modern phone
/// photo is 3-8MB, so a "reject anything over 2MB" rule would refuse the exact
/// files this feature exists for.
/// Scales [image] down so neither side exceeds [maxDimension], preserving
/// aspect ratio. Never enlarges.
img.Image _capped(img.Image image, int maxDimension) {
  final longest = image.width > image.height ? image.width : image.height;
  if (longest <= maxDimension) return image;
  final scale = maxDimension / longest;
  return img.copyResize(
    image,
    width: (image.width * scale).round().clamp(1, maxDimension),
    height: (image.height * scale).round().clamp(1, maxDimension),
  );
}

/// Encodes as JPEG, stepping quality down only as far as [target] requires — a
/// small image keeps its detail instead of being flattened to hit a target it
/// already met.
List<int> _encodeUnder(img.Image image, int target) {
  var quality = 85;
  var encoded = img.encodeJpg(image, quality: quality);
  while (encoded.length > target && quality > _kMinQuality) {
    quality -= 15;
    encoded = img.encodeJpg(image, quality: quality);
  }
  return encoded;
}

Future<PreparedFile> prepare(PrescriptionAttachment file) async {
  if (file.isPdf) {
    if (file.bytes.length > kMaxUploadBytes) {
      throw const PrescriptionException(
        'That PDF is larger than 2MB. Please upload a smaller file.',
      );
    }
    return PreparedFile(
      bytes: file.bytes,
      filename: file.filename,
      mediaType: file.mediaType,
      originalBytes: file.bytes.length,
    );
  }

  final decoded = img.decodeImage(file.bytes);
  if (decoded == null) {
    throw const PrescriptionException(
      'That file could not be read as an image.',
    );
  }

  var working = _capped(decoded, _kMaxDimension);
  var encoded = _encodeUnder(working, _kTargetBytes);

  // Detail-heavy images (dense text, fine grain) can still exceed the hard
  // ceiling once quality bottoms out. Shrink further instead of refusing: the
  // alternative is rejecting the exact photos this feature exists for, which is
  // the bug the website had. A prescription is legible at 1200px, so trading
  // resolution for an accepted upload is the right trade.
  var attempts = 0;
  while (encoded.length > kMaxUploadBytes && attempts < _kMaxShrinkAttempts) {
    attempts++;
    working = _capped(working, (working.width * _kShrinkFactor).floor());
    encoded = _encodeUnder(working, _kTargetBytes);
  }

  if (encoded.length > kMaxUploadBytes) {
    throw const PrescriptionException(
      'That photo is still too large after compression. Try a smaller image.',
    );
  }

  final stem = file.filename.contains('.')
      ? file.filename.substring(0, file.filename.lastIndexOf('.'))
      : file.filename;

  return PreparedFile(
    bytes: Uint8List.fromList(encoded),
    filename: '$stem.jpg',
    mediaType: 'image/jpeg',
    originalBytes: file.bytes.length,
  );
}