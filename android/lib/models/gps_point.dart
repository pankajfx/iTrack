/// GPS stamp attached to each site-verification photo.
/// Serialized into site_images[].gps exactly as the web wizard does.
class GpsPoint {
  final double lat;
  final double lng;
  final String address;

  const GpsPoint({required this.lat, required this.lng, this.address = ''});

  factory GpsPoint.fromJson(Map<String, dynamic> json) => GpsPoint(
        lat: (json['lat'] as num?)?.toDouble() ?? 0,
        lng: (json['lng'] as num?)?.toDouble() ?? 0,
        address: json['address'] ?? '',
      );

  Map<String, dynamic> toJson() => {'lat': lat, 'lng': lng, 'address': address};

  String get coordsLabel =>
      '${lat.toStringAsFixed(5)}, ${lng.toStringAsFixed(5)}';
}
