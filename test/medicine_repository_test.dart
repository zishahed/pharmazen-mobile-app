import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmazen_mobile_app/data/db/app_database.dart';
import 'package:pharmazen_mobile_app/data/repositories/medicine_repository.dart';

void main() {
  test('search by name returns ordered medicines', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final results = await repo.search('Pana', MedicineSearchMode.name);

    expect(results, isNotEmpty);
    final names = results.map((m) => m.brandName).toList();
    expect(names, orderedEquals([...names]..sort()));

    await db.close();
  });

  test('search by generic returns ordered medicines', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final results = await repo.search('aceclofen', MedicineSearchMode.generic);

    expect(results, isNotEmpty);
    expect(results.first.genericName?.toLowerCase(), contains('aceclofen'));

    await db.close();
  });

  test('search by category returns ordered medicines', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final results = await repo.search('Quinolone', MedicineSearchMode.category);

    expect(results, isNotEmpty);
    expect(results.first.brandName, isNotEmpty);

    await db.close();
  });

  test('empty query returns no results', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final results = await repo.search('   ', MedicineSearchMode.name);

    expect(results, isEmpty);

    await db.close();
  });
}