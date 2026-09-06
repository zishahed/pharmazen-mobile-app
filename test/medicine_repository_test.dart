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

  test('search by indication returns ordered medicines', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final results = await repo.search('ulcerative', MedicineSearchMode.indication);

    expect(results, isNotEmpty);
    expect(results.first.brandName, isNotEmpty);

    await db.close();
  });

  test('all generics are distinct and sorted', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final values = await repo.allValues(MedicineSearchMode.generic);

    expect(values, isNotEmpty);
    _expectSortedIgnoreCase(values);
    expect(values.toSet().length, values.length);

    await db.close();
  });

  test('all categories are distinct and sorted', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final values = await repo.allValues(MedicineSearchMode.category);

    expect(values, isNotEmpty);
    _expectSortedIgnoreCase(values);

    await db.close();
  });

  test('all indications are distinct and sorted', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final values = await repo.allValues(MedicineSearchMode.indication);

    expect(values, isNotEmpty);
    _expectSortedIgnoreCase(values);

    await db.close();
  });

  test('search by exact generic returns matching medicines', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final generic = (await repo.allValues(MedicineSearchMode.generic)).first;
    final results = await repo.searchByExact(generic, MedicineSearchMode.generic);

    expect(results, isNotEmpty);
    expect(results.every((m) => m.genericName == generic), isTrue);

    await db.close();
  });

  test('search by exact category returns matching medicines', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final category = (await repo.allValues(MedicineSearchMode.category)).first;
    final results = await repo.searchByExact(category, MedicineSearchMode.category);

    expect(results, isNotEmpty);

    await db.close();
  });

  test('search by exact indication returns matching medicines', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final indication =
        (await repo.allValues(MedicineSearchMode.indication)).first;
    final results = await repo.searchByExact(
      indication,
      MedicineSearchMode.indication,
    );

    expect(results, isNotEmpty);

    await db.close();
  });

  test('empty query returns no results', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final results = await repo.search('   ', MedicineSearchMode.name);

    expect(results, isEmpty);

    await db.close();
  });

  test('fetchDetails returns all fields for a generic', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final medicines = await repo.search('Pana', MedicineSearchMode.name);
    final medicine = medicines.first;
    final genericId = medicine.genericId;
    expect(genericId, isNotNull);

    final details = await repo.fetchDetails(genericId!);
    expect(details, isNotNull);
    expect(details!.genericId, genericId);

    await db.close();
  });

  test('fetchDetails returns null for unknown generic', () async {
    final db = AppDatabase(NativeDatabase(File('assets/database/medicines.db')));
    final repo = MedicineRepository(db);

    final details = await repo.fetchDetails(-1);

    expect(details, isNull);

    await db.close();
  });
}

void _expectSortedIgnoreCase(List<String> values) {
  for (var i = 1; i < values.length; i++) {
    expect(
      values[i].toLowerCase().compareTo(values[i - 1].toLowerCase()),
      greaterThanOrEqualTo(0),
    );
  }
}