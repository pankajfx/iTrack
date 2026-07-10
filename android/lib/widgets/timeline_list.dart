import 'package:flutter/material.dart';

import 'package:itrack_fe/models/tracker.dart';
import 'package:itrack_fe/utils/status_maps.dart';
import 'package:itrack_fe/utils/time_utils.dart';

/// Reverse-chronological event timeline (mirrors renderTimeline in
/// fe_tracker_detail.html — newest first).
class TimelineList extends StatelessWidget {
  final List<TrackerEvent> events;

  const TimelineList({super.key, required this.events});

  @override
  Widget build(BuildContext context) {
    if (events.isEmpty) {
      return Text('No activity yet',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 13));
    }
    final ordered = events.reversed.toList();
    return Column(
      children: List.generate(ordered.length, (i) {
        final event = ordered[i];
        final isLast = i == ordered.length - 1;
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Column(
                children: [
                  Container(
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(top: 4),
                    decoration: BoxDecoration(
                      color: i == 0 ? Colors.teal : Colors.grey.shade400,
                      shape: BoxShape.circle,
                    ),
                  ),
                  if (!isLast)
                    Expanded(
                      child: Container(
                          width: 2, color: Colors.grey.shade300),
                    ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        formatStage(event.stage),
                        style: const TextStyle(
                            fontWeight: FontWeight.w600, fontSize: 13),
                      ),
                      if ((event.remarks ?? '').isNotEmpty)
                        Text(event.remarks!,
                            style: TextStyle(
                                fontSize: 12, color: Colors.grey.shade600)),
                      Text(
                        formatIstShort(event.timestamp),
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      }),
    );
  }
}
