import 'package:itrack_fe/api/api_client.dart';
import 'package:itrack_fe/api/api_exception.dart';
import 'package:itrack_fe/models/tracker.dart';

/// Result of `GET /api/trackers/<id>`: the tracker plus whether the logged-in
/// user may act on it (FE owner) — mirrors the web's `{tracker, can_interact}`.
class TrackerDetail {
  final Tracker tracker;
  final bool canInteract;
  const TrackerDetail({required this.tracker, required this.canInteract});
}

/// Tracker read + FE action endpoints (all existing web API routes).
class TrackersApi {
  final ApiClient _client;
  TrackersApi([ApiClient? client]) : _client = client ?? ApiClient.instance;

  /// GET /api/trackers/all-fe — the FE dashboard list (own trackers,
  /// newest first; server scopes by role).
  Future<List<Tracker>> allFe() async {
    final body = await _client.requestJson((dio) => dio.get('/api/trackers/all-fe'));
    return (body['trackers'] as List? ?? [])
        .map((e) => Tracker.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// `GET /api/trackers/<id>` — full tracker + can_interact.
  /// The response carries all site photos inline (multi-MB), which can fail
  /// transiently on weak networks — retry once before surfacing the error.
  /// Safe to retry: GET is idempotent (unlike create).
  Future<TrackerDetail> detail(String trackerId) async {
    Map<String, dynamic> body;
    try {
      body = await _client
          .requestJson((dio) => dio.get('/api/trackers/$trackerId'));
    } on SessionExpiredException {
      rethrow;
    } on ApiException catch (e) {
      // Only network-level failures (no HTTP status) get the retry.
      if (e.statusCode != null) rethrow;
      await Future.delayed(const Duration(seconds: 1));
      body = await _client
          .requestJson((dio) => dio.get('/api/trackers/$trackerId'));
    }
    return TrackerDetail(
      tracker: Tracker.fromJson(body['tracker'] as Map<String, dynamic>),
      canInteract: body['can_interact'] == true,
    );
  }

  /// `GET /api/trackers/check/<sdwan_id>` — duplicate pre-check for the wizard.
  Future<bool> sdwanIdExists(String sdwanId) async {
    final body = await _client
        .requestJson((dio) => dio.get('/api/trackers/check/$sdwanId'));
    return body['exists'] == true;
  }

  /// POST /api/trackers — create a new tracker.
  /// [images] maps snap field keys (sim1_provider, sim1_number, …) to base64
  /// data-URLs; [siteImages] are the 3 GPS-stamped site photos.
  /// Throws DuplicateSdwanIdException on 409.
  Future<Tracker> create({
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
    required Map<String, String> images,
    required List<Map<String, dynamic>> siteImages,
  }) async {
    final body = await _client.requestJson((dio) => dio.post('/api/trackers', data: {
          'sdwan_id': sdwanId,
          'customer': customer,
          'fe_phone': fePhone,
          'sim1_provider': sim1Provider,
          'sim1_number': sim1Number,
          'sim2_provider': sim2Provider ?? '',
          'sim2_number': sim2Number ?? '',
          'router_type': routerType,
          'router_make': routerMake,
          'router_firmware_version': routerFirmwareVersion,
          'images': images,
          'site_images': siteImages,
        }));
    return Tracker.fromJson(body['tracker'] as Map<String, dynamic>);
  }

  /// `POST /api/trackers/<id>/site-verify/resubmit` — after NOC rejection,
  /// re-submit 3 fresh GPS-stamped photos.
  Future<void> resubmitSitePhotos(
      String trackerId, List<Map<String, dynamic>> siteImages) async {
    await _client.requestJson((dio) => dio.post(
          '/api/trackers/$trackerId/site-verify/resubmit',
          data: {'site_images': siteImages},
        ));
  }

  // ── ZTP actions (FE owner only; server re-validates every gate) ──

  /// POST .../ztp/fe-start — FE begins ZTP on the device.
  Future<void> ztpFeStart(String trackerId) async {
    await _client.requestJson(
        (dio) => dio.post('/api/trackers/$trackerId/ztp/fe-start'));
  }

  /// POST .../ztp/fe-complete — FE reports ZTP done (NS must verify).
  Future<void> ztpFeComplete(String trackerId) async {
    await _client.requestJson(
        (dio) => dio.post('/api/trackers/$trackerId/ztp/fe-complete'));
  }

  /// POST .../ztp/request-noc — FE can't do ZTP; hands it to NS
  /// (also unlocks chat).
  Future<void> ztpRequestNoc(String trackerId) async {
    await _client.requestJson(
        (dio) => dio.post('/api/trackers/$trackerId/ztp/request-noc'));
  }

  /// `POST /api/trackers/<id>/hso/submit` — bodyless state transition
  /// (no document upload; HSO paperwork happens outside the app).
  Future<void> hsoSubmit(String trackerId) async {
    await _client
        .requestJson((dio) => dio.post('/api/trackers/$trackerId/hso/submit'));
  }
}
