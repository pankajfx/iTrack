import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:itrack_fe/api/auth_api.dart';
import 'package:itrack_fe/models/user.dart';
import 'package:itrack_fe/state/auth_state.dart';
import 'package:itrack_fe/theme/app_theme.dart';
import 'package:itrack_fe/screens/server_setup_screen.dart';

/// FE login: pick group → pick engineer (both DB-driven dropdowns) → password.
/// Mirrors the web login flow for the FIELD_ENGINEER role.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final AuthApi _api = AuthApi();
  final _passwordController = TextEditingController();

  List<LoginOption> _groups = [];
  List<LoginOption> _engineers = [];
  String? _selectedGroup;
  String? _selectedEngineer;

  bool _loadingGroups = true;
  bool _loadingEngineers = false;
  bool _submitting = false;
  bool _obscure = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    // Show a "session expired" note if we were kicked back here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (context.read<AuthState>().consumeSessionExpiredNotice() && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Session expired — please log in again')));
      }
    });
    _loadGroups();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _loadGroups() async {
    setState(() {
      _loadingGroups = true;
      _error = null;
    });
    final authState = context.read<AuthState>();
    try {
      final groups = await _api.fieldEngineerGroups();
      final (lastGroup, lastName) = await authState.lastLoginSelection();
      setState(() {
        _groups = groups;
        _selectedGroup =
            groups.any((g) => g.name == lastGroup) ? lastGroup : null;
      });
      if (_selectedGroup != null) {
        await _loadEngineers(_selectedGroup!, preselectName: lastName);
      }
    } catch (e) {
      setState(() => _error = 'Could not load groups: $e');
    } finally {
      if (mounted) setState(() => _loadingGroups = false);
    }
  }

  Future<void> _loadEngineers(String group, {String? preselectName}) async {
    setState(() {
      _loadingEngineers = true;
      _engineers = [];
      _selectedEngineer = null;
    });
    try {
      final engineers = await _api.fieldEngineers(group);
      setState(() {
        _engineers = engineers;
        _selectedEngineer =
            engineers.any((e) => e.name == preselectName) ? preselectName : null;
      });
    } catch (e) {
      setState(() => _error = 'Could not load engineers: $e');
    } finally {
      if (mounted) setState(() => _loadingEngineers = false);
    }
  }

  Future<void> _submit() async {
    if (_selectedGroup == null ||
        _selectedEngineer == null ||
        _passwordController.text.isEmpty) {
      setState(() => _error = 'Select your group, name, and enter a password');
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await context.read<AuthState>().login(
            feName: _selectedEngineer!,
            feGroup: _selectedGroup!,
            password: _passwordController.text,
          );
      // On success the root router swaps to the dashboard automatically.
    } catch (e) {
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(gradient: AppTheme.headerGradient),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Column(
                children: [
                  const Icon(Icons.router, color: Colors.white, size: 48),
                  const SizedBox(height: 8),
                  const Text(
                    'iTrack Field Engineer',
                    style: TextStyle(
                      fontFamily: 'FjallaOne',
                      fontSize: 24,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 20),
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Sign in', style: AppTheme.heading),
                          const SizedBox(height: 16),
                          _loadingGroups
                              ? const Padding(
                                  padding: EdgeInsets.all(16),
                                  child: Center(
                                      child: CircularProgressIndicator()),
                                )
                              : DropdownButtonFormField<String>(
                                  value: _selectedGroup,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'FE Group',
                                    prefixIcon: Icon(Icons.groups),
                                  ),
                                  items: _groups
                                      .map((g) => DropdownMenuItem(
                                            value: g.name,
                                            child: Text(g.name,
                                                overflow:
                                                    TextOverflow.ellipsis),
                                          ))
                                      .toList(),
                                  onChanged: (value) {
                                    setState(() => _selectedGroup = value);
                                    if (value != null) _loadEngineers(value);
                                  },
                                ),
                          const SizedBox(height: 14),
                          DropdownButtonFormField<String>(
                            value: _selectedEngineer,
                            isExpanded: true,
                            decoration: InputDecoration(
                              labelText: 'Your Name',
                              prefixIcon: const Icon(Icons.person),
                              suffixIcon: _loadingEngineers
                                  ? const Padding(
                                      padding: EdgeInsets.all(12),
                                      child: SizedBox(
                                          width: 16,
                                          height: 16,
                                          child: CircularProgressIndicator(
                                              strokeWidth: 2)),
                                    )
                                  : null,
                            ),
                            items: _engineers
                                .map((e) => DropdownMenuItem(
                                      value: e.name,
                                      child: Text(e.name,
                                          overflow: TextOverflow.ellipsis),
                                    ))
                                .toList(),
                            onChanged: _engineers.isEmpty
                                ? null
                                : (value) =>
                                    setState(() => _selectedEngineer = value),
                          ),
                          const SizedBox(height: 14),
                          TextField(
                            controller: _passwordController,
                            obscureText: _obscure,
                            onSubmitted: (_) => _submit(),
                            decoration: InputDecoration(
                              labelText: 'Password',
                              prefixIcon: const Icon(Icons.lock),
                              suffixIcon: IconButton(
                                icon: Icon(_obscure
                                    ? Icons.visibility
                                    : Icons.visibility_off),
                                onPressed: () =>
                                    setState(() => _obscure = !_obscure),
                              ),
                            ),
                          ),
                          if (_error != null) ...[
                            const SizedBox(height: 12),
                            Text(_error!,
                                style: const TextStyle(
                                    color: Colors.red, fontSize: 13)),
                          ],
                          const SizedBox(height: 20),
                          FilledButton(
                            onPressed: _submitting ? null : _submit,
                            child: _submitting
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                        strokeWidth: 2, color: Colors.white))
                                : const Text('Sign In'),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton.icon(
                    onPressed: () => Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const ServerSetupScreen()),
                    ),
                    icon: const Icon(Icons.settings, color: Colors.white70),
                    label: const Text('Server Settings',
                        style: TextStyle(color: Colors.white70)),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
