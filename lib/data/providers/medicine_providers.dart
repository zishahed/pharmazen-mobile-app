import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../db/app_database.dart';
import '../repositories/medicine_repository.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  // WAL is enabled here and nowhere else: this is the mutable on-device copy.
  // The bundled asset stays in `delete` journal mode.
  final db = AppDatabase(openConnection(), enableWal: true);
  ref.onDispose(db.close);
  return db;
});

final medicineRepositoryProvider = Provider<MedicineRepository>(
  (ref) => MedicineRepository(ref.watch(databaseProvider)),
);