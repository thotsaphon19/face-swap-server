import 'dart:async';
import 'dart:math';
import 'dart:typed_data';

import 'package:web_socket_channel/status.dart' as status;
import 'package:web_socket_channel/web_socket_channel.dart';

/// Resilient WebSocket client for the realtime face-swap stream.
///
/// Design goals:
/// - reconnect automatically after mobile network changes;
/// - send an application heartbeat so dead NAT/proxy connections are detected;
/// - avoid overlapping reconnect attempts;
/// - surface connection state cleanly to the camera pipeline.
class WsService {
  final String url;
  final bool autoReconnect;
  final Duration reconnectDelay;
  final Duration heartbeatInterval;
  final Duration watchdogTimeout;

  WsService({
    required this.url,
    this.autoReconnect = false,
    this.reconnectDelay = const Duration(seconds: 2),
    this.heartbeatInterval = const Duration(seconds: 12),
    this.watchdogTimeout = const Duration(seconds: 35),
  });

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  bool _connected = false;
  bool _disposed = false;
  bool _connecting = false;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  Timer? _watchdogTimer;
  DateTime _lastRx = DateTime.fromMillisecondsSinceEpoch(0);
  int _failureCount = 0;

  bool get isConnected => _connected;

  void Function(Uint8List bytes)? onBinaryFrame;
  void Function(String message)? onText;
  void Function(String message)? onError;
  void Function(bool connected)? onConnectionChange;

  void connect() {
    _disposed = false;
    _reconnectTimer?.cancel();
    _doConnect();
  }

  void _setConnected(bool value) {
    if (_connected == value) return;
    _connected = value;
    onConnectionChange?.call(value);
  }

  Future<void> _doConnect() async {
    if (_disposed || _connecting || _connected) return;
    _connecting = true;
    await _closeTransport(notify: false);
    try {
      final channel = WebSocketChannel.connect(Uri.parse(url));
      _channel = channel;
      await channel.ready.timeout(const Duration(seconds: 8));
      if (_disposed) {
        await channel.sink.close(status.normalClosure);
        return;
      }
      _lastRx = DateTime.now();
      _failureCount = 0;
      _setConnected(true);
      _startHeartbeat();
      _sub = channel.stream.listen(
        (data) {
          _lastRx = DateTime.now();
          if (!_connected) _setConnected(true);
          if (data is Uint8List) {
            onBinaryFrame?.call(data);
          } else if (data is List<int>) {
            onBinaryFrame?.call(Uint8List.fromList(data));
          } else if (data is String) {
            onText?.call(data);
          }
        },
        onError: (e) => _handleTransportFailure('WS stream error: $e'),
        onDone: () => _handleTransportFailure('WebSocket closed'),
        cancelOnError: false,
      );
    } on TimeoutException {
      onError?.call('WebSocket connection timed out');
      await _handleTransportFailure(null);
    } catch (e) {
      onError?.call('Connect failed: $e');
      await _handleTransportFailure(null);
    } finally {
      _connecting = false;
    }
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _watchdogTimer?.cancel();
    _heartbeatTimer = Timer.periodic(heartbeatInterval, (_) {
      if (_connected) sendText('{"type":"ping"}');
    });
    _watchdogTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_connected) return;
      if (DateTime.now().difference(_lastRx) > watchdogTimeout) {
        _handleTransportFailure('Connection watchdog timeout');
      }
    });
  }

  Future<void> _handleTransportFailure(String? message) async {
    if (_disposed) return;
    if (message != null) onError?.call(message);
    _setConnected(false);
    await _closeTransport(notify: false);
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!autoReconnect || _disposed || _connected || _connecting) return;
    _reconnectTimer?.cancel();
    _failureCount = min(_failureCount + 1, 6);
    final baseMs = reconnectDelay.inMilliseconds;
    final shift = (_failureCount - 1).clamp(0, 3).toInt();
    final expMs = min(8000, baseMs * (1 << shift)).toInt();
    final jitterMs = Random().nextInt(250);
    _reconnectTimer = Timer(Duration(milliseconds: expMs + jitterMs), () {
      if (!_disposed) _doConnect();
    });
  }

  Future<void> reconnectNow() async {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _setConnected(false);
    await _closeTransport(notify: false);
    _failureCount = 0;
    _doConnect();
  }

  void sendText(String text) {
    if (!_connected) return;
    try {
      _channel?.sink.add(text);
    } catch (e) {
      _handleTransportFailure('WS send text error: $e');
    }
  }

  void sendBytes(Uint8List bytes) {
    if (!_connected) return;
    try {
      _channel?.sink.add(bytes);
    } catch (e) {
      _handleTransportFailure('WS send error: $e');
    }
  }

  Future<void> _closeTransport({required bool notify}) async {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    _watchdogTimer?.cancel();
    _watchdogTimer = null;
    final sub = _sub;
    final channel = _channel;
    _sub = null;
    _channel = null;
    try {
      await sub?.cancel();
    } catch (_) {}
    try {
      await channel?.sink.close(status.normalClosure);
    } catch (_) {}
    if (notify) _setConnected(false);
  }

  void disconnect() {
    _disposed = true;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _heartbeatTimer?.cancel();
    _watchdogTimer?.cancel();
    _setConnected(false);
    _closeTransport(notify: false);
  }
}
