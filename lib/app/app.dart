import 'package:flutter/material.dart';

import 'router.dart';
import 'theme/app_theme.dart';

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
