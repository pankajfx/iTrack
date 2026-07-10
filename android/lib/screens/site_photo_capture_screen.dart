import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:itrack_fe/models/gps_point.dart';
import 'package:itrack_fe/services/image_service.dart';
import 'package:itrack_fe/services/location_service.dart';
import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/utils/constants.dart';
import 'package:itrack_fe/widgets/loading_overlay.dart';
import 'package:itrack_fe/widgets/photo_capture_tile.dart';

/// Standalone 3-photo capture flow used for site-verification RESUBMIT
/// (after NOC rejection). Pops with the site_images list the API expects,
/// or null if cancelled. The create wizard has its own inline copy of this.
class SitePhotoCaptureScreen extends StatefulWidget {
  final String title;
  const SitePhotoCaptureScreen({super.key, required this.title});

  @override
  State<SitePhotoCaptureScreen> createState() => _SitePhotoCaptureScreenState();
}

class _SitePhotoCaptureScreenState extends State<SitePhotoCaptureScreen> {
  final ImageService _images = ImageService();
  final LocationService _location = LocationService();

  final Map<String, _Captured> _photos = {};
  bool _busy = false;
  String? _busyLabel;

  bool get _allTaken =>
      sitePhotoSlots.every((slot) => _photos.containsKey(slot.type));

  Future<void> _capture(String type) async {
    if (!await _images.ensureCameraPermission()) {
      _toast('Camera permission is required');
      return;
    }
    final hasLocation = await _location.ensureLocationPermission();
    setState(() {
      _busy = true;
      _busyLabel = 'Opening camera…';
    });
    try {
      final bytes = await _images.captureJpeg();
      if (bytes == null) return;
      setState(() => _busyLabel = 'Getting GPS location…');
      final gps = hasLocation ? await _location.currentPoint() : null;
      setState(() {
        _photos[type] = _Captured(bytes, gps, DateTime.now().toUtc());
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _submit() {
    final siteImages = _photos.entries
        .map((e) => {
              'type': e.key,
              'data': _images.toDataUrl(e.value.bytes),
              'gps': e.value.gps?.toJson() ??
                  {'lat': null, 'lng': null, 'address': ''},
              'captured_at': e.value.capturedAt.toIso8601String(),
            })
        .toList();
    Navigator.pop(context, siteImages);
  }

  void _toast(String message) => ScaffoldMessenger.of(context)
      .showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    return LoadingOverlay(
      visible: _busy,
      label: _busyLabel,
      child: Scaffold(
        appBar: AppBar(title: Text(widget.title)),
        body: ListView(
          padding: const EdgeInsets.all(12),
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.badgeBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: const Text(
                'Retake all 3 GPS-stamped site photos to resubmit for '
                'NOC verification.',
                style: TextStyle(fontSize: 13, color: AppTheme.badgeText),
              ),
            ),
            const SizedBox(height: 8),
            ...sitePhotoSlots.map((slot) {
              final photo = _photos[slot.type];
              return PhotoCaptureTile(
                title: slot.title,
                bytes: photo?.bytes,
                gps: photo?.gps,
                onCapture: () => _capture(slot.type),
                onRetake: () => setState(() => _photos.remove(slot.type)),
              );
            }),
          ],
        ),
        bottomNavigationBar: SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: FilledButton.icon(
              onPressed: _allTaken ? _submit : null,
              icon: const Icon(Icons.check),
              label: Text(_allTaken
                  ? 'Resubmit 3 Photos'
                  : 'Take all 3 photos to resubmit'),
            ),
          ),
        ),
      ),
    );
  }
}

class _Captured {
  final Uint8List bytes;
  final GpsPoint? gps;
  final DateTime capturedAt;
  const _Captured(this.bytes, this.gps, this.capturedAt);
}
