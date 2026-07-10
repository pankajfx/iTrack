import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:itrack_fe/api/api_client.dart';
import 'package:itrack_fe/utils/constants.dart';

/// Persisted server base URL (e.g. https://192.168.1.50 for the prod
/// reverse proxy, or http://192.168.1.50:5001 for a dev laptop server).
class ServerConfig extends ChangeNotifier {
  static const _prefKey = 'server_base_url';

  /// Host of the currently-configured server, read by the global
  /// HttpOverrides in main.dart to scope self-signed cert trust.
  /// Static because HttpOverrides has no access to the provider tree.
  static String? currentHost;

  String _baseUrl = '';
  String get baseUrl => _baseUrl;
  bool get isConfigured => _baseUrl.isNotEmpty;

  /// Load the saved URL and configure the API client. Call once at startup.
  /// Falls back to the hardwired [defaultServerUrl] (constants.dart) on a
  /// fresh install, so the app goes straight to login. A user-saved URL
  /// (Server Settings) always takes precedence; the default is not persisted
  /// so a future APK with a new default applies without clearing app data.
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(_prefKey) ?? '';
    if (_baseUrl.isEmpty) _baseUrl = defaultServerUrl;
    if (_baseUrl.isNotEmpty) {
      currentHost = Uri.parse(_baseUrl).host;
      await ApiClient.instance.configure(_baseUrl);
    }
    notifyListeners();
  }

  /// Validate, persist, and apply a new server URL.
  /// Throws [FormatException] with a friendly message when invalid.
  Future<void> save(String url) async {
    var cleaned = url.trim();
    if (cleaned.endsWith('/')) {
      cleaned = cleaned.substring(0, cleaned.length - 1);
    }
    final uri = Uri.tryParse(cleaned);
    if (uri == null ||
        !(uri.scheme == 'http' || uri.scheme == 'https') ||
        uri.host.isEmpty) {
      throw const FormatException(
          'Enter a full URL like http://192.168.1.50:5001 or https://server');
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, cleaned);
    _baseUrl = cleaned;
    currentHost = uri.host;
    await ApiClient.instance.configure(cleaned);
    notifyListeners();
  }
}
