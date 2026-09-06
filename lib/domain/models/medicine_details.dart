class MedicineDetails {
  final int genericId;
  final String? genericName;
  final String? slug;
  final String? monographLink;
  final String? drugClass;
  final String? indication;
  final String? indicationDescription;
  final String? therapeuticClassDescription;
  final String? pharmacologyDescription;
  final String? dosageDescription;
  final String? administrationDescription;
  final String? interactionDescription;
  final String? contraindicationsDescription;
  final String? sideEffectsDescription;
  final String? pregnancyAndLactationDescription;
  final String? precautionsDescription;
  final String? pediatricUsageDescription;
  final String? overdoseEffectsDescription;
  final String? durationOfTreatmentDescription;
  final String? reconstitutionDescription;
  final String? storageConditionsDescription;

  const MedicineDetails({
    required this.genericId,
    this.genericName,
    this.slug,
    this.monographLink,
    this.drugClass,
    this.indication,
    this.indicationDescription,
    this.therapeuticClassDescription,
    this.pharmacologyDescription,
    this.dosageDescription,
    this.administrationDescription,
    this.interactionDescription,
    this.contraindicationsDescription,
    this.sideEffectsDescription,
    this.pregnancyAndLactationDescription,
    this.precautionsDescription,
    this.pediatricUsageDescription,
    this.overdoseEffectsDescription,
    this.durationOfTreatmentDescription,
    this.reconstitutionDescription,
    this.storageConditionsDescription,
  });
}