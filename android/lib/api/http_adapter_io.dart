import 'dart:io';

import 'package:cookie_jar/cookie_jar.dart';
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:dio_cookie_manager/dio_cookie_manager.dart';
import 'package:path_provider/path_provider.dart';

import 'package:itrack_fe/state/server_config.dart';

/// Native implementation: persistent cookie jar + per-host self-signed trust.
PersistCookieJar? _cookieJar;

/// Attach the cookie manager and scope self-signed cert trust to [host].
Future<void> setupHttpAdapter(Dio dio, String host) async {
  if (_cookieJar == null) {
    final dir = await getApplicationSupportDirectory();
    _cookieJar = PersistCookieJar(storage: FileStorage('${dir.path}/.cookies/'));
  }
  dio.interceptors.add(CookieManager(_cookieJar!));

  final adapter = dio.httpClientAdapter as IOHttpClientAdapter;
  adapter.createHttpClient = () {
    final client = HttpClient();
    // Accept a bad certificate ONLY for the configured host — never blanket.
    client.badCertificateCallback = (cert, certHost, port) => certHost == host;
    return client;
  };
}

Future<void> clearHttpCookies() async => _cookieJar?.deleteAll();

/// Trust the same self-signed host for Socket.IO (separate dart:io stack).
class _SelfSignedHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final trustedHost = ServerConfig.currentHost;
    return super.createHttpClient(context)
      ..badCertificateCallback =
          (cert, host, port) => trustedHost != null && host == trustedHost;
  }
}

void installSelfSignedHttpOverrides() {
  HttpOverrides.global = _SelfSignedHttpOverrides();
}
