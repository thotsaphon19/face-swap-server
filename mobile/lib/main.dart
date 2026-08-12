import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'screens/home_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  runApp(FaceSwapApp(prefs: prefs));
}

class FaceSwapApp extends StatelessWidget {
  final SharedPreferences prefs;
  const FaceSwapApp({super.key, required this.prefs});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FaceSwap Cam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1565C0),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: HomeScreen(prefs: prefs),
    );
  }
}
