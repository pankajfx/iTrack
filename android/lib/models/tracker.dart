import 'package:itrack_fe/models/gps_point.dart';
import 'package:itrack_fe/utils/time_utils.dart';

/// Tracker document as served by the Flask API (serialize_doc output).
/// Nested objects mirror the embedded documents created in POST /api/trackers.
/// All images are inline base64 data-URL strings.
Map<String, dynamic> _map(dynamic raw) =>
    raw is Map<String, dynamic> ? raw : <String, dynamic>{};

List<Map<String, dynamic>> _mapList(dynamic raw) => (raw as List? ?? [])
    .whereType<Map<String, dynamic>>()
    .toList();

/// Per-field snapshot: {field: 'provider'|'number', data: base64}.
class FieldImage {
  final String field;
  final String data;
  const FieldImage({required this.field, required this.data});

  factory FieldImage.fromJson(Map<String, dynamic> json) =>
      FieldImage(field: json['field'] ?? '', data: json['data'] ?? '');
}

class SimInfo {
  final String? provider;
  final String? number;
  final String status; // pending | activation_in_process | activation_complete_* | activation_failed | not_required
  final List<FieldImage> images;
  final String? failureReason;

  const SimInfo({
    this.provider,
    this.number,
    required this.status,
    this.images = const [],
    this.failureReason,
  });

  factory SimInfo.fromJson(Map<String, dynamic> json) => SimInfo(
        provider: json['provider'],
        number: json['number'],
        status: json['status'] ?? 'not_required',
        images: _mapList(json['images']).map(FieldImage.fromJson).toList(),
        failureReason: json['failure_reason'],
      );

  bool get notRequired => status == 'not_required';
}

class RouterInfo {
  final String? type;
  final String? make;
  final String? firmwareVersion;
  final List<FieldImage> images;

  const RouterInfo({this.type, this.make, this.firmwareVersion, this.images = const []});

  factory RouterInfo.fromJson(Map<String, dynamic> json) => RouterInfo(
        type: json['type'],
        make: json['make'],
        firmwareVersion: json['firmware_version'],
        images: _mapList(json['images']).map(FieldImage.fromJson).toList(),
      );
}

class ZtpInfo {
  final String configStatus; // pending | config_verified | config_failed
  final String status; // pending | initiated | fe_completed | completed | failed
  final String? performedBy; // 'FE' | 'NS'
  final bool feRequestedNs;
  final DateTime? initiatedAt;
  final DateTime? completedAt;
  final String? failureReason;
  final String? configFailureReason;

  const ZtpInfo({
    required this.configStatus,
    required this.status,
    this.performedBy,
    this.feRequestedNs = false,
    this.initiatedAt,
    this.completedAt,
    this.failureReason,
    this.configFailureReason,
  });

  factory ZtpInfo.fromJson(Map<String, dynamic> json) => ZtpInfo(
        configStatus: json['config_status'] ?? 'pending',
        status: json['status'] ?? 'pending',
        performedBy: json['performed_by'],
        feRequestedNs: json['fe_requested_ns'] == true,
        initiatedAt: parseServerTime(json['initiated_at']),
        completedAt: parseServerTime(json['completed_at']),
        failureReason: json['failure_reason'],
        configFailureReason: json['config_failure_reason'],
      );

  bool get configVerified => configStatus == 'config_verified';
  bool get isCompleted => status == 'completed';
}

class HsoInfo {
  final String status; // pending | submitted | approved | rejected
  final DateTime? submittedAt;
  final DateTime? approvedAt;
  final DateTime? rejectedAt;
  final String? rejectionReason;
  final int attemptCount;

  const HsoInfo({
    required this.status,
    this.submittedAt,
    this.approvedAt,
    this.rejectedAt,
    this.rejectionReason,
    this.attemptCount = 0,
  });

  factory HsoInfo.fromJson(Map<String, dynamic> json) => HsoInfo(
        status: json['status'] ?? 'pending',
        submittedAt: parseServerTime(json['submitted_at']),
        approvedAt: parseServerTime(json['approved_at']),
        rejectedAt: parseServerTime(json['rejected_at']),
        rejectionReason: json['rejection_reason'],
        attemptCount: (json['attempts'] as List? ?? []).length,
      );
}

/// Site-verification photo: {type, data, gps, captured_at}.
class SiteImage {
  final String type; // booster | router | other
  final String data; // base64 data-URL
  final GpsPoint? gps;
  final DateTime? capturedAt;

  const SiteImage({required this.type, required this.data, this.gps, this.capturedAt});

  factory SiteImage.fromJson(Map<String, dynamic> json) => SiteImage(
        type: json['type'] ?? 'other',
        data: json['data'] ?? '',
        gps: json['gps'] is Map<String, dynamic>
            ? GpsPoint.fromJson(json['gps'])
            : null,
        capturedAt: parseServerTime(json['captured_at']),
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'data': data,
        'gps': gps?.toJson(),
        'captured_at': capturedAt?.toIso8601String(),
      };
}

class SiteVerification {
  final String status; // pending | confirmed | rejected
  final List<SiteImage> images;
  final String? rejectionReason;
  final int rejectionCount;
  final DateTime? nocReviewedAt;

  const SiteVerification({
    required this.status,
    this.images = const [],
    this.rejectionReason,
    this.rejectionCount = 0,
    this.nocReviewedAt,
  });

