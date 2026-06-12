import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'screens/home_screen.dart';

void main() {
  runApp(const ProviderScope(child: VastEditApp()));
}

class VastEditApp extends StatelessWidget {
  const VastEditApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'VastEdit',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppColors.bg,
        colorScheme: const ColorScheme.dark(
          primary: AppColors.accent,
          surface: AppColors.surface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppColors.surface,
          elevation: 0,
        ),
        dividerColor: AppColors.border,
        fontFamily: 'SF Pro Display',
      ),
      home: const HomeScreen(),
    );
  }
}
