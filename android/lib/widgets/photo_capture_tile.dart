import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:itrack_fe/models/gps_point.dart';
import 'package:itrack_fe/theme/app_theme.dart';

/// Wizard Step-1 tile: shows a capture prompt, or the taken photo with a
/// GPS chip + retake button. Mirrors the web wizard's three mandatory slots.
class PhotoCaptureTile extends StatelessWidget {
  final String title;
  final Uint8List? bytes;
  final GpsPoint? gps;
  final VoidCallback onCapture;
  final VoidCallback onRetake;

  const PhotoCaptureTile({
    super.key,
    required this.title,
    required this.bytes,
    required this.gps,
    required this.onCapture,
    required this.onRetake,
  });

  @override
  Widget build(BuildContext context) {
    final taken = bytes != null;
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(
                  taken ? Icons.check_circle : Icons.photo_camera_outlined,
                  color: taken ? Colors.green : AppTheme.primary,
                  size: 20,
                ),
                const SizedBox(width: 8),
                Text(title, style: AppTheme.heading.copyWith(fontSize: 15)),
                const Spacer(),
                Text('Required',
                    style:
                        TextStyle(fontSize: 11, color: Colors.grey.shade500)),
              ],
            ),
            const SizedBox(height: 10),
            if (!taken)
              InkWell(
                onTap: onCapture,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  height: 130,
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: AppTheme.badgeBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.3)),
                  ),
                  child: const Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.add_a_photo,
                          color: AppTheme.primary, size: 32),
                      SizedBox(height: 6),
                      Text('Tap to capture',
                          style: TextStyle(color: AppTheme.primary)),
                    ],
                  ),
                ),
              )
            else ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: Image.memory(bytes!,
                    height: 160, width: double.infinity, fit: BoxFit.cover),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    gps != null ? Icons.location_on : Icons.location_off,
                    size: 14,
                    color: gps != null ? Colors.green : Colors.orange,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      gps == null
                          ? 'No GPS — will submit without location'
                          : (gps!.address.isNotEmpty
                              ? gps!.address
                              : gps!.coordsLabel),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: Colors.grey.shade600),
                    ),
                  ),
                  TextButton.icon(
                    onPressed: onRetake,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Retake'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
