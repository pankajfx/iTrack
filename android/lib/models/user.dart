/// Logged-in user profile, as returned by GET /api/android/me.
class User {
  final String userId;
  final String username;
  final String name;
  final String role;
  final String? region;
  final String? feGroup;
  final String? email;
  final String? contact;
  final String? location;

  const User({
    required this.userId,
    required this.username,
    required this.name,
    required this.role,
    this.region,
    this.feGroup,
    this.email,
    this.contact,
    this.location,
  });

  factory User.fromJson(Map<String, dynamic> json) => User(
        userId: json['user_id'] ?? '',
        username: json['username'] ?? '',
        name: json['name'] ?? '',
        role: json['role'] ?? '',
        region: json['region'],
        feGroup: json['fe_group'],
        email: json['email'],
        contact: json['contact'],
        location: json['location'],
      );
}

/// Entry in the login dropdowns (GET /api/login/field-engineer-groups and
/// GET /api/login/field-engineers).
class LoginOption {
  final String username;
  final String name;
  final String? region;
  final String? feGroup;

  const LoginOption({
    required this.username,
    required this.name,
    this.region,
    this.feGroup,
  });

  factory LoginOption.fromJson(Map<String, dynamic> json) => LoginOption(
        username: json['username'] ?? '',
        name: json['name'] ?? '',
        region: json['region'],
        feGroup: json['field_engineer_group'],
      );
}
