import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

/// Connection states exposed to the UI.
enum ConnectionStatus { searching, connecting, connected, failed, disconnected }

/// Response from /v1/info endpoint.
class ServerInfo {
  final String server;
  final String version;
  final String device;
  final String hostname;
  final String ip;

  const ServerInfo({
    required this.server,
    required this.version,
    required this.device,
    required this.hostname,
    required this.ip,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
        server: json['server'] as String? ?? '',
        version: json['version'] as String? ?? '',
        device: json['device'] as String? ?? '',
        hostname: json['hostname'] as String? ?? '',
        ip: json['ip'] as String? ?? '',
      );
}

/// Service that manages health-check polling and session lifecycle.
///
/// API contract:
///   GET  /health          → {"status":"ok","device":"cpu|cuda"}
///   GET  /v1/info         → {"server":…,"ip":…,"hostname":…,"device":…}
///   POST /v1/session      → {"session_id":"<uuid>"}  (****** required)
///   GET  /v1/session/:id  → {"session_id":…,"created_at":…,"frames":…}
///   DEL  /v1/session/:id  → {"deleted":true}
class ServerConnectionService {
  String baseUrl;
  String token;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  ServerInfo? _serverInfo;
  String? _sessionId;
  Timer? _pollTimer;

  final _statusController = StreamController<ConnectionStatus>.broadcast();
  final _infoController = StreamController<ServerInfo?>.broadcast();

  Stream<ConnectionStatus> get statusStream => _statusController.stream;
  Stream<ServerInfo?> get serverInfoStream => _infoController.stream;

  ConnectionStatus get status => _status;
  ServerInfo? get serverInfo => _serverInfo;
  String? get sessionId => _sessionId;

  ServerConnectionService({required this.baseUrl, required this.token});

  // -----------------------------------------------------------------------
  // Public API
  // -----------------------------------------------------------------------

  /// Start a polling search for the configured server.
  void startSearch() {
    _updateStatus(ConnectionStatus.searching);
    _poll();
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  /// Stop polling without disconnecting an active session.
  void stopSearch() {
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Connect: create a server session.
  Future<bool> connect() async {
    _updateStatus(ConnectionStatus.connecting);
    try {
      final resp = await http
          .post(
            Uri.parse('$baseUrl/v1/session'),
            headers: _authHeaders(),
          )
          .timeout(const Duration(seconds: 10));
      if (resp.statusCode == 200) {
        final data = json.decode(resp.body) as Map<String, dynamic>;
        _sessionId = data['session_id'] as String?;
        _updateStatus(ConnectionStatus.connected);
        return true;
      }
    } catch (_) {}
    _updateStatus(ConnectionStatus.failed);
    return false;
  }

  /// Disconnect: delete the active session.
  Future<void> disconnect() async {
    final id = _sessionId;
    _sessionId = null;
    if (id != null) {
      try {
        await http
            .delete(
              Uri.parse('$baseUrl/v1/session/$id'),
              headers: _authHeaders(),
            )
            .timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    _updateStatus(ConnectionStatus.disconnected);
  }

  void dispose() {
    _pollTimer?.cancel();
    _statusController.close();
    _infoController.close();
  }

  // -----------------------------------------------------------------------
  // Internals
  // -----------------------------------------------------------------------

  Future<void> _poll() async {
    try {
      final resp = await http
          .get(Uri.parse('$baseUrl/v1/info'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final info =
            ServerInfo.fromJson(json.decode(resp.body) as Map<String, dynamic>);
        _serverInfo = info;
        _infoController.add(info);
        if (_status == ConnectionStatus.searching) {
          // Server found – stay on searching so user can explicitly connect
          _updateStatus(ConnectionStatus.searching);
        }
        return;
      }
    } catch (_) {}
    // Could not reach server
    if (_status == ConnectionStatus.searching ||
        _status == ConnectionStatus.connected) {
      _serverInfo = null;
      _infoController.add(null);
      if (_status == ConnectionStatus.connected) {
        _sessionId = null;
        _updateStatus(ConnectionStatus.failed);
      }
    }
  }

  void _updateStatus(ConnectionStatus s) {
    _status = s;
    _statusController.add(s);
  }

  Map<String, String> _authHeaders() {
    final scheme = 'Bearer';
    return {
      'Authorization': '$scheme $token',
      'Content-Type': 'application/json',
    };
  }
}
