import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

/// Connection-first home screen shown before the camera stream.
///
/// Workflow:
/// 1. Load saved server URL on launch.
/// 2. If a URL is saved, attempt to auto-connect to GET /health.
/// 3. Show Connecting / Connected / Failed states clearly.
/// 4. Only navigate to the camera screen after a successful connection.
class ConnectionScreen extends StatefulWidget {
  /// Called when the server is reachable and the user should proceed.
  final void Function(String wsUrl, String token) onConnected;

  const ConnectionScreen({super.key, required this.onConnected});

  @override
  State<ConnectionScreen> createState() => _ConnectionScreenState();
}

enum _ConnState { idle, connecting, connected, failed }

class _ConnectionScreenState extends State<ConnectionScreen> {
  final _urlCtrl = TextEditingController();
  final _tokenCtrl = TextEditingController();

  _ConnState _state = _ConnState.idle;
  String _errorMsg = '';

  @override
  void initState() {
    super.initState();
    _loadAndAutoConnect();
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadAndAutoConnect() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString('serverUrl') ?? '';
    final savedToken = prefs.getString('token') ?? '';
    _urlCtrl.text = savedUrl;
    _tokenCtrl.text = savedToken;

    if (savedUrl.isNotEmpty) {
      await _connect(savedUrl, savedToken);
    }
  }

  /// Converts a server base URL (http/https) to ws/wss WebSocket URL.
  String _toWsUrl(String base) {
    final trimmed = base.trim().replaceAll(RegExp(r'/$'), '');
    if (trimmed.startsWith('ws://') || trimmed.startsWith('wss://')) {
      if (!trimmed.endsWith('/ws')) return '$trimmed/ws';
      return trimmed;
    }
    final wsBase = trimmed
        .replaceFirst('https://', 'wss://')
        .replaceFirst('http://', 'ws://');
    return '$wsBase/ws';
  }

  /// Derives an HTTP health-check URL from the user input.
  String _toHealthUrl(String input) {
    final trimmed = input.trim().replaceAll(RegExp(r'/$'), '');
    final httpBase = trimmed
        .replaceFirst('wss://', 'https://')
        .replaceFirst('ws://', 'http://');
    // Strip trailing /ws path if present so we can append /health
    final base = httpBase.endsWith('/ws')
        ? httpBase.substring(0, httpBase.length - 3)
        : httpBase;
    return '$base/health';
  }

  Future<void> _connect(String rawUrl, String token) async {
    if (!mounted) return;
    setState(() {
      _state = _ConnState.connecting;
      _errorMsg = '';
    });

    final healthUrl = _toHealthUrl(rawUrl);
    try {
      final uri = Uri.parse(healthUrl);
      final response = await http
          .get(uri, headers: token.isNotEmpty ? {'X-Token': token} : {})
          .timeout(const Duration(seconds: 8));

      if (!mounted) return;
      if (response.statusCode == 200 || response.statusCode == 401) {
        // 401 means the server IS reachable, auth is checked at WS level
        // Create a server-side session so the GPU worker has a stable source-face key.
        final base = rawUrl.trim().replaceAll(RegExp(r'/$'), '')
            .replaceFirst(RegExp(r'/ws$'), '');
        final sessionResponse = await http.post(
          Uri.parse('$base/v1/sessions'),
          headers: {
            'Content-Type': 'application/json',
            if (token.trim().isNotEmpty) 'Authorization': 'Bearer ${token.trim()}',
          },
          body: '{"client_name":"flutter_app","transport":"ws","fps":8,"resolution":"640x480"}',
        ).timeout(const Duration(seconds: 8));

        if (sessionResponse.statusCode < 200 || sessionResponse.statusCode >= 300) {
          throw Exception('Session creation failed: HTTP ${sessionResponse.statusCode} ${sessionResponse.body}');
        }
        final session = jsonDecode(sessionResponse.body) as Map<String, dynamic>;
        final wsUrl = session['ws_url'] as String?;
        if (wsUrl == null || wsUrl.isEmpty) {
          throw Exception('Server did not return ws_url');
        }

        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('serverUrl', rawUrl.trim());
        await prefs.setString('token', token.trim());
        await prefs.setString('sessionId', session['session_id'] as String? ?? '');
        setState(() => _state = _ConnState.connected);
        await Future.delayed(const Duration(milliseconds: 400));
        if (mounted) widget.onConnected(wsUrl, token.trim());
      } else {
        setState(() {
          _state = _ConnState.failed;
          _errorMsg = 'Server returned HTTP ${response.statusCode}';
        });
      }
    } on TimeoutException {
      if (mounted) {
        setState(() {
          _state = _ConnState.failed;
          _errorMsg = 'Connection timed out. Check the server URL.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _state = _ConnState.failed;
          _errorMsg = 'Cannot reach server: $e';
        });
      }
    }
  }

