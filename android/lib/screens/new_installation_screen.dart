import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:itrack_fe/api/api_exception.dart';
import 'package:itrack_fe/models/form_options.dart';
import 'package:itrack_fe/state/new_installation_state.dart';
import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/utils/constants.dart';
import 'package:itrack_fe/screens/tracker_detail_screen.dart';
import 'package:itrack_fe/widgets/field_snap_button.dart';
import 'package:itrack_fe/widgets/loading_overlay.dart';
import 'package:itrack_fe/widgets/photo_capture_tile.dart';

/// Two-step create-tracker wizard mirroring fe_new_installation.html:
/// Step 1 = three mandatory GPS-stamped site photos, Step 2 = details form.
class NewInstallationScreen extends StatefulWidget {
  const NewInstallationScreen({super.key});

  @override
  State<NewInstallationScreen> createState() => _NewInstallationScreenState();
}

class _NewInstallationScreenState extends State<NewInstallationScreen> {
  final NewInstallationState _state = NewInstallationState();
  int _step = 0; // 0 = photos, 1 = form

  @override
  void initState() {
    super.initState();
    _state.loadOptions();
  }

  @override
  void dispose() {
    _state.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider.value(
      value: _state,
      child: Consumer<NewInstallationState>(
        builder: (context, state, _) {
          return Scaffold(
            appBar: AppBar(
              // On the details step, the AppBar back arrow returns to Photos
              // (instead of leaving the wizard). This keeps "Back" out of the
              // bottom bar so the bar can be a single button — a multi-child
              // Row there fails to lay out because this bottomNavigationBar slot
              // is handed an unbounded max width on the details step.
              leading: _step == 1
                  ? IconButton(
                      icon: const Icon(Icons.arrow_back),
                      onPressed:
                          state.busy ? null : () => setState(() => _step = 0),
                    )
                  : null,
              title: Text(_step == 0
                  ? 'New Installation · Photos'
                  : 'New Installation · Details'),
            ),
            body: LoadingOverlay(
              visible: state.busy,
              label: state.busyLabel,
              child: _step == 0
                  ? _PhotoStep(state: state)
                  : _FormStep(state: state),
            ),
            bottomNavigationBar: _buildBottomBar(state),
          );
        },
      ),
    );
  }

  Widget _buildBottomBar(NewInstallationState state) {
    return SafeArea(
      // Per-step key: forces a fresh render subtree on the photos→details
      // change so this bar isn't relaid-out with stale unbounded constraints.
      key: ValueKey('bottom-bar-$_step'),
      child: Padding(
        padding: const EdgeInsets.all(12),
        // Single full-width button only — no Row. A lone button sizes cleanly
        // under any constraints; a Row with a non-Expanded child demands
        // infinite width in this slot and fails to lay out.
        child: _step == 0
            ? FilledButton.icon(
                onPressed: (state.allSitePhotosTaken && !state.busy)
                    ? () => setState(() => _step = 1)
                    : null,
                icon: const Icon(Icons.arrow_forward),
                label: Text(state.allSitePhotosTaken
                    ? 'Continue to Details'
                    : 'Take all 3 photos to continue'),
              )
            : FilledButton.icon(
                onPressed: state.busy ? null : () => _submit(state),
                icon: const Icon(Icons.check),
                label: const Text('Create Installation'),
              ),
      ),
    );
  }

