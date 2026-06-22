import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'services/anilist_service.dart';
import 'services/notification_service.dart';
import 'services/nyaa_service.dart';
import 'services/storage_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final storage = StorageService();
  await storage.init();
  final notifications = NotificationService();
  await notifications.init();
  runApp(AniMagnetApp(storage: storage, notifications: notifications));
}

class AniMagnetApp extends StatelessWidget {
  final StorageService storage;
  final NotificationService notifications;
  const AniMagnetApp({
    super.key,
    required this.storage,
    required this.notifications,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AniMagnet',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      theme: _amoled(),
      darkTheme: _amoled(),
      home: HomeScreen(
        storage: storage,
        nyaa: NyaaService(),
        anilist: AniListService(),
        notifications: notifications,
      ),
    );
  }

  /// True-black (AMOLED) dark theme with blue accents.
  ThemeData _amoled() {
    const accent = Color(0xFF4F9DFF); // blue
    const surface = Color(0xFF0E0E12); // near-black for cards/sheets
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: Brightness.dark,
    ).copyWith(
      primary: accent,
      secondary: accent,
      surface: surface,
      surfaceContainerHighest: const Color(0xFF15151B),
    );

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: Colors.black,
      canvasColor: Colors.black,
      cardColor: surface,
      cardTheme: const CardThemeData(
        color: surface,
        elevation: 0,
        margin: EdgeInsets.zero,
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        elevation: 0,
      ),
      dividerColor: const Color(0xFF1E1E26),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: accent,
        foregroundColor: Colors.black,
      ),
    );
  }
}
