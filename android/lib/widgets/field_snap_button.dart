import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:itrack_fe/theme/app_theme.dart';

/// Small camera button beside a form field (SIM number, firmware, …).
/// Turns green with a thumbnail once a snap is captured — mirrors the
/// per-field camera buttons in fe_new_installation.html.
class FieldSnapButton extends StatelessWidget {
  final Uint8List? snap;
  final VoidCallback onCapture;
  final VoidCallback onClear;

  const FieldSnapButton({
    super.key,
    required this.snap,
    required this.onCapture,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    if (snap != null) {
      return InkWell(
        onTap: onClear,
        borderRadius: BorderRadius.circular(10),
        child: Stack(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Image.memory(snap!, width: 48, height: 48, fit: BoxFit.cover),
            ),
            Positioned(
              right: 0,
              top: 0,
              child: Container(
                decoration: const BoxDecoration(
                    color: Colors.red, shape: BoxShape.circle),
                child: const Icon(Icons.close, size: 14, color: Colors.white),
              ),
            ),
          ],
        ),
      );
    }
    return SizedBox(
      width: 48,
      height: 48,
      child: Material(
        color: AppTheme.badgeBg,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onCapture,
          child: const Icon(Icons.photo_camera, color: AppTheme.primary, size: 20),
        ),
      ),
    );
  }
}
