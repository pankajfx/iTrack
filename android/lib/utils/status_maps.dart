import 'package:flutter/material.dart';

/// Status → display info, ported from fe_dashboard.html getStatusInfo().
/// Labels are verbatim; Tailwind badge classes are mapped to equivalent
/// Material colors (bg-*-100 → shade100 background, text-*-800 → shade800 text).
///
/// Three statuses the web map is missing (they render "Unknown" there —
/// an upstream bug not worth replicating) get sensible entries here:
/// fe_requested_ztp, hso_submitted, hso_rejected.
class StatusInfo {
  final String label;
  final Color background;
  final Color foreground;
  final IconData icon;
  const StatusInfo(this.label, this.background, this.foreground, this.icon);
}

// Tailwind palette equivalents.
final Color _yellowBg = Colors.yellow.shade100;
final Color _yellowFg = Colors.yellow.shade900;
final Color _blueBg = Colors.blue.shade100;
final Color _blueFg = Colors.blue.shade800;
final Color _greenBg = Colors.green.shade100;
final Color _greenFg = Colors.green.shade800;
final Color _purpleBg = Colors.purple.shade100;
final Color _purpleFg = Colors.purple.shade800;
final Color _redBg = Colors.red.shade100;
final Color _redFg = Colors.red.shade800;
final Color _orangeBg = Colors.orange.shade100;
final Color _orangeFg = Colors.orange.shade900;
final Color _greyBg = Colors.grey.shade200;
final Color _greyFg = Colors.grey.shade800;

final Map<String, StatusInfo> _statusMap = {
  // Initial stages
  'waiting_noc_assignment':
      StatusInfo('Pending', _yellowBg, _yellowFg, Icons.schedule),
  'noc_working': StatusInfo('Active', _blueBg, _blueFg, Icons.autorenew),

  // SIM activation stages
  'sim_activation_pending':
      StatusInfo('SIM Pending', _yellowBg, _yellowFg, Icons.sim_card),
  'sim_activation_in_progress':
      StatusInfo('SIM Activation', _blueBg, _blueFg, Icons.sim_card),
  'sim_activated': StatusInfo('SIM Active', _greenBg, _greenFg, Icons.sim_card),

  // ZTP Configuration Phase
  'ztp_config_pending':
      StatusInfo('ZTP Config Pending', _purpleBg, _purpleFg, Icons.settings),
  'ztp_config_unverified':
      StatusInfo('ZTP Config Unverified', _redBg, _redFg, Icons.error_outline),
  'ztp_config_verified':
      StatusInfo('ZTP Config Verified', _greenBg, _greenFg, Icons.verified),

  // ZTP Pull Phase
  'ztp_pull_pending':
      StatusInfo('ZTP Pull Pending', _purpleBg, _purpleFg, Icons.download),
  'ztp_pull_done_by_fe':
      StatusInfo('ZTP Pull by FE', _blueBg, _blueFg, Icons.download_done),
  'ztp_pull_unverified':
      StatusInfo('ZTP Pull Unverified', _redBg, _redFg, Icons.error_outline),
  'ztp_pull_requested_from_noc': StatusInfo(
      'ZTP Pull Requested', _orangeBg, _orangeFg, Icons.support_agent),
  'ztp_pull_verified':
      StatusInfo('ZTP Pull Verified', _greenBg, _greenFg, Icons.verified),
  'ztp_pull_done_by_noc':
      StatusInfo('ZTP Pull by NOC', _greenBg, _greenFg, Icons.verified),

  // Legacy ZTP stages
  'ztp_in_progress':
      StatusInfo('ZTP In Progress', _purpleBg, _purpleFg, Icons.settings),
  'ztp_completed':
      StatusInfo('ZTP Complete', _greenBg, _greenFg, Icons.check_circle),

  // HSO stages
  'hso_pending':
      StatusInfo('HSO Pending', _orangeBg, _orangeFg, Icons.pending),
  'hso_in_progress':
      StatusInfo('HSO In Progress', _orangeBg, _orangeFg, Icons.assignment),

  // Final stages
  'ready_for_coordination':
      StatusInfo('Ready', _greenBg, _greenFg, Icons.call),
  'installation_complete': StatusInfo('Done', _greyBg, _greyFg, Icons.check),
  'completed': StatusInfo('Done', _greyBg, _greyFg, Icons.check),

  // Added (missing from the web map — rendered "Unknown" there):
  'fe_requested_ztp': StatusInfo(
      'ZTP Requested from NS', _orangeBg, _orangeFg, Icons.support_agent),
  'hso_submitted':
      StatusInfo('HSO Submitted', _blueBg, _blueFg, Icons.assignment_turned_in),
  'hso_rejected':
      StatusInfo('HSO Rejected', _redBg, _redFg, Icons.error_outline),
};

StatusInfo statusInfoFor(String? status) {
  return _statusMap[status] ??
      StatusInfo('Unknown', _greyBg, _greyFg, Icons.help_outline);
}

