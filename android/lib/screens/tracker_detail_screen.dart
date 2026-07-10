import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:itrack_fe/models/tracker.dart';
import 'package:itrack_fe/state/tracker_detail_state.dart';
import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/utils/status_maps.dart';
import 'package:itrack_fe/utils/time_utils.dart';
import 'package:itrack_fe/screens/chat_screen.dart';
import 'package:itrack_fe/screens/image_viewer_screen.dart';
import 'package:itrack_fe/screens/site_photo_capture_screen.dart';
import 'package:itrack_fe/widgets/confirm_dialog.dart';
import 'package:itrack_fe/widgets/empty_state.dart';
import 'package:itrack_fe/widgets/loading_overlay.dart';
import 'package:itrack_fe/widgets/status_badge.dart';
import 'package:itrack_fe/widgets/timeline_list.dart';

/// FE tracker detail — status, SIM, ZTP, HSO cards + actions + timeline + chat.
/// Action buttons are gated exactly as fe_tracker_detail.html; the server
/// re-validates every gate, so a mis-gated button still fails safe.
class TrackerDetailScreen extends StatefulWidget {
  final String trackerId;
  const TrackerDetailScreen({super.key, required this.trackerId});

  @override
  State<TrackerDetailScreen> createState() => _TrackerDetailScreenState();
}

class _TrackerDetailScreenState extends State<TrackerDetailScreen> {
  late final TrackerDetailState _state;

