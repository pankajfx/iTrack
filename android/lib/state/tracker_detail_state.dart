import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:itrack_fe/api/trackers_api.dart';
import 'package:itrack_fe/models/tracker.dart';
import 'package:itrack_fe/services/socket_service.dart';
import 'package:itrack_fe/utils/constants.dart';

/// State for one tracker's detail screen: loads {tracker, can_interact},
/// exposes the FE action gates (ported from fe_tracker_detail.html), and
/// stays fresh via the tracker_{id} socket room + 30 s polling.
class TrackerDetailState extends ChangeNotifier {
  final TrackersApi _api = TrackersApi();
  final String trackerId;

  Tracker? _tracker;
  bool _canInteract = false;
  bool _loading = true;
  bool _actionInProgress = false;
  String? _error;

  Timer? _pollTimer;
  final List<void Function()> _socketUnsubs = [];

  TrackerDetailState(this.trackerId);

  Tracker? get tracker => _tracker;
  bool get canInteract => _canInteract;
  bool get loading => _loading;
  bool get actionInProgress => _actionInProgress;
  String? get error => _error;

  // ── Action gates — mirror fe_tracker_detail.html exactly ──

  /// ZTP buttons: config verified, ZTP not completed, owner, ≥1 SIM active.
  bool get canActOnZtp {
    final t = _tracker;
    if (t == null || !_canInteract) return false;
    return t.ztp.configVerified && !t.ztp.isCompleted && t.anySimActivated;
  }

  /// "Start ZTP" only before it's been initiated; "Completed" only after.
  bool get canStartZtp => canActOnZtp && _tracker!.ztp.status == 'pending';
  bool get canCompleteZtp => canActOnZtp && _tracker!.ztp.status == 'initiated';
  bool get canRequestNocZtp =>
      canActOnZtp && !_tracker!.ztp.feRequestedNs;

  /// HSO submit gate — mirrors HSO_SUBMITTABLE_STATUSES.
  bool get canSubmitHso {
    final t = _tracker;
    if (t == null || !_canInteract) return false;
    return hsoSubmittableStatuses.contains(t.status);
  }

  bool get isHsoResubmit => _tracker?.status == TrackerStatus.hsoRejected;

  /// Site-photo resubmit only after NOC rejection.
  bool get canResubmitSitePhotos =>
      _canInteract && (_tracker?.siteVerification.isRejected ?? false);

  // ── Lifecycle ──

  void start() {
    refresh();
    SocketService.instance.joinTracker(trackerId);
    _socketUnsubs.add(SocketService.instance.on('tracker_update', (data) {
      if (data is Map && '${data['tracker_id']}' == trackerId) {
        refresh(silent: true);
      }
    }));
    _pollTimer = Timer.periodic(pollInterval, (_) => refresh(silent: true));
  }

  void stop() {
    _pollTimer?.cancel();
    for (final unsub in _socketUnsubs) {
      unsub();
    }
    _socketUnsubs.clear();
    SocketService.instance.leaveTracker(trackerId);
  }

  Future<void> refresh({bool silent = false}) async {
    if (!silent) {
      _loading = true;
      _error = null;
      notifyListeners();
    }
    try {
      final detail = await _api.detail(trackerId);
      _tracker = detail.tracker;
      _canInteract = detail.canInteract;
      _error = null;
    } catch (e) {
      if (!silent) _error = '$e';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  // ── FE actions (server re-validates everything) ──

  Future<void> ztpFeStart() => _runAction(() => _api.ztpFeStart(trackerId));
  Future<void> ztpFeComplete() =>
      _runAction(() => _api.ztpFeComplete(trackerId));
  Future<void> ztpRequestNoc() =>
      _runAction(() => _api.ztpRequestNoc(trackerId));
  Future<void> hsoSubmit() => _runAction(() => _api.hsoSubmit(trackerId));

  Future<void> resubmitSitePhotos(List<Map<String, dynamic>> siteImages) =>
      _runAction(() => _api.resubmitSitePhotos(trackerId, siteImages));

  Future<void> _runAction(Future<void> Function() action) async {
    _actionInProgress = true;
    notifyListeners();
    try {
      await action();
      await refresh(silent: true);
    } finally {
      _actionInProgress = false;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}