  Future<void> _submit(NewInstallationState state) async {
    final formKey = _FormStep.formKey;
    if (formKey.currentState?.validate() != true) return;
    final values = _FormStep.values;

    try {
      final tracker = await state.submit(
        sdwanId: values['sdwan_id']!,
        customer: values['customer']!,
        fePhone: values['fe_phone']!,
        sim1Provider: values['sim1_provider']!,
        sim1Number: values['sim1_number']!,
        sim2Provider: values['sim2_provider'],
        sim2Number: values['sim2_number'],
        routerType: values['router_type']!,
        routerMake: values['router_make']!,
        routerFirmwareVersion: values['router_firmware_version']!,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Installation created ✓')),
      );
      // Replace so back returns to the dashboard, not the wizard.
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
            builder: (_) => TrackerDetailScreen(trackerId: tracker.id)),
      );
    } on DuplicateSdwanIdException catch (e) {
      if (!mounted) return;
      _showDuplicateDialog(e.existingTrackerId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  void _showDuplicateDialog(String? existingId) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('SDWAN ID already exists'),
        content: const Text(
            'A tracker with this SDWAN ID already exists. Open it instead?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Change ID')),
          if (existingId != null)
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pushReplacement(
                  context,
                  MaterialPageRoute(
                      builder: (_) =>
                          TrackerDetailScreen(trackerId: existingId)),
                );
              },
              child: const Text('Open Existing'),
            ),
        ],
      ),
    );
  }
}

// ── Step 1: site photos ──

class _PhotoStep extends StatelessWidget {
  final NewInstallationState state;
  const _PhotoStep({required this.state});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(12),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.badgeBg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Text(
            'Take 3 site photos. Each is GPS-stamped automatically — make sure '
            'location is on.',
            style: TextStyle(fontSize: 13, color: AppTheme.badgeText),
          ),
        ),
        const SizedBox(height: 8),
        ...sitePhotoSlots.map((slot) {
          final photo = state.sitePhotos[slot.type];
          return PhotoCaptureTile(
            title: slot.title,
            bytes: photo?.jpegBytes,
            gps: photo?.gps,
            onCapture: () => _capture(context, slot.type),
            onRetake: () => state.removeSitePhoto(slot.type),
          );
        }),
      ],
    );
  }

  Future<void> _capture(BuildContext context, String type) async {
    final error = await state.captureSitePhoto(type);
    if (error != null && context.mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error)));
    }
  }
}

// ── Step 2: details form ──

/// Holds the form field values so the parent's submit can read them.
/// Static because the wizard owns a single form instance at a time.
class _FormStep extends StatefulWidget {
  final NewInstallationState state;
  const _FormStep({required this.state});

  static final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  static final Map<String, String?> values = {};

  @override
  State<_FormStep> createState() => _FormStepState();
}

class _FormStepState extends State<_FormStep> {
  final _sdwanController = TextEditingController();
  final _phoneController = TextEditingController();
  final _sim1NumberController = TextEditingController();
  final _sim2NumberController = TextEditingController();
  final _firmwareController = TextEditingController();

  String? _customer;
  String? _sim1Provider;
  String? _sim2Provider;
  String? _routerType;
  String? _routerMake;

  @override
  void dispose() {
    _sdwanController.dispose();
    _phoneController.dispose();
    _sim1NumberController.dispose();
    _sim2NumberController.dispose();
    _firmwareController.dispose();
    super.dispose();
  }

  void _sync() {
    _FormStep.values
      ..['sdwan_id'] = _sdwanController.text.trim()
      ..['customer'] = _customer
      ..['fe_phone'] = _phoneController.text.trim()
      ..['sim1_provider'] = _sim1Provider
      ..['sim1_number'] = _sim1NumberController.text.trim()
      ..['sim2_provider'] = _sim2Provider
      ..['sim2_number'] = _sim2NumberController.text.trim()
      ..['router_type'] = _routerType
      ..['router_make'] = _routerMake
      ..['router_firmware_version'] = _firmwareController.text.trim();
  }

