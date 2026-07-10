import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';

/// Renders a base64 data-URL image (the only image format the Flask API
/// serves — images live inline in MongoDB documents, not at URLs).
/// Decoded bytes are memo-cached (small LRU) so list scrolling stays smooth.
class Base64Image extends StatelessWidget {
  final String dataUrl;
  final BoxFit fit;
  final double? width;
  final double? height;

  const Base64Image(
    this.dataUrl, {
    super.key,
    this.fit = BoxFit.cover,
    this.width,
    this.height,
  });

  static final Map<String, Uint8List> _cache = {};
  static const int _cacheLimit = 40;

  static Uint8List? decode(String dataUrl) {
    if (dataUrl.isEmpty) return null;
    final cached = _cache[dataUrl];
    if (cached != null) return cached;

    final comma = dataUrl.indexOf(',');
    final raw = comma >= 0 ? dataUrl.substring(comma + 1) : dataUrl;
    Uint8List bytes;
    try {
      bytes = base64Decode(raw);
    } catch (_) {
      return null;
    }

    if (_cache.length >= _cacheLimit) {
      _cache.remove(_cache.keys.first); // drop oldest entry
    }
    _cache[dataUrl] = bytes;
    return bytes;
  }

  @override
  Widget build(BuildContext context) {
    final bytes = decode(dataUrl);
    if (bytes == null) {
      return Container(
        width: width,
        height: height,
        color: Colors.grey.shade200,
        alignment: Alignment.center,
        child: const Icon(Icons.broken_image, color: Colors.grey),
      );
    }
    return Image.memory(
      bytes,
      fit: fit,
      width: width,
      height: height,
      gaplessPlayback: true,
    );
  }
}
