import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'package:itrack_fe/api/auth_api.dart';
import 'package:itrack_fe/state/auth_state.dart';
import 'package:itrack_fe/state/server_config.dart';
import 'package:itrack_fe/theme/app_theme.dart';

/// First-run screen: enter the Flask server URL and test connectivity.
/// Also reachable later from a settings gear to switch servers.
class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  late final TextEditingController _controller;
  bool _testing = false;
  String? _message;
  bool _ok = false;

  @override
  void initState() {
    super.initState();
    final existing = context.read<ServerConfig>().baseUrl;
    _controller = TextEditingController(
      text: existing.isNotEmpty ? existing : 'https://',
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _testAndSave() async {
    setState(() {
      _testing = true;
      _message = null;
      _ok = false;
    });
    final serverConfig = context.read<ServerConfig>();
    try {
      await serverConfig.save(_controller.text);
      // Ping goes through the freshly-configured client.
      final result = await AuthApi().ping();
      if (result['app'] == 'iTrack') {
        setState(() {
          _ok = true;
          _message = 'Connected to iTrack server ✓';
        });
        // Re-check whether an existing session cookie is still valid.
        if (mounted) await context.read<AuthState>().restoreSession();
      } else {
        setState(() => _message = 'Reached a server, but it is not iTrack');
      }
    } on FormatException catch (e) {
      setState(() => _message = e.message);
    } catch (e) {
      setState(() => _message = 'Could not connect: $e');
    } finally {
      if (mounted) setState(() => _testing = false);
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
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Row(
                        children: [
                          Icon(Icons.dns, color: AppTheme.primary),
                          SizedBox(width: 8),
                          Text('Server Setup', style: AppTheme.heading),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Enter the address of your iTrack server. Ask your '
                        'coordinator if you are not sure.',
                        style: TextStyle(
                            fontSize: 13, color: Colors.grey.shade600),
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: _controller,
                        keyboardType: TextInputType.url,
                        autocorrect: false,
                        decoration: const InputDecoration(
                          labelText: 'Server URL',
                          hintText: 'https://itrack.example.com',
                          prefixIcon: Icon(Icons.link),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        'Examples: https://192.168.1.50  or  '
                        'http://192.168.1.50:5001 (dev)',
                        style: TextStyle(
                            fontSize: 11, color: Colors.grey.shade500),
                      ),
                      if (_message != null) ...[
                        const SizedBox(height: 14),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: _ok
                                ? Colors.green.shade50
                                : Colors.red.shade50,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _ok ? Icons.check_circle : Icons.error_outline,
                                color: _ok ? Colors.green : Colors.red,
                                size: 18,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_message!,
                                    style: const TextStyle(fontSize: 13)),
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 20),
                      FilledButton.icon(
                        onPressed: _testing ? null : _testAndSave,
                        icon: _testing
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Colors.white))
                            : const Icon(Icons.wifi_tethering),
                        label: Text(_testing ? 'Testing…' : 'Test & Continue'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
