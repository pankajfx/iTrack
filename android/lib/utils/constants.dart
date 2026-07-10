/// Shared constants mirroring the Flask backend (app.py) and web templates.
/// Status strings, bucket rules, and image field keys MUST stay in sync with
/// the server — they are the contract, not arbitrary app values.
library;

/// Role string for Field Engineer (mirrors ROLE_FE in app.py).
const String roleFieldEngineer = 'FIELD_ENGINEER';

/// ── HARDWIRED SERVER URL ─────────────────────────────────────────────────
/// Default iTrack (Flask) server the app talks to out of the box.
/// SET THIS BEFORE BUILDING THE APK for your deployment, e.g.:
///   'http://192.168.0.110:5001'   — dev laptop on office Wi-Fi
///   'https://itrack.company.com'  — production reverse proxy
/// Behavior:
///  - Fresh install: this URL is used automatically (Server Setup is skipped).
///  - Users can still override it later via Login → Server Settings; a user-
///    saved URL always wins over this default.
///  - Leave '' to force the manual Server Setup screen on first run.
const String defaultServerUrl = 'http://192.168.0.110:5001';

/// Tracker statuses (mirrors the status constants section of app.py).
class TrackerStatus {
  static const waitingNocAssignment = 'waiting_noc_assignment';
  static const installationComplete = 'installation_complete';
  static const completedLegacy = 'completed';
  static const feRequestedZtp = 'fe_requested_ztp';
  static const readyForCoordination = 'ready_for_coordination';
  static const hsoSubmitted = 'hso_submitted';
  static const hsoRejected = 'hso_rejected';
  static const ztpPullVerifiedLegacy = 'ztp_pull_verified';
  static const ztpPullDoneByNocLegacy = 'ztp_pull_done_by_noc';
}

/// Statuses where the FE may submit (or resubmit) HSO.
/// Mirrors HSO_SUBMITTABLE_STATUSES in app.py — server enforces this too.
const Set<String> hsoSubmittableStatuses = {
  TrackerStatus.readyForCoordination,
  TrackerStatus.feRequestedZtp,
  TrackerStatus.hsoRejected,
  TrackerStatus.ztpPullVerifiedLegacy,
  TrackerStatus.ztpPullDoneByNocLegacy,
};

/// SIM statuses that count as "activated" for the ZTP action gate
/// (mirrors the check in fe_tracker_detail.html renderZtpSection).
const Set<String> simActivatedStatuses = {
  'activation_complete_manual',
  'activation_complete_preactivated',
};

/// Dashboard bucket rules — ported verbatim from fe_dashboard.html
/// displayInstallations(): Unassigned = waiting_noc_assignment,
/// Completed = installation_complete | completed, Ongoing = everything else.
enum TrackerBucket { unassigned, ongoing, completed }

TrackerBucket bucketForStatus(String status) {
  if (status == TrackerStatus.waitingNocAssignment) {
    return TrackerBucket.unassigned;
  }
  if (status == TrackerStatus.installationComplete ||
      status == TrackerStatus.completedLegacy) {
    return TrackerBucket.completed;
  }
  return TrackerBucket.ongoing;
}

/// Site verification photo slots — order and types mirror the web wizard
/// (fe_new_installation.html sitePhotoTypes).
class SitePhotoSlot {
  final String type;
  final String title;
  const SitePhotoSlot(this.type, this.title);
}

const List<SitePhotoSlot> sitePhotoSlots = [
  SitePhotoSlot('booster', 'Booster / Antenna'),
  SitePhotoSlot('router', 'SDWAN Router'),
  SitePhotoSlot('other', 'Site Photo'),
];

/// Form field keys that support a camera snap on the create form.
/// These exact keys are what POST /api/trackers reads from `images{}`.
const List<String> snapFieldKeys = [
  'sim1_provider',
  'sim1_number',
  'sim2_provider',
  'sim2_number',
  'router_firmware_version',
];

/// Image processing targets — mirrors the server's Pillow re-encode
/// (chat upload: max side 1024, JPEG quality 85).
const int imageMaxSide = 1024;
const int imageJpegQuality = 85;

/// Dashboard polling interval — mirrors the web pages' 30 s setInterval.
const Duration pollInterval = Duration(seconds: 30);

/// Nominatim reverse-geocode endpoint (same service the web wizard uses).
/// Usage policy requires an identifying User-Agent and ≥1 request/second.
const String nominatimReverseUrl =
    'https://nominatim.openstreetmap.org/reverse';
const String nominatimUserAgent = 'iTrack-FE-App/1.0 (SDWAN tracker field app)';
