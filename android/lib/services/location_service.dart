import 'package:dio/dio.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:itrack_fe/models/gps_point.dart';
import 'package:itrack_fe/utils/constants.dart';

/// GPS fix + reverse geocode for site-verification photos.
///
/// Mirrors the web wizard: navigator.geolocation for coordinates, then
/// Nominatim (OpenStreetMap) for a human-readable address. Nominatim usage
/// policy: identifying User-Agent, max 1 request/second — we throttle and
/// treat geocode failure as non-blocking (photo keeps lat/lng, empty address).
class LocationService {
  // Plain Dio (no cookies/baseUrl) — this talks to OpenStreetMap, not our server.
  final Dio _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 8),
    receiveTimeout: const Duration(seconds: 8),
    headers: {'User-Agent': nominatimUserAgent},
  ));

  DateTime _lastGeocode = DateTime.fromMillisecondsSinceEpoch(0);

  Future<bool> ensureLocationPermission() async {
    if (!await Geolocator.isLocationServiceEnabled()) return false;
    final status = await Permission.location.request();
    return status.isGranted || status.isLimited;
  }

  /// Current GPS position with a reverse-geocoded address (best effort).
  /// Returns null only when no position fix is possible.
  Future<GpsPoint?> currentPoint() async {
    Position position;
    try {
      position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
    } catch (_) {
      // Fall back to the last known fix (may be null).
      final last = await Geolocator.getLastKnownPosition();
      if (last == null) return null;
      position = last;
    }

    final address =
        await _reverseGeocode(position.latitude, position.longitude);
    return GpsPoint(
      lat: position.latitude,
      lng: position.longitude,
      address: address,
    );
  }

  Future<String> _reverseGeocode(double lat, double lng) async {
    // Respect the 1 req/s policy across the 3 wizard photos.
    final sinceLast = DateTime.now().difference(_lastGeocode);
    if (sinceLast < const Duration(seconds: 1)) {
      await Future.delayed(const Duration(seconds: 1) - sinceLast);
    }
    _lastGeocode = DateTime.now();

    try {
      final response = await _dio.get(nominatimReverseUrl, queryParameters: {
        'format': 'json',
        'lat': '$lat',
        'lon': '$lng',
      });
      final data = response.data;
      if (data is Map && data['display_name'] is String) {
        return data['display_name'] as String;
      }
    } catch (_) {
      // Non-blocking: coordinates without an address are still valid.
    }
    return '';
  }
}
