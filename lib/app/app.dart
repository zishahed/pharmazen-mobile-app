import 'package:flutter/material.dart';

import '../app/theme/app_theme.dart';
import 'router.dart';

class PharmaZenApp extends StatelessWidget {
  const PharmaZenApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp.router(
      debugShowCheckedModeBanner: false,
      title: 'PharmaZen',
      theme: AppTheme.light,
      routerConfig: appRouter,
    );
  }
}
