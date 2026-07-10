import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:itrack_fe/api/http_adapter.dart';
import 'package:itrack_fe/app.dart';
import 'package:itrack_fe/state/auth_state.dart';
import 'package:itrack_fe/state/server_config.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // On native, trust the configured host's self-signed cert for Socket.IO
  // too (it uses a separate dart:io stack). No-op on web.
  installSelfSignedHttpOverrides();

  final serverConfig = ServerConfig();
  await serverConfig.load();

  final authState = AuthState();
  await authState.restoreSession();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: serverConfig),
        ChangeNotifierProvider.value(value: authState),
      ],
      child: const ITrackApp(),
    ),
  );
}
