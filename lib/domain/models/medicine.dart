class Medicine {
  /// The server-side UUID (`medicines.id` in Postgres), or null when the row has
  /// not been synced yet.
  ///
  /// Needed whenever a request has to name this medicine to the API — a
  /// prescription upload sends `medicineId`, and the backend column is a
  /// `@db.Uuid`, so the local `brand_id` would be rejected. Only synced rows
  /// have one, which is a legitimate reason to refuse the action rather than
  /// send an id the server cannot resolve.
  final String? remoteId;

  final int brandId;
  final String brandName;
  final String? type;
  final String? slug;
  final String? dosageForm;
  final String? genericName;
  final String? strength;
  final String? manufacturer;
  final String? packageContainer;
  final String? packageSize;
  final int? genericId;
  final bool isSensitive;

  const Medicine({
    this.remoteId,
    required this.brandId,
    required this.brandName,
    this.type,
    this.slug,
    this.dosageForm,
    this.genericName,
    this.strength,
    this.manufacturer,
    this.packageContainer,
    this.packageSize,
    this.genericId,
    required this.isSensitive,
  });
}
