import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:itrack_fe/services/socket_service.dart';
import 'package:itrack_fe/state/auth_state.dart';
import 'package:itrack_fe/state/server_config.dart';
import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/screens/dashboard_screen.dart';
import 'package:itrack_fe/screens/login_screen.dart';
import 'package:itrack_fe/screens/server_setup_screen.dart';

class ITrackApp extends StatelessWidget {
  const ITrackApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'iTrack FE',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      home: const _RootRouter(),
    );
  }
}

/// Decides the first screen based on config + auth:
/// no server URL → Server Setup; not logged in → Login; else → Dashboard.
class _RootRouter extends StatelessWidget {
  const _RootRouter();

  @override
  Widget build(BuildContext context) {
    final serverConfig = context.watch<ServerConfig>();
    final auth = context.watch<AuthState>();

    if (!serverConfig.isConfigured) {
      return const ServerSetupScreen();
    }

    // Keep the socket connection aligned with the configured server.
    SocketService.instance.connect(serverConfig.baseUrl);

    switch (auth.status) {
      case AuthStatus.unknown:
        return const _SplashScreen();
      case AuthStatus.loggedOut:
        return const LoginScreen();
      case AuthStatus.loggedIn:
        return const DashboardScreen();
    }
  }
}

class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: CircularProgressIndicator()),
    );
  }
}
