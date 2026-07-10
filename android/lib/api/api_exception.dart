/// Errors surfaced to the UI layer. Every API call throws one of these
/// (never a raw DioException) so screens can show a friendly message.
class ApiException implements Exception {
  final String message;
  final int? statusCode;

  const ApiException(this.message, {this.statusCode});

  @override
  String toString() => message;
}

/// The Flask server redirected an API call to /login — the session cookie is
/// missing/expired (the web app returns 302 + HTML instead of 401).
/// AuthState listens for this globally and navigates back to the Login screen.
class SessionExpiredException extends ApiException {
  const SessionExpiredException()
      : super('Session expired — please log in again', statusCode: 401);
}

/// POST /api/trackers returned 409: the SDWAN ID already exists.
/// Carries the existing tracker's _id so the UI can offer to open it.
class DuplicateSdwanIdException extends ApiException {
  final String? existingTrackerId;

  const DuplicateSdwanIdException({this.existingTrackerId})
      : super('SDWAN ID already exists', statusCode: 409);
}
