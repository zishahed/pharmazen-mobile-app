import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pharmazen_mobile_app/data/db/app_database.dart';
import 'package:pharmazen_mobile_app/data/providers/medicine_providers.dart';
import 'package:pharmazen_mobile_app/data/repositories/medicine_repository.dart';
import 'package:pharmazen_mobile_app/features/browse/browse_screen.dart';

class _FakeRepository extends MedicineRepository {
  _FakeRepository(super.db, this.values);

  final List<String> values;

  @override
  Future<List<String>> allValues(MedicineSearchMode mode) async => values;
}

/// Mirrors the grouping BrowseScreen does, without reaching into its internals.
Map<String, List<String>> _group(List<String> values) {
  final grouped = <String, List<String>>{};
  for (final value in values) {
    final trimmed = value.trim();
    final first = trimmed.isEmpty ? '' : trimmed[0].toUpperCase();
    final letter = RegExp('[A-Za-z]').hasMatch(first) ? first : '#';
    (grouped[letter] ??= <String>[]).add(value);
  }
  return grouped;
}

void main() {
  late AppDatabase memoryDb;
  late List<String> generics;

  setUpAll(() async {
    final assetDb = AppDatabase(
      NativeDatabase(File('assets/database/medicines.db')),
    );
    generics = await MedicineRepository(assetDb)
        .allValues(MedicineSearchMode.generic);
    await assetDb.close();
    memoryDb = AppDatabase(NativeDatabase.memory());
  });

  tearDownAll(() async => memoryDb.close());

  Future<void> pumpBrowse(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          medicineRepositoryProvider.overrideWithValue(
            _FakeRepository(memoryDb, generics),
          ),
        ],
        child: const MaterialApp(
          home: BrowseScreen(mode: MedicineSearchMode.generic),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Finder sidebar() => find
      .byWidgetPredicate(
        (widget) =>
            widget is GestureDetector &&
            widget.behavior == HitTestBehavior.opaque,
      )
      .first;

  Finder sectionHeaderBox(String letter) => find
      .ancestor(
        of: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.text(letter),
            )
            .first,
        matching: find.byType(Container),
      )
      .first;

  double sectionHeaderExtent(WidgetTester tester, String letter) =>
      tester.getSize(sectionHeaderBox(letter)).height;

  double itemExtent(WidgetTester tester) =>
      tester.getSize(find.byType(ListTile).first).height;

  double scrollPixels(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable)).position.pixels;

  Future<void> tapLetter(
    WidgetTester tester,
    List<String> letters,
    int index,
  ) async {
    final rect = tester.getRect(sidebar());
    final dy = (index + 0.5) / letters.length * rect.height;
    await tester.tapAt(Offset(rect.left + rect.width / 2, rect.top + dy));
  }

  testWidgets('jumping to a far letter lands exactly on its section header', (
    tester,
  ) async {
    await pumpBrowse(tester);

    final grouped = _group(generics);
    const letter = 'T';
    final targetIndex = grouped.keys.toList().indexOf(letter);

    // Extents measured from the real layout, independent of the implementation.
    final header = sectionHeaderExtent(tester, grouped.keys.first);
    final item = itemExtent(tester);

    var expected = 8.0;
    for (final entry in grouped.entries) {
      if (entry.key == letter) break;
      expected += header + entry.value.length * item;
    }

    await tapLetter(tester, grouped.keys.toList(), targetIndex);
    await tester.pump();

    expect(scrollPixels(tester), closeTo(expected, 0.5));
    expect(
      tester.getTopLeft(sectionHeaderBox(letter)).dy,
      closeTo(tester.getTopLeft(find.byType(CustomScrollView)).dy, 0.5),
    );
  });

  testWidgets('only visible rows are built, so a long list stays cheap', (
    tester,
  ) async {
    await pumpBrowse(tester);

    expect(generics.length, greaterThan(1000));
    expect(find.byType(ListTile).evaluate().length, lessThan(60));
  });

  testWidgets('a far jump is applied without an animation', (tester) async {
    await pumpBrowse(tester);

    final grouped = _group(generics);
    await tapLetter(
      tester,
      grouped.keys.toList(),
      grouped.keys.toList().indexOf('T'),
    );

    // Still no pump: the offset must already be at its final value.
    expect(scrollPixels(tester), greaterThan(1000));
  });

  testWidgets('a nearby letter animates instead of jumping', (tester) async {
    await pumpBrowse(tester);

    final letters = _group(generics).keys.toList();
    final last = letters.length - 1;

    // Land far away first, then step to the neighbour: short hops animate.
    await tapLetter(tester, letters, last);
    await tester.pumpAndSettle();
    final before = scrollPixels(tester);

    await tapLetter(tester, letters, last - 1);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final midway = scrollPixels(tester);
    await tester.pumpAndSettle();
    final settled = scrollPixels(tester);

    expect(midway, lessThan(before));
    expect(settled, lessThan(midway));
    expect(settled, lessThan(before));
  });
}
