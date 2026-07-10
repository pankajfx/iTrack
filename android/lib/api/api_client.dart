import 'package:dio/dio.dart';

import 'package:itrack_fe/api/api_exception.dart';
import 'package:itrack_fe/api/http_adapter.dart';

/// Single Dio instance talking to the Flask server.
///
/// Key behaviors (see android/docs/ARCHITECTURE.md):
/// - Session-cookie auth: a [PersistCookieJar] stores the Flask `session`
///   cookie on disk, so the login survives app restarts. The cookie IS the
///   credential — there are no tokens.
/// - Auth-expiry detection: the web app answers unauthenticated API calls
///   with 302 → /login (HTML), not 401. We disable redirect-following and
///   translate that pattern into [SessionExpiredException].
/// - Self-signed HTTPS: the prod reverse proxy (Caddy/Nginx) uses a
///   self-signed certificate. We accept bad certificates ONLY for the
///   configured server host — never a blanket trust.
class ApiClient {
  ApiClient._();

  static final ApiClient instance = ApiClient._();

  /// A usable Dio exists from the start (empty base URL) so early calls to
  /// [isConfigured] before a server is set don't hit an uninitialized field.
  Dio dio = Dio();
  String _host = '';
  bool _configured = false;

  /// Called by AuthState when any request hits an expired session.
  void Function()? onSessionExpired;

  bool get isConfigured => _configured;

  /// (Re)configure for a server base URL, e.g. `https://192.168.1.50` or
  /// `http://192.168.1.50:5001`. Safe to call again when the user changes
  /// the URL on the Server Setup screen.
  Future<void> configure(String baseUrl) async {
    _host = Uri.parse(baseUrl).host;

    dio = Dio(BaseOptions(
      baseUrl: baseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 60),
      sendTimeout: const Duration(seconds: 120),
      followRedirects: false,
      // Let 3xx/4xx reach our interceptor instead of throwing early;
      // 5xx still throws.
      validateStatus: (status) => status != null && status < 500,
      headers: {'Accept': 'application/json'},
    ));

    // Platform HTTP wiring: cookie jar + self-signed trust on native,
    // credentialed browser requests on web (see http_adapter.dart).
    await setupHttpAdapter(dio, _host);
    dio.interceptors.add(InterceptorsWrapper(onResponse: _checkResponse));
    _configured = true;
  }

  /// Wipe the stored session cookie (logout / switch server).
  Future<void> clearCookies() async => clearHttpCookies();

  void _checkResponse(Response response, ResponseInterceptorHandler handler) {
    final status = response.statusCode ?? 0;

    // Flask's login_required: 302 → /login means "not authenticated".
    if (status >= 300 && status < 400) {
      final location = response.headers.value('location') ?? '';
      if (location.contains('/login')) {
        onSessionExpired?.call();
        handler.reject(DioException(
          requestOptions: response.requestOptions,
          response: response,
          error: const SessionExpiredException(),
        ));
        return;
      }
    }

    // HTML where JSON was expected — same signal via a different route.
    final contentType = response.headers.value('content-type') ?? '';
    if (status == 200 &&
        contentType.contains('text/html') &&
        response.requestOptions.path.startsWith('/api/')) {
      onSessionExpired?.call();
      handler.reject(DioException(
        requestOptions: response.requestOptions,
        response: response,
        error: const SessionExpiredException(),
      ));
      return;
    }

    handler.resolve(response);
  }

  /// Run a request and translate failures into [ApiException]s.
  /// [action] should perform exactly one Dio call and return the Response.
  Future<Map<String, dynamic>> requestJson(
    Future<Response> Function(Dio dio) action,
  ) async {
    Response response;
    try {
      response = await action(dio);
    } on DioException catch (e) {
      final inner = e.error;
      if (inner is ApiException) throw inner;
      if (e.type == DioExceptionType.connectionTimeout ||
          e.type == DioExceptionType.connectionError) {
        throw const ApiException(
            'Cannot reach server — check Server Settings and your network');
      }
      if (e.type == DioExceptionType.receiveTimeout ||
          e.type == DioExceptionType.sendTimeout) {
        throw const ApiException('Server took too long to respond — try again');
      }
      throw ApiException('Network error: ${e.message}');
    }

    final status = response.statusCode ?? 0;
    final data = response.data;
    final body = data is Map<String, dynamic> ? data : <String, dynamic>{};

    if (status >= 200 && status < 300) return body;

    if (status == 401) {
      // Distinguish genuine session expiry (android_backend guards return
      // error:'authentication_required') from an endpoint that returns 401 for
      // other reasons — notably login with bad credentials, which must show
      // "Invalid credentials", not "Session expired".
      if (body['error'] == 'authentication_required') {
        onSessionExpired?.call();
        throw const SessionExpiredException();
      }
      final message = body['message'] ?? body['error'] ?? 'Invalid credentials';
      throw ApiException('$message', statusCode: 401);
    }
    if (status == 409) {
      throw DuplicateSdwanIdException(existingTrackerId: body['tracker_id']);
    }

    final message = body['message'] ?? body['error'] ?? 'Request failed';
    throw ApiException('$message', statusCode: status);
  }
}
