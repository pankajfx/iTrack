import 'package:flutter/material.dart';

import 'package:itrack_fe/utils/status_maps.dart';

/// Colored status pill, visually matching the web dashboard badges
/// (bg-*-100 background + text-*-800 text + Material icon).
class StatusBadge extends StatelessWidget {
  final StatusInfo info;
  final bool compact;

  const StatusBadge(this.info, {super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 8 : 10,
        vertical: compact ? 3 : 5,
      ),
      decoration: BoxDecoration(
        color: info.background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(info.icon, size: compact ? 13 : 15, color: info.foreground),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              info.label,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: info.foreground,
                fontSize: compact ? 11 : 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
