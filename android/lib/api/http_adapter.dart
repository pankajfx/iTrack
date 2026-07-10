// Platform-specific HTTP wiring, selected at compile time.
//
// Native (Android): a persistent cookie jar stores the Flask session cookie
// on disk, and the HttpClient trusts the configured host's self-signed cert.
// Web (Chrome, for UI preview): the browser manages cookies via credentialed
// requests; there is no cookie jar and no cert override.
//
// Using conditional exports keeps `dart:io` and `cookie_jar` out of the web
// compile graph — otherwise the app could not build for Chrome at all.
export 'http_adapter_io.dart' if (dart.library.html) 'http_adapter_web.dart';