/// Progress % per status — ported verbatim from fe_dashboard.html
/// calculateProgress(), plus the statuses that map lacks (web shows 0%).
const Map<String, int> _progressMap = {
  'waiting_noc_assignment': 10,
  'sim_activation_pending': 20,
  'sim_activation_in_progress': 30,
  'sim_activated': 40,
  // ZTP Configuration Phase
  'ztp_config_pending': 50,
  'ztp_config_unverified': 45,
  'ztp_config_verified': 55,
  // ZTP Pull Phase
  'ztp_pull_pending': 60,
  'ztp_pull_done_by_fe': 65,
  'ztp_pull_unverified': 62,
  'ztp_pull_requested_from_noc': 65,
  'ztp_pull_verified': 70,
  'ztp_pull_done_by_noc': 70,
  // Legacy ZTP statuses
  'ztp_in_progress': 60,
  'ztp_completed': 70,
  // HSO and Completion
  'hso_in_progress': 85,
  'completed': 100,
  'installation_complete': 100,
  // Added (absent from the web map):
  'noc_working': 15,
  'fe_requested_ztp': 65,
  'ready_for_coordination': 80,
  'hso_submitted': 90,
  'hso_rejected': 85,
};

int progressForStatus(String? status) => _progressMap[status] ?? 0;

// ─── Tracker detail page maps (fe_tracker_detail.html) ──────────────────────
// The detail page uses its own labels, ported verbatim from its getStatusInfo.

final Color _amberBg = Colors.amber.shade100;
final Color _amberFg = Colors.amber.shade900;
final Color _tealBg = Colors.teal.shade100;
final Color _tealFg = Colors.teal.shade800;
final Color _indigoBg = Colors.indigo.shade100;
final Color _indigoFg = Colors.indigo.shade800;

final Map<String, StatusInfo> _detailStatusMap = {
  'waiting_noc_assignment':
      StatusInfo('Waiting for NOC', _yellowBg, _yellowFg, Icons.schedule),
  'noc_working': StatusInfo('NOC Working', _blueBg, _blueFg, Icons.autorenew),
  'ztp_config_pending':
      StatusInfo('ZTP Config Pending', _blueBg, _blueFg, Icons.settings),
  'ztp_config_unverified': StatusInfo(
      'ZTP Config Unverified', _orangeBg, _orangeFg, Icons.warning_amber),
  'ztp_pull_pending':
      StatusInfo('ZTP Pull Pending', _blueBg, _blueFg, Icons.download),
  'ztp_pull_done_by_fe': StatusInfo('ZTP Done - Awaiting Verification',
      _purpleBg, _purpleFg, Icons.check_circle),
  'ztp_pull_unverified': StatusInfo(
      'ZTP Pull Unverified', _orangeBg, _orangeFg, Icons.warning_amber),
  'ztp_pull_requested_from_noc':
      StatusInfo('NOC Doing ZTP', _amberBg, _amberFg, Icons.sos),
  'ztp_pull_verified':
      StatusInfo('ZTP Complete', _greenBg, _greenFg, Icons.verified),
  'ztp_pull_done_by_noc':
      StatusInfo('ZTP Complete', _greenBg, _greenFg, Icons.verified),
  'fe_requested_ztp':
      StatusInfo('NOC Doing ZTP', _amberBg, _amberFg, Icons.sos),
  'ready_for_coordination':
      StatusInfo('Ready — Chat Open', _tealBg, _tealFg, Icons.call),
  'hso_submitted':
      StatusInfo('HSO Submitted', _indigoBg, _indigoFg, Icons.send),
  'hso_rejected':
      StatusInfo('HSO Rejected — Resubmit', _redBg, _redFg, Icons.cancel),
  'installation_complete':
      StatusInfo('Complete', _greenBg, _greenFg, Icons.verified_user),
};

StatusInfo detailStatusInfoFor(String? status) {
  return _detailStatusMap[status] ??
      StatusInfo(status ?? 'Unknown', _greyBg, _greyFg, Icons.help_outline);
}

/// SIM status map — ported verbatim from fe_tracker_detail.html getSimStatusInfo.
final Map<String, StatusInfo> _simStatusMap = {
  'pending': StatusInfo('Pending', _greyBg, _greyFg, Icons.schedule),
  'activation_in_process':
      StatusInfo('Activating…', _blueBg, _blueFg, Icons.autorenew),
  'activation_complete_manual':
      StatusInfo('Activated', _greenBg, _greenFg, Icons.check),
  'activation_complete_preactivated':
      StatusInfo('Pre-activated', _greenBg, _greenFg, Icons.done_all),
  'activation_failed': StatusInfo('Failed', _redBg, _redFg, Icons.close),
};

StatusInfo simStatusInfoFor(String? status) {
  return _simStatusMap[status] ??
      StatusInfo(status ?? 'Unknown', _greyBg, _greyFg, Icons.help_outline);
}

/// Events-based progress for the DETAIL page — ported verbatim from
/// fe_tracker_detail.html calculateProgress() (8 milestone stages).
int detailProgressFromEvents(String? status, List<String> eventStages) {
  if (status == 'installation_complete') return 100;
  var done = 0;
  if (eventStages.contains('tracker_created')) done++;
  if (eventStages.contains('noc_assigned')) done++;
  if (eventStages.any((s) =>
      s.contains('sim1_activation_complete') ||
      s.contains('sim2_activation_complete'))) {
    done++;
  }
  if (eventStages.contains('ztp_config_verified')) done++;
  if (eventStages.any((s) => const [
        'ztp_fe_completion_verified',
        'ztp_completed_by_noc',
        'ztp_completed_by_fe',
        'ztp_pull_verification',
        'ztp_pull_action',
      ].contains(s))) {
    done++;
  }
  if (eventStages.contains('ready_for_coordination')) done++;
  if (eventStages.contains('hso_submitted')) done++;
  if (eventStages.contains('hso_approved')) done++;
  return ((done / 8) * 100).round();
}

/// "tracker_created" → "Tracker Created" (fe_tracker_detail.html formatStage).
String formatStage(String stage) => stage
    .split('_')
    .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
    .join(' ');
