import 'dart:convert';

/// Wire contract for `GET /api/sync` and `GET /api/sync/manifest`.
///
/// Phase 2 implements the server side against exactly these shapes and against
/// [contentHash]; nothing here depends on the endpoint existing yet, so the
/// engine is testable against a fake.
///
/// A delta page looks like:
/// ```json
/// {
///   "nextCursor": "opaque-or-null",
///   "isFullResync": false,
///   "generics":   [{ "genericId": 1, "genericName": "...", "isDeleted": false }],
///   "medicines":  [{ "id": "uuid", "brandName": "...", "isDeleted": false }]
/// }
/// ```
/// Field names are camelCase because that is what Prisma returns, which keeps
/// the server handler a pass-through. `id` is the Neon UUID and lands in the
/// local `medicines.remote_id` column.

/// One page of a `?since=` delta.
class SyncDeltaPage {
  const SyncDeltaPage({
    required this.medicines,
    required this.generics,
    this.nextCursor,
    this.serverTime,
    this.isFullResync = false,
  });

  final List<SyncMedicine> medicines;
  final List<SyncGeneric> generics;

  /// Opaque continuation token. Null means this is the last page.
  final String? nextCursor;

  /// The server's clock at the moment the snapshot was taken. After the final
  /// page commits this becomes the next `since`, which is what makes the cursor
  /// safe: it is the instant after which *every* change is guaranteed to appear
  /// in some later delta, including rows edited mid-paging.
  ///
  /// **Phase 2 must send this.** Deriving the cursor from the maximum `updatedAt`
  /// in the payload instead would silently skip any row sharing a timestamp with
  /// the last row of the last page. Optional only so an incomplete server can
  /// still be tested against.
  final String? serverTime;

  /// Set when the supplied `since` predates the server's retention window, in
  /// which case the payload is the complete current state rather than a delta.
  final bool isFullResync;

  bool get isLastPage => nextCursor == null || nextCursor!.isEmpty;

  static SyncDeltaPage fromJson(Map<String, dynamic> json) {
    return SyncDeltaPage(
      medicines: _list(json['medicines'])
          .map(SyncMedicine.fromJson)
          .toList(growable: false),
      generics: _list(json['generics'])
          .map(SyncGeneric.fromJson)
          .toList(growable: false),
      nextCursor: json['nextCursor'] as String?,
      serverTime: json['serverTime'] as String?,
      isFullResync: json['isFullResync'] as bool? ?? false,
    );
  }
}

/// A remote medicine row.
class SyncMedicine {
  const SyncMedicine({
    required this.id,
    required this.brandName,
    required this.updatedAt,
    this.genericId,
    this.genericName,
    this.type,
    this.slug,
    this.dosageForm,
    this.strength,
    this.manufacturer,
    this.packageContainer,
    this.packageSize,
    this.isSensitive = false,
    this.isDeleted = false,
  });

  /// Neon UUID; the local `medicines.remote_id`.
  final String id;
  final String brandName;
  final int? genericId;

  /// Convenience copy denormalised onto the medicine. The server may send it
  /// null even when [genericId] is set; [GenericResolver] backfills from
  /// `generics` in that case.
  final String? genericName;
  final String? type;
  final String? slug;
  final String? dosageForm;
  final String? strength;
  final String? manufacturer;
  final String? packageSize;
  final String? packageContainer;
  final bool isSensitive;
  final bool isDeleted;

  /// Server timestamp. Deliberately not parsed into a `DateTime`: the cursor is
  /// passed back to the server verbatim, so round-tripping the exact string is
  /// safer than reformatting it.
  final String updatedAt;

  static SyncMedicine fromJson(Map<String, dynamic> json) {
    return SyncMedicine(
      id: json['id'] as String,
      brandName: (json['brandName'] ?? json['name']) as String,
      genericId: _asId(json['genericId']),
      genericName: json['genericName'] as String?,
      type: json['type'] as String?,
      slug: json['slug'] as String?,
      dosageForm: json['dosageForm'] as String?,
      strength: json['strength'] as String?,
      manufacturer: json['manufacturer'] as String?,
      packageContainer: json['packageContainer'] as String?,
      packageSize: json['packageSize'] as String?,
      isSensitive: json['isSensitive'] as bool? ?? false,
      isDeleted: json['isDeleted'] as bool? ?? false,
      updatedAt: (json['updatedAt'] ?? '') as String,
    );
  }

  /// Hash of everything the local row will contain, so an unchanged remote row
  /// can be skipped without rewriting it.
  String get contentHash => computeMedicineHash(this);
}

/// A remote generic row, mirroring Neon's `Generic` 1:1.
class SyncGeneric {
  const SyncGeneric({
    required this.genericId,
    required this.genericName,
    this.slug,
    this.monographLink,
    this.drugClass,
    this.indication,
    this.descriptions = const {},
    this.descriptionsCount = 0,
    this.isDeleted = false,
  });

