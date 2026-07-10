import 'package:flutter/material.dart';
import 'package:photo_view/photo_view.dart';

import 'package:itrack_fe/widgets/base64_image.dart';

/// Full-screen, pinch-to-zoom viewer for a base64 data-URL image
/// (site photos, field snaps, chat images).
class ImageViewerScreen extends StatelessWidget {
  final String dataUrl;
  final String title;

  const ImageViewerScreen({
    super.key,
    required this.dataUrl,
    this.title = 'Photo',
  });

  static void open(BuildContext context, String dataUrl, {String title = 'Photo'}) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImageViewerScreen(dataUrl: dataUrl, title: title),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bytes = Base64Image.decode(dataUrl);
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(title),
      ),
      body: bytes == null
          ? const Center(
              child: Icon(Icons.broken_image, color: Colors.white54, size: 64))
          : PhotoView(
              imageProvider: MemoryImage(bytes),
              minScale: PhotoViewComputedScale.contained,
              maxScale: PhotoViewComputedScale.covered * 3,
              backgroundDecoration:
                  const BoxDecoration(color: Colors.black),
            ),
    );
  }
}
