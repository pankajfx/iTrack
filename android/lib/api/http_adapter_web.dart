import 'package:dio/browser.dart';
import 'package:dio/dio.dart';

/// Web implementation (Chrome — UI preview only). The browser stores cookies
/// itself, so we enable credentialed requests instead of a cookie jar. There
/// is no certificate override on web. Note: cross-origin API calls will still
/// be blocked by the browser because the Flask server sends no CORS headers —
/// this build is for inspecting the UI, not exercising the backend.
Future<void> setupHttpAdapter(Dio dio, String host) async {
  final adapter = dio.httpClientAdapter as BrowserHttpClientAdapter;
  adapter.withCredentials = true;
}

Future<void> clearHttpCookies() async {
  // Browser-managed; nothing to clear here.
}

void installSelfSignedHttpOverrides() {
  // No-op on web — there is no dart:io HttpOverrides.
}
