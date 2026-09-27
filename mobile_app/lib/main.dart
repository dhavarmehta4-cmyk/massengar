import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'core/theme/app_theme.dart';
import 'core/security/biometric_lock_service.dart';
import 'presentation/blocs/chat/chat_bloc.dart';
import 'presentation/screens/auth/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize local DB and biometrics
  await LocalDatabase().database;

  // Set transparent status bar
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.light,
  ));

  runApp(const MassengarApp());
}

class MassengarApp extends StatelessWidget {
  const MassengarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MultiBlocProvider(
      providers: [
        // ChatBloc is application-scoped so the WebSocket subscription
        // survives screen transitions.
        BlocProvider<ChatBloc>(
          create: (_) => ChatBloc(),
          lazy: false,
        ),
      ],
      child: MaterialApp(
        title: 'Massengar',
        debugShowCheckedModeBanner: false,
        theme: AppTheme.darkTheme,
        home: const LoginScreen(),
      ),
    );
  }
}
