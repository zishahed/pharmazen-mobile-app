class Medicine {
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