  @override
  Widget build(BuildContext context) {
    final options = widget.state.options;
    if (options == null && widget.state.optionsError == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Form(
      key: _FormStep.formKey,
      onChanged: _sync,
      child: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          if (widget.state.optionsError != null)
            Container(
              padding: const EdgeInsets.all(10),
              margin: const EdgeInsets.only(bottom: 10),
              color: Colors.orange.shade50,
              child: Text(
                'Could not load dropdown options: ${widget.state.optionsError}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          _snapField(
            controller: _sdwanController,
            label: 'SDWAN ID *',
            fieldKey: null,
            validator: _required,
          ),
          _dropdown(
            label: 'Customer *',
            value: _customer,
            items: options?.customers ?? [],
            onChanged: (v) => setState(() {
              _customer = v;
              _sync();
            }),
          ),
          TextFormField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
                labelText: 'FE Phone Number *', prefixIcon: Icon(Icons.phone)),
            validator: _required,
          ),
          const SizedBox(height: 12),
          _sectionTitle('SIM 1 *'),
          _dropdown(
            label: 'SIM 1 Provider *',
            value: _sim1Provider,
            items: options?.simProviders ?? [],
            fieldKey: 'sim1_provider',
            onChanged: (v) => setState(() {
              _sim1Provider = v;
              _sync();
            }),
          ),
          _snapField(
            controller: _sim1NumberController,
            label: 'SIM 1 Number *',
            fieldKey: 'sim1_number',
            validator: _required,
          ),
          const SizedBox(height: 12),
          _sectionTitle('SIM 2 (Optional)'),
          _dropdown(
            label: 'SIM 2 Provider',
            value: _sim2Provider,
            items: options?.simProviders ?? [],
            fieldKey: 'sim2_provider',
            onChanged: (v) => setState(() {
              _sim2Provider = v;
              _sync();
            }),
          ),
          _snapField(
            controller: _sim2NumberController,
            label: 'SIM 2 Number',
            fieldKey: 'sim2_number',
          ),
          const SizedBox(height: 12),
          _sectionTitle('Router *'),
          _dropdown(
            label: 'Router Type *',
            value: _routerType,
            items: options?.routerTypes ?? [],
            onChanged: (v) => setState(() {
              _routerType = v;
              _sync();
            }),
          ),
          _dropdown(
            label: 'Router Make *',
            value: _routerMake,
            items: options?.routerMakes ?? [],
            onChanged: (v) => setState(() {
              _routerMake = v;
              _sync();
            }),
          ),
          _snapField(
            controller: _firmwareController,
            label: 'Firmware Version *',
            fieldKey: 'router_firmware_version',
            validator: _required,
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  String? _required(String? v) =>
      (v == null || v.trim().isEmpty) ? 'Required' : null;

  Widget _sectionTitle(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6, top: 4),
        child: Text(text, style: AppTheme.heading.copyWith(fontSize: 14)),
      );

  Widget _dropdown({
    required String label,
    required String? value,
    required List<OptionItem> items,
    required ValueChanged<String?> onChanged,
    String? fieldKey,
  }) {
    final dropdown = DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(labelText: label),
      validator: label.endsWith('*') ? _required : null,
      items: items
          .map((o) => DropdownMenuItem(
                value: o.value,
                child: Text(o.label, overflow: TextOverflow.ellipsis),
              ))
          .toList(),
      onChanged: onChanged,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: fieldKey == null
          ? dropdown
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: dropdown),
                const SizedBox(width: 8),
                _snapButton(fieldKey),
              ],
            ),
    );
  }

  Widget _snapField({
    required TextEditingController controller,
    required String label,
    required String? fieldKey,
    String? Function(String?)? validator,
  }) {
    final field = TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
      validator: validator,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: fieldKey == null
          ? field
          : Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: field),
                const SizedBox(width: 8),
                _snapButton(fieldKey),
              ],
            ),
    );
  }

  Widget _snapButton(String fieldKey) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: FieldSnapButton(
        snap: widget.state.fieldSnaps[fieldKey],
        onCapture: () async {
          final error = await widget.state.captureFieldSnap(fieldKey);
          if (error != null && mounted) {
            ScaffoldMessenger.of(context)
                .showSnackBar(SnackBar(content: Text(error)));
          }
        },
        onClear: () => widget.state.removeFieldSnap(fieldKey),
      ),
    );
  }
}
