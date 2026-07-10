/// Dropdown option lists for the new-installation form,
/// served by GET /api/android/form-options (form_options collection).
class OptionItem {
  final String value;
  final String label;

  const OptionItem({required this.value, required this.label});

  factory OptionItem.fromJson(Map<String, dynamic> json) => OptionItem(
        value: json['value'] ?? '',
        label: json['label'] ?? json['value'] ?? '',
      );
}

class FormOptions {
  final List<OptionItem> customers;
  final List<OptionItem> simProviders;
  final List<OptionItem> routerTypes;
  final List<OptionItem> routerMakes;

  const FormOptions({
    required this.customers,
    required this.simProviders,
    required this.routerTypes,
    required this.routerMakes,
  });

  static List<OptionItem> _list(dynamic raw) => (raw as List? ?? [])
      .map((e) => OptionItem.fromJson(e as Map<String, dynamic>))
      .toList();

  factory FormOptions.fromJson(Map<String, dynamic> json) => FormOptions(
        customers: _list(json['customers']),
        simProviders: _list(json['sim_providers']),
        routerTypes: _list(json['router_types']),
        routerMakes: _list(json['router_makes']),
      );
}
