import 'package:itrack_fe/api/api_client.dart';
import 'package:itrack_fe/models/user.dart';
import 'package:itrack_fe/utils/constants.dart';

/// Auth + login-dropdown endpoints.
/// Login dropdowns are the same DB-driven lists the web login page uses.
class AuthApi {
  final ApiClient _client;
  AuthApi([ApiClient? client]) : _client = client ?? ApiClient.instance;

  /// GET /api/login/field-engineer-groups (unauthenticated).
  Future<List<LoginOption>> fieldEngineerGroups() async {
    final response = await _client.dio.get('/api/login/field-engineer-groups');
    return (response.data as List? ?? [])
        .map((e) => LoginOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// GET /api/login/field-engineers?field_engineer_group=X (unauthenticated).
  Future<List<LoginOption>> fieldEngineers(String group) async {
    final response = await _client.dio.get(
      '/api/login/field-engineers',
      queryParameters: {'field_engineer_group': group},
    );
    return (response.data as List? ?? [])
        .map((e) => LoginOption.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// POST /api/auth/login — on success the session cookie is stored by the
  /// cookie jar; the body only confirms {success, role}.
  Future<void> login({
    required String feName,
    required String feGroup,
    required String password,
  }) async {
    await _client.requestJson((dio) => dio.post('/api/auth/login', data: {
          'role': roleFieldEngineer,
          'fe_name': feName,
          'fe_group': feGroup,
          'password': password,
        }));
  }

  /// POST /api/auth/logout + wipe the local cookie jar.
  Future<void> logout() async {
    try {
      await _client.requestJson((dio) => dio.post('/api/auth/logout'));
    } finally {
      await _client.clearCookies();
    }
  }

  /// GET /api/android/me — validates the stored session on app start.
  /// Returns null when not authenticated (401).
  Future<User?> me() async {
    final response = await _client.dio.get('/api/android/me');
    if (response.statusCode == 200 &&
        response.data is Map<String, dynamic> &&
        response.data['authenticated'] == true) {
      return User.fromJson(response.data['user'] as Map<String, dynamic>);
    }
    return null;
  }

  /// GET /api/android/ping — Server Setup "Test Connection".
  Future<Map<String, dynamic>> ping() =>
      _client.requestJson((dio) => dio.get('/api/android/ping'));
}