  factory SiteVerification.fromJson(Map<String, dynamic> json) =>
      SiteVerification(
        status: json['status'] ?? 'pending',
        images: _mapList(json['images']).map(SiteImage.fromJson).toList(),
        rejectionReason: json['rejection_reason'],
        rejectionCount: (json['rejection_count'] as num?)?.toInt() ?? 0,
        nocReviewedAt: parseServerTime(json['noc_reviewed_at']),
      );

  bool get isRejected => status == 'rejected';
}

/// Workflow event appended by make_event() in app.py.
class TrackerEvent {
  final String stage;
  final DateTime? timestamp;
  final String? actor;
  final String? actorRole;
  final String? remarks;

  const TrackerEvent({
    required this.stage,
    this.timestamp,
    this.actor,
    this.actorRole,
    this.remarks,
  });

  factory TrackerEvent.fromJson(Map<String, dynamic> json) => TrackerEvent(
        stage: json['stage'] ?? '',
        timestamp: parseServerTime(json['timestamp']),
        actor: json['actor'],
        actorRole: json['actor_role'],
        remarks: json['remarks'],
      );
}

/// NOC assignment history entry ({assignee_id, assignee_name, assigned_at, released_at}).
class NocHistoryEntry {
  final String? assigneeName;
  final DateTime? assignedAt;
  final DateTime? releasedAt;
  final String? reassignmentReason;

  const NocHistoryEntry({
    this.assigneeName,
    this.assignedAt,
    this.releasedAt,
    this.reassignmentReason,
  });

  factory NocHistoryEntry.fromJson(Map<String, dynamic> json) =>
      NocHistoryEntry(
        assigneeName: json['assignee_name'],
        assignedAt: parseServerTime(json['assigned_at']),
        releasedAt: parseServerTime(json['released_at']),
        reassignmentReason: json['reassignment_reason'],
      );
}

class Tracker {
  final String id; // Mongo _id (used in URLs and Socket.IO rooms)
  final String trackerId; // SDWAN-YYYY-000001 (server-generated)
  final String sdwanId;
  final String customer;
  final String? siteName;
  final String? siteAddress;
  final String status;
  final String? nocAssignee;
  final List<NocHistoryEntry> nocHistory;
  final String feId;
  final String feName;
  final String feUsername;
  final String? fePhone;
  final SimInfo sim1;
  final SimInfo sim2;
  final RouterInfo router;
  final ZtpInfo ztp;
  final HsoInfo hso;
  final SiteVerification siteVerification;
  final List<TrackerEvent> events;
  final DateTime? createdAt;
  final DateTime? updatedAt;
  final DateTime? completedAt;

  const Tracker({
    required this.id,
    required this.trackerId,
    required this.sdwanId,
    required this.customer,
    this.siteName,
    this.siteAddress,
    required this.status,
    this.nocAssignee,
    this.nocHistory = const [],
    required this.feId,
    required this.feName,
    required this.feUsername,
    this.fePhone,
    required this.sim1,
    required this.sim2,
    required this.router,
    required this.ztp,
    required this.hso,
    required this.siteVerification,
    this.events = const [],
    this.createdAt,
    this.updatedAt,
    this.completedAt,
  });

  factory Tracker.fromJson(Map<String, dynamic> json) {
    final fe = _map(json['fe']);
    final sim = _map(json['sim']);
    return Tracker(
      id: json['_id'] ?? '',
      trackerId: json['tracker_id'] ?? '',
      sdwanId: json['sdwan_id'] ?? '',
      customer: json['customer'] ?? '',
      siteName: json['site_name'],
      siteAddress: json['site_address'],
      status: json['status'] ?? '',
      nocAssignee: json['noc_assignee'],
      nocHistory:
          _mapList(json['noc_history']).map(NocHistoryEntry.fromJson).toList(),
      feId: fe['id'] ?? '',
      feName: fe['name'] ?? '',
      feUsername: fe['username'] ?? '',
      fePhone: fe['phone'],
      sim1: SimInfo.fromJson(_map(sim['sim1'])),
      sim2: SimInfo.fromJson(_map(sim['sim2'])),
      router: RouterInfo.fromJson(_map(json['router'])),
      ztp: ZtpInfo.fromJson(_map(json['ztp'])),
      hso: HsoInfo.fromJson(_map(json['hso'])),
      siteVerification: SiteVerification.fromJson(_map(json['site_verification'])),
      events: _mapList(json['events']).map(TrackerEvent.fromJson).toList(),
      createdAt: parseServerTime(json['created_at']),
      updatedAt: parseServerTime(json['updated_at']),
      completedAt: parseServerTime(json['completed_at']),
    );
  }

  /// At least one SIM activated — gate for FE ZTP actions
  /// (mirrors fe_tracker_detail.html renderZtpSection).
  bool get anySimActivated {
    const activated = {
      'activation_complete_manual',
      'activation_complete_preactivated',
    };
    return activated.contains(sim1.status) || activated.contains(sim2.status);
  }

  /// Search haystack — fields the web dashboard search matches on.
  String get searchText => [
        sdwanId,
        customer,
        feName,
        feUsername,
        fePhone ?? '',
        sim1.number ?? '',
        sim2.number ?? '',
      ].join(' ').toLowerCase();
}
