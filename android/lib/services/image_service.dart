import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import 'package:itrack_fe/utils/constants.dart';

/// Camera capture + compression.
///
/// The web app captures via getUserMedia → canvas JPEG (q0.85), and the
/// server re-encodes chat uploads to max 1024px JPEG q85 (Pillow). We match
/// that target on-device so payloads stay small BEFORE they travel over
/// mobile data: max side 1024, JPEG quality 85.
class ImageService {
  final ImagePicker _picker = ImagePicker();

  /// Ask for camera permission if needed. Returns true when granted.
  Future<bool> ensureCameraPermission() async {
    final status = await Permission.camera.request();
    return status.isGranted || status.isLimited;
  }

  /// Launch the native camera app and return compressed JPEG bytes,
  /// or null if the user cancelled.
  Future<Uint8List?> captureJpeg() async {
    final XFile? shot = await _picker.pickImage(
      source: ImageSource.camera,
      // Pre-shrink in the camera pipeline; final pass below enforces exactly.
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 92,
    );
    if (shot == null) return null;
    return _compress(await shot.readAsBytes());
  }

  /// Pick an existing photo from the gallery (used by chat attachments).
  Future<Uint8List?> pickFromGallery() async {
    final XFile? picked = await _picker.pickImage(source: ImageSource.gallery);
    if (picked == null) return null;
    return _compress(await picked.readAsBytes());
  }

  Future<Uint8List> _compress(Uint8List raw) async {
    return FlutterImageCompress.compressWithList(
      raw,
      minWidth: imageMaxSide,
      minHeight: imageMaxSide,
      quality: imageJpegQuality,
      format: CompressFormat.jpeg,
    );
  }

  /// Base64 data-URL string — the format every image field in the Flask API
  /// expects (tracker images{}, site_images[].data).
  String toDataUrl(Uint8List jpegBytes) =>
      'data:image/jpeg;base64,${base64Encode(jpegBytes)}';
}