  final int genericId;
  final String genericName;
  final String? slug;
  final String? monographLink;
  final String? drugClass;
  final String? indication;

  /// The 15 `*_description` columns, keyed without the `_description` suffix
  /// (e.g. `indication`, `sideEffects`). All default null.
  final Map<String, String?> descriptions;
  final int descriptionsCount;
  final bool isDeleted;

  /// Column names of the monograph fields, in a fixed order so [contentHash] is
  /// stable. Mirrors the local `generics` schema.
  static const List<String> descriptionColumns = [
    'indication',
    'therapeuticClass',
    'pharmacology',
    'dosage',
    'administration',
    'interaction',
    'contraindications',
    'sideEffects',
    'pregnancyAndLactation',
    'precautions',
    'pediatricUsage',
    'overdoseEffects',
    'durationOfTreatment',
    'reconstitution',
    'storageConditions',
  ];

  static SyncGeneric fromJson(Map<String, dynamic> json) {
    final descriptions = <String, String?>{};
    for (final column in descriptionColumns) {
      descriptions[column] =
          json['${column}Description'] as String? ??
          json[column] as String?;
    }
    return SyncGeneric(
      genericId: _asId(json['genericId'])!,
      genericName: json['genericName'] as String,
      slug: json['slug'] as String?,
      monographLink: json['monographLink'] as String?,
      drugClass: json['drugClass'] as String?,
      indication: json['indication'] as String?,
      descriptions: descriptions,
      descriptionsCount: json['descriptionsCount'] as int? ?? 0,
      isDeleted: json['isDeleted'] as bool? ?? false,
    );
  }

  String get contentHash => computeGenericHash(this);
}

/// One `[[remoteId, hash], ...]` pair from `GET /api/sync/manifest`.
class SyncManifestEntry {
  const SyncManifestEntry({required this.remoteId, required this.contentHash});

  final String remoteId;
  final String contentHash;

  static SyncManifestEntry fromJson(List<dynamic> pair) {
    return SyncManifestEntry(
      remoteId: pair[0] as String,
      contentHash: pair[1] as String,
    );
  }
}

// ---------------------------------------------------------------------------
// contentHash
// ---------------------------------------------------------------------------

final BigInt _fnvMask64 = (BigInt.one << 64) - BigInt.one;
final BigInt _fnvOffsetBasis = BigInt.parse('14695981039346656037');
final BigInt _fnvPrime = BigInt.parse('1099511628211');
const int _unitSeparator = 0x1F;

/// FNV-1a, 64-bit, over the UTF-8 bytes of each field joined by U+001F, with
/// null rendered as the empty string. Rendered as 16 lowercase hex digits.
///
/// Chosen because it is trivial to reproduce exactly in Node with `BigInt`, which
/// Phase 2 needs — a hash that cannot be ported is useless for manifest
/// comparison. 64 bits keeps the collision probability across ~21.7k medicines
/// negligible; 32 bits would already give a ~5% chance of one collision.
///
/// **Phase 2 must port this verbatim**, including the separator and the field
/// order below, or manifest comparison will flag every row as drifted.
String contentHashOfFields(List<String?> fields) {
  var hash = _fnvOffsetBasis;
  for (final field in fields) {
    for (final byte in utf8.encode(field ?? '')) {
      hash = (hash ^ BigInt.from(byte)) * _fnvPrime & _fnvMask64;
    }
    hash = (hash ^ BigInt.from(_unitSeparator)) * _fnvPrime & _fnvMask64;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Field order is part of the contract; see [contentHashOfFields].
String computeMedicineHash(SyncMedicine m) {
  return contentHashOfFields([
    m.brandName,
    m.genericName,
    '${m.genericId ?? ''}',
    m.type,
    m.slug,
    m.dosageForm,
    m.strength,
    m.manufacturer,
    m.packageContainer,
    m.packageSize,
    m.isSensitive ? '1' : '0',
    m.isDeleted ? '1' : '0',
  ]);
}

/// Field order is part of the contract; see [contentHashOfFields].
String computeGenericHash(SyncGeneric g) {
  return contentHashOfFields([
    g.genericName,
    g.slug,
    g.monographLink,
    g.drugClass,
    g.indication,
    for (final column in SyncGeneric.descriptionColumns)
      g.descriptions[column],
    g.descriptionsCount.toString(),
    g.isDeleted ? '1' : '0',
  ]);
}

List<Map<String, dynamic>> _list(Object? value) {
  if (value is! List) return const [];
  return value.whereType<Map<String, dynamic>>().toList(growable: false);
}

/// Generics ids are ints on both sides, but a JSON number that arrives as a
/// double (or a string, from a sloppy serialiser) must not become null.
int? _asId(Object? value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}