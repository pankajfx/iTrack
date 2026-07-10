import 'package:itrack_fe/api/api_client.dart';
import 'package:itrack_fe/models/form_options.dart';

/// GET /api/android/form-options — DB-backed dropdown lists for the
/// new-installation form (form_options collection; seeded by
/// scripts/seed_form_options.py).
class OptionsApi {
  final ApiClient _client;
  OptionsApi([ApiClient? client]) : _client = client ?? ApiClient.instance;

  Future<FormOptions> formOptions() async {
    final body =
        await _client.requestJson((dio) => dio.get('/api/android/form-options'));
    return FormOptions.fromJson(body);
  }
}