  @override
  void initState() {
    super.initState();
    _state = TrackerDetailState(widget.trackerId)..start();
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _state,
      child: Consumer<TrackerDetailState>(
        builder: (context, state, _) {
          final tracker = state.tracker;
          return LoadingOverlay(
            visible: state.actionInProgress,
            label: 'Working…',
            child: Scaffold(
              appBar: AppBar(
                title: Text(tracker?.sdwanId ?? 'Tracker'),
                actions: [
                  IconButton(
                    icon: const Icon(Icons.refresh),
                    onPressed: () => state.refresh(),
                  ),
                ],
              ),
              body: _buildBody(state, tracker),
              floatingActionButton: tracker == null
                  ? null
                  : FloatingActionButton.extended(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) =>
                                ChatScreen(trackerId: widget.trackerId)),
                      ),
                      icon: const Icon(Icons.chat),
                      label: const Text('Chat'),
                    ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildBody(TrackerDetailState state, Tracker? tracker) {
    if (state.loading && tracker == null) {
      return const Center(child: CircularProgressIndicator());
    }
    if (tracker == null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load tracker',
        subtitle: state.error,
        onRetry: () => state.refresh(),
      );
    }
    return RefreshIndicator(
      onRefresh: () => state.refresh(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 90),
        children: [
          if (tracker.siteVerification.isRejected) _rejectionBanner(state, tracker),
          _statusCard(tracker),
          _infoCard(tracker),
          _nocCard(tracker),
          _simCard('SIM 1', tracker.sim1),
          if (!tracker.sim2.notRequired) _simCard('SIM 2', tracker.sim2),
          _ztpCard(state, tracker),
          _hsoCard(state, tracker),
          _timelineCard(tracker),
          if (!state.canInteract) _viewOnlyNote(),
        ],
      ),
    );
  }

  // ── Cards ──

  Widget _statusCard(Tracker tracker) {
    final progress =
        detailProgressFromEvents(tracker.status, tracker.events.map((e) => e.stage).toList());
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                    child: Text('Installation Status', style: AppTheme.heading)),
                StatusBadge(detailStatusInfoFor(tracker.status)),
              ],
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: progress / 100,
                minHeight: 8,
                backgroundColor: Colors.grey.shade200,
                valueColor: const AlwaysStoppedAnimation(AppTheme.primary),
              ),
            ),
            const SizedBox(height: 6),
            Text('$progress% complete · started ${formatIst(tracker.createdAt)}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
          ],
        ),
      ),
    );
  }

  Widget _infoCard(Tracker tracker) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Installation Info', style: AppTheme.heading),
            const SizedBox(height: 10),
            _infoRow(Icons.tag, 'SDWAN ID', tracker.sdwanId),
            _infoRow(Icons.business, 'Customer', tracker.customer),
            if ((tracker.siteName ?? '').isNotEmpty)
              _infoRow(Icons.place, 'Site', tracker.siteName!),
          ],
        ),
      ),
    );
  }

  Widget _nocCard(Tracker tracker) {
    final assigned = tracker.nocAssignee != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('NOC Support', style: AppTheme.heading),
            const SizedBox(height: 4),
            Text(
              assigned ? 'NOC Support Assigned' : 'Waiting for NOC assignment',
              style: TextStyle(
                  color: assigned ? Colors.green.shade700 : Colors.orange,
                  fontSize: 13),
            ),
            for (final h in tracker.nocHistory)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '• ${h.assigneeName ?? 'NOC Support'} — ${formatIstShort(h.assignedAt)}',
                  style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _simCard(String title, SimInfo sim) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sim_card, size: 18, color: AppTheme.primary),
                const SizedBox(width: 6),
                Expanded(
                    child: Text(title, style: AppTheme.heading.copyWith(fontSize: 15))),
                StatusBadge(simStatusInfoFor(sim.status), compact: true),
              ],
            ),
            const SizedBox(height: 8),
            _infoRow(Icons.business, 'Provider', sim.provider ?? '—'),
            _infoRow(Icons.numbers, 'Number', sim.number ?? '—'),
            if (sim.images.isNotEmpty)
              Wrap(
                spacing: 8,
                children: sim.images
                    .map((img) => ActionChip(
                          avatar: const Icon(Icons.image, size: 16),
                          label: Text(img.field),
                          onPressed: () => ImageViewerScreen.open(
                              context, img.data,
                              title: '$title ${img.field}'),
                        ))
                    .toList(),
              ),
            if ((sim.failureReason ?? '').isNotEmpty)
              Text('Failure: ${sim.failureReason}',
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
          ],
        ),
      ),
    );
  }

  Widget _ztpCard(TrackerDetailState state, Tracker tracker) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('ZTP', style: AppTheme.heading),
            const SizedBox(height: 6),
            _infoRow(Icons.settings, 'Config',
                tracker.ztp.configVerified ? 'Verified' : tracker.ztp.configStatus),
            _infoRow(Icons.download, 'ZTP Status', tracker.ztp.status),
            if (tracker.router.firmwareVersion != null)
              _infoRow(Icons.memory, 'Firmware', tracker.router.firmwareVersion!),
            if (tracker.router.images.isNotEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => ImageViewerScreen.open(
                      context, tracker.router.images.first.data,
                      title: 'Firmware'),
                  icon: const Icon(Icons.image, size: 16),
                  label: const Text('View firmware image'),
                ),
              ),
            if (state.canActOnZtp) ...[
              const Divider(),
              if (state.canStartZtp)
                _actionButton('Start ZTP on Device', Icons.play_arrow, () async {
                  if (await _confirm('Start ZTP', 'Start ZTP on the device now?')) {
                    await state.ztpFeStart();
                  }
                }),
              if (state.canCompleteZtp)
                _actionButton('ZTP Completed — Notify NS', Icons.check, () async {
                  if (await _confirm('ZTP Complete',
                      'Mark ZTP complete and notify NOC to verify?')) {
                    await state.ztpFeComplete();
                  }
                }),
              if (state.canRequestNocZtp)
                _actionButton(
                    'Cannot do ZTP — Request NS', Icons.support_agent, () async {
                  if (await _confirm('Request NOC',
                      'Ask NOC Support to perform ZTP? This opens chat.')) {
                    await state.ztpRequestNoc();
                  }
                }, outlined: true),
            ],
          ],
        ),
      ),
    );
  }

  Widget _hsoCard(TrackerDetailState state, Tracker tracker) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('HSO Documentation', style: AppTheme.heading),
            const SizedBox(height: 6),
            _infoRow(Icons.assignment, 'HSO Status', tracker.hso.status),
            if ((tracker.hso.rejectionReason ?? '').isNotEmpty)
              Container(
                margin: const EdgeInsets.only(top: 6),
                padding: const EdgeInsets.all(8),
                color: Colors.red.shade50,
                child: Text('Rejected: ${tracker.hso.rejectionReason}',
                    style: const TextStyle(fontSize: 12, color: Colors.red)),
              ),
            if (state.canSubmitHso) ...[
              const SizedBox(height: 8),
              _actionButton(
                state.isHsoResubmit ? 'Re-submit HSO' : 'Submit HSO',
                Icons.send,
                () async {
                  final msg = state.isHsoResubmit
                      ? 'Re-submit HSO after addressing the rejection reason?'
                      : 'Submit HSO to notify NOC that sign-off is complete?';
                  if (await _confirm('Submit HSO', msg)) {
                    await state.hsoSubmit();
                  }
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _timelineCard(Tracker tracker) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Activity Timeline', style: AppTheme.heading),
            const SizedBox(height: 10),
            TimelineList(events: tracker.events),
          ],
        ),
      ),
    );
  }

  Widget _rejectionBanner(TrackerDetailState state, Tracker tracker) {
    return Card(
      color: Colors.red.shade50,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning, color: Colors.red),
                const SizedBox(width: 8),
                Expanded(
                  child: Text('Site photos rejected',
                      style: AppTheme.heading.copyWith(color: Colors.red)),
                ),
              ],
            ),
            if ((tracker.siteVerification.rejectionReason ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(tracker.siteVerification.rejectionReason!,
                    style: const TextStyle(fontSize: 13)),
              ),
            if (state.canResubmitSitePhotos) ...[
              const SizedBox(height: 10),
              _actionButton('Retake Site Photos & Resubmit', Icons.camera_alt,
                  () => _resubmitPhotos(state)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _viewOnlyNote() => Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'You are viewing this installation in read-only mode.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey.shade500, fontSize: 12),
        ),
      );

  // ── Helpers ──

  Widget _infoRow(IconData icon, String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 15, color: Colors.grey.shade500),
            const SizedBox(width: 8),
            Text('$label: ',
                style:
                    const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
            Expanded(
                child: Text(value, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );

  Widget _actionButton(String label, IconData icon, VoidCallback onTap,
      {bool outlined = false}) {
    final child = Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [Icon(icon, size: 18), const SizedBox(width: 6), Text(label)],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        width: double.infinity,
        child: outlined
            ? OutlinedButton(onPressed: onTap, child: child)
            : FilledButton(onPressed: onTap, child: child),
      ),
    );
  }

  Future<bool> _confirm(String title, String message) =>
      showConfirmDialog(context, title: title, message: message);

  Future<void> _resubmitPhotos(TrackerDetailState state) async {
    final photos = await Navigator.push<List<Map<String, dynamic>>>(
      context,
      MaterialPageRoute(
        builder: (_) => const SitePhotoCaptureScreen(
            title: 'Resubmit Site Photos'),
      ),
    );
    if (photos != null && photos.length >= 3) {
      await state.resubmitSitePhotos(photos);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Site photos resubmitted ✓')));
      }
    }
  }
}
