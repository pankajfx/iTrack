import 'package:flutter/material.dart';

import 'package:itrack_fe/models/tracker.dart';
import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/utils/status_maps.dart';
import 'package:itrack_fe/utils/time_utils.dart';
import 'package:itrack_fe/widgets/status_badge.dart';

/// Dashboard list card — shows the same pills as the web row:
/// SDWAN ID, customer, time-ago, progress %, status badge.
class TrackerCard extends StatelessWidget {
  final Tracker tracker;
  final VoidCallback onTap;

  const TrackerCard({super.key, required this.tracker, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final progress = progressForStatus(tracker.status);

    return Card(
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      tracker.sdwanId,
                      style: AppTheme.heading.copyWith(fontSize: 16),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  StatusBadge(statusInfoFor(tracker.status), compact: true),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.business, size: 14, color: Colors.grey),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      tracker.customer,
                      style: TextStyle(
                          color: Colors.grey.shade700, fontSize: 13),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.schedule, size: 14, color: Colors.grey),
                  const SizedBox(width: 3),
                  Text(
                    formatTimeAgo(tracker.createdAt),
                    style:
                        TextStyle(color: Colors.grey.shade600, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: progress / 100,
                        minHeight: 6,
                        backgroundColor: Colors.grey.shade200,
                        valueColor: const AlwaysStoppedAnimation(
                            AppTheme.primary),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '$progress%',
                    style: const TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppTheme.badgeText,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
