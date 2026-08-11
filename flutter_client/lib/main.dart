import 'package:flutter/material.dart';
import 'home_screen.dart';

void main() {
  runApp(const FaceSwapApp());
}

class FaceSwapApp extends StatelessWidget {
  const FaceSwapApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Swap',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1976D2),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: const HomeScreen(),
    );
  }
}
