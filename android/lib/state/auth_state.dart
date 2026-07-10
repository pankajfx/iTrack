import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:itrack_fe/api/api_client.dart';
import 'package:itrack_fe/api/auth_api.dart';
import 'package:itrack_fe/models/user.dart';
import 'package:itrack_fe/services/socket_service.dart';

enum AuthStatus { unknown, loggedOut, loggedIn }

/// Login/session state. The actual credential is the Flask session cookie
/// held by the persistent cookie jar; this class tracks who is logged in and
/// reacts to session expiry signalled by the ApiClient interceptor.
class AuthState extends ChangeNotifier {
  static const _prefGroup = 'last_fe_group';
  static const _prefName = 'last_fe_name';

  final AuthApi _api = AuthApi();

  AuthStatus _status = AuthStatus.unknown;
  User? _user;
  bool _sessionExpiredNotice = false;

  AuthStatus get status => _status;
  User? get user => _user;

  /// One-shot flag the login screen reads to show "Session expired".
  bool consumeSessionExpiredNotice() {
    final value = _sessionExpiredNotice;
    _sessionExpiredNotice = false;
    return value;
  }

  AuthState() {
    ApiClient.instance.onSessionExpired = _handleSessionExpired;
  }

  /// On app start (after ServerConfig.load): check whether the persisted
  /// cookie still maps to a live server session.
  Future<void> restoreSession() async {
    if (!ApiClient.instance.isConfigured) {
      _status = AuthStatus.loggedOut;
      notifyListeners();
      return;
    }
    try {
      _user = await _api.me();
      _status = _user != null ? AuthStatus.loggedIn : AuthStatus.loggedOut;
    } catch (_) {
      // Server unreachable — stay logged out; user can retry from login.
      _status = AuthStatus.loggedOut;
    }
    notifyListeners();
  }

  Future<void> login({
    required String feName,
    required String feGroup,
    required String password,
  }) async {
    await _api.login(feName: feName, feGroup: feGroup, password: password);
    // Login response carries only {success, role}; fetch the full profile
    // (user_id is needed for Socket.IO room joins).
    _user = await _api.me();
    _status = AuthStatus.loggedIn;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefGroup, feGroup);
    await prefs.setString(_prefName, feName);
    notifyListeners();
  }

  Future<void> logout() async {
    try {
      await _api.logout();
    } catch (_) {
      // Even if the server call fails, drop the local session.
    }
    SocketService.instance.disconnect();
    _user = null;
    _status = AuthStatus.loggedOut;
    notifyListeners();
  }

  /// Remembered dropdown selections for the login screen.
  Future<(String?, String?)> lastLoginSelection() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getString(_prefGroup), prefs.getString(_prefName));
  }

  void _handleSessionExpired() {
    if (_status != AuthStatus.loggedIn) return;
    _sessionExpiredNotice = true;
    SocketService.instance.disconnect();
    _user = null;
    _status = AuthStatus.loggedOut;
    notifyListeners();
  }
}
