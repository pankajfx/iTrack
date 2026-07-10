import 'package:flutter/foundation.dart';

import 'package:itrack_fe/api/options_api.dart';
import 'package:itrack_fe/api/trackers_api.dart';
import 'package:itrack_fe/models/form_options.dart';
import 'package:itrack_fe/models/gps_point.dart';
import 'package:itrack_fe/models/tracker.dart';
import 'package:itrack_fe/services/image_service.dart';
import 'package:itrack_fe/services/location_service.dart';
import 'package:itrack_fe/utils/constants.dart';

/// One captured site photo awaiting submission (wizard Step 1).
class CapturedSitePhoto {
  final String type; // booster | router | other
  final Uint8List jpegBytes;
  final GpsPoint? gps;
  final DateTime capturedAt;

  const CapturedSitePhoto({
    required this.type,
    required this.jpegBytes,
    required this.gps,
    required this.capturedAt,
  });
}

/// Wizard state for creating a tracker — mirrors fe_new_installation.html:
/// Step 1 = 3 mandatory GPS-stamped site photos, Step 2 = details form with
/// optional per-field snaps. Submission is one JSON POST /api/trackers.
class NewInstallationState extends ChangeNotifier {
  final TrackersApi _trackersApi = TrackersApi();
  final OptionsApi _optionsApi = OptionsApi();
  final ImageService images = ImageService();
  final LocationService location = LocationService();

  // Step 1 — site photos keyed by slot type.
  final Map<String, CapturedSitePhoto> sitePhotos = {};
  bool get allSitePhotosTaken =>
      sitePhotoSlots.every((slot) => sitePhotos.containsKey(slot.type));

  // Step 2 — dropdown data + per-field snaps.
  FormOptions? options;
  String? optionsError;
  final Map<String, Uint8List> fieldSnaps = {};

  bool _busy = false;
  bool get busy => _busy;
  String? _busyLabel;
  String? get busyLabel => _busyLabel;

  Future<void> loadOptions() async {
    try {
      options = await _optionsApi.formOptions();
      optionsError = null;
    } catch (e) {
      optionsError = '$e';
    }
    notifyListeners();
  }

  /// Capture one site photo: camera → compress → GPS fix → reverse geocode.
  /// Returns an error message for the UI, or null on success/cancel.
  Future<String?> captureSitePhoto(String type) async {
    if (!await images.ensureCameraPermission()) {
      return 'Camera permission is required to take site photos';
    }
    final hasLocation = await location.ensureLocationPermission();

    _setBusy(true, 'Opening camera…');
    try {
      final bytes = await images.captureJpeg();
      if (bytes == null) return null; // user cancelled

      _setBusy(true, 'Getting GPS location…');
      final gps = hasLocation ? await location.currentPoint() : null;

      sitePhotos[type] = CapturedSitePhoto(
        type: type,
        jpegBytes: bytes,
        gps: gps,
        capturedAt: DateTime.now().toUtc(),
      );
      return null;
    } finally {
      _setBusy(false);
    }
  }

  void removeSitePhoto(String type) {
    sitePhotos.remove(type);
    notifyListeners();
  }

  /// Snap a photo for a form field (sim1_provider, sim1_number, …).
  Future<String?> captureFieldSnap(String fieldKey) async {
    if (!await images.ensureCameraPermission()) {
      return 'Camera permission is required';
    }
    _setBusy(true, 'Opening camera…');
    try {
      final bytes = await images.captureJpeg();
      if (bytes != null) fieldSnaps[fieldKey] = bytes;
      return null;
    } finally {
      _setBusy(false);
    }
  }

  void removeFieldSnap(String fieldKey) {
    fieldSnaps.remove(fieldKey);
    notifyListeners();
  }

  /// Debounced duplicate check backing the SDWAN ID field.
  Future<bool> sdwanIdExists(String sdwanId) =>
      _trackersApi.sdwanIdExists(sdwanId);

  /// Submit everything as one POST /api/trackers.
  /// Throws DuplicateSdwanIdException (409) or ApiException on failure.
  Future<Tracker> submit({
    required String sdwanId,
    required String customer,
    required String fePhone,
    required String sim1Provider,
    required String sim1Number,
    String? sim2Provider,
    String? sim2Number,
    required String routerType,
    required String routerMake,
    required String routerFirmwareVersion,
  }) async {
    _setBusy(true, 'Submitting installation…');
    try {
      final siteImages = sitePhotos.values
          .map((photo) => {
                'type': photo.type,
                'data': images.toDataUrl(photo.jpegBytes),
                'gps': photo.gps?.toJson() ??
                    {'lat': null, 'lng': null, 'address': ''},
                'captured_at': photo.capturedAt.toIso8601String(),
              })
          .toList();

      final imageMap = fieldSnaps
          .map((key, bytes) => MapEntry(key, images.toDataUrl(bytes)));

      return await _trackersApi.create(
        sdwanId: sdwanId,
        customer: customer,
        fePhone: fePhone,
        sim1Provider: sim1Provider,
        sim1Number: sim1Number,
        sim2Provider: sim2Provider,
        sim2Number: sim2Number,
        routerType: routerType,
        routerMake: routerMake,
        routerFirmwareVersion: routerFirmwareVersion,
        images: imageMap,
        siteImages: siteImages,
      );
    } finally {
      _setBusy(false);
    }
  }

  void _setBusy(bool value, [String? label]) {
    _busy = value;
    _busyLabel = value ? label : null;
    notifyListeners();
  }
}
