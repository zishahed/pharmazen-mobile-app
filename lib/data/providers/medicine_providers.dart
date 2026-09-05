import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_database.dart';
import '../repositories/medicine_repository.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase(openConnection());
  ref.onDispose(db.close);
  return db;
});

final medicineRepositoryProvider = Provider<MedicineRepository>(
  (ref) => MedicineRepository(ref.watch(databaseProvider)),
);