  void _onConnectPressed() {
    final url = _urlCtrl.text.trim();
    if (url.isEmpty) {
      setState(() {
        _state = _ConnState.failed;
        _errorMsg = 'Please enter a server URL.';
      });
      return;
    }
    _connect(url, _tokenCtrl.text.trim());
  }

  @override
  Widget build(BuildContext context) {
    final isConnecting = _state == _ConnState.connecting;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // App icon / logo
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A84FF),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Icon(Icons.videocam, color: Colors.white, size: 44),
                ),
                const SizedBox(height: 20),
                Text(
                  'FaceSwap Cam',
                  style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Connect to your face-swap server',
                  style: Theme.of(context)
                      .textTheme
                      .bodyMedium
                      ?.copyWith(color: Colors.white54),
                ),
                const SizedBox(height: 40),

                // State indicator
                _StateIndicator(state: _state, errorMsg: _errorMsg),
                const SizedBox(height: 28),

                // Server URL field
                TextField(
                  controller: _urlCtrl,
                  enabled: !isConnecting,
                  style: const TextStyle(color: Colors.white),
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(
                    labelText: 'Server URL',
                    hintText: 'http://192.168.1.x or http://yourserver.com',
                    labelStyle: const TextStyle(color: Colors.white54),
                    hintStyle: const TextStyle(color: Colors.white24),
                    filled: true,
                    fillColor: const Color(0xFF1C1C1E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(Icons.dns, color: Colors.white38),
                  ),
                ),
                const SizedBox(height: 14),

                // Token field
                TextField(
                  controller: _tokenCtrl,
                  enabled: !isConnecting,
                  obscureText: true,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'Auth Token (optional)',
                    labelStyle: const TextStyle(color: Colors.white54),
                    filled: true,
                    fillColor: const Color(0xFF1C1C1E),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                    prefixIcon: const Icon(Icons.lock_outline, color: Colors.white38),
                  ),
                ),
                const SizedBox(height: 28),

                // Connect button
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    onPressed: isConnecting ? null : _onConnectPressed,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0A84FF),
                      foregroundColor: Colors.white,
                      disabledBackgroundColor: const Color(0xFF0A84FF).withOpacity(0.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: isConnecting
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: Colors.white,
                            ),
                          )
                        : const Text(
                            'Connect',
                            style: TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                  ),
                ),

                const SizedBox(height: 24),
                Text(
                  'URL format: http://SERVER_IP  (e.g. http://192.168.1.100)\n'
                  'The app will connect to /health to verify, then stream via /ws.',
                  textAlign: TextAlign.center,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: Colors.white24),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StateIndicator extends StatelessWidget {
  final _ConnState state;
  final String errorMsg;
  const _StateIndicator({required this.state, required this.errorMsg});

  @override
  Widget build(BuildContext context) {
    switch (state) {
      case _ConnState.idle:
        return const SizedBox.shrink();
      case _ConnState.connecting:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blueAccent),
            ),
            const SizedBox(width: 10),
            Text('Connecting…', style: TextStyle(color: Colors.blueAccent.shade100)),
          ],
        );
      case _ConnState.connected:
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.check_circle, color: Colors.greenAccent, size: 20),
            const SizedBox(width: 8),
            Text('Connected — starting camera…',
                style: const TextStyle(color: Colors.greenAccent)),
          ],
        );
      case _ConnState.failed:
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.red.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: Colors.red.withOpacity(0.4)),
          ),
          child: Row(
            children: [
              const Icon(Icons.error_outline, color: Colors.redAccent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  errorMsg.isNotEmpty ? errorMsg : 'Connection failed',
                  style: const TextStyle(color: Colors.redAccent),
                ),
              ),
            ],
          ),
        );
    }
  }
}
