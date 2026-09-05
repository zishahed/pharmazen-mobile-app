import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

class AppDatabase extends GeneratedDatabase {
  AppDatabase(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  Iterable<TableInfo> get allTables => [];
}

LazyDatabase openConnection() {
  return LazyDatabase(() async {
    final appDir = await getApplicationDocumentsDirectory();
    final file = File(p.join(appDir.path, 'medicines.db'));
    if (!await file.exists()) {
      final data = await rootBundle.load('assets/database/medicines.db');
      await file.writeAsBytes(data.buffer.asUint8List(), flush: true);
    }
    return NativeDatabase.createInBackground(file);
  });
}