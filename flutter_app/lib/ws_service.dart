import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

/// Manages a WebSocket connection to the face-swap backend.
/// Supports optional auto-reconnect when [autoReconnect] is true.
class WsService {
  final String url;
  final bool autoReconnect;
  final Duration reconnectDelay;

  WsService({
    required this.url,
    this.autoReconnect = false,
    this.reconnectDelay = const Duration(seconds: 3),
  });

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  bool _connected = false;
  bool _disposed = false;
  Timer? _reconnectTimer;

  bool get isConnected => _connected;

  /// Called with the raw JPEG bytes received from the server.
  void Function(Uint8List bytes)? onBinaryFrame;

  /// Called with a human-readable error string.
  void Function(String message)? onError;

  /// Called when the connection state changes (connected or disconnected).
  void Function(bool connected)? onConnectionChange;

  void connect() {
    _disposed = false;
    _doConnect();
  }

  void _doConnect() {
    if (_disposed) return;
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel!.ready.then((_) {
        if (_disposed) return;
        _connected = true;
        onConnectionChange?.call(true);
      }).catchError((e) {
        _connected = false;
        onConnectionChange?.call(false);
        onError?.call('Connect failed: $e');
        _scheduleReconnect();
      });

      _sub = _channel!.stream.listen(
        (data) {
          if (!_connected) {
            _connected = true;
            onConnectionChange?.call(true);
          }
          if (data is List<int>) {
            onBinaryFrame?.call(Uint8List.fromList(data));
          } else if (data is Uint8List) {
            onBinaryFrame?.call(data);
          }
        },
        onError: (e) {
          _connected = false;
          onConnectionChange?.call(false);
          onError?.call('WS stream error: $e');
          _scheduleReconnect();
        },
        onDone: () {
          _connected = false;
          onConnectionChange?.call(false);
          _scheduleReconnect();
        },
        cancelOnError: false,
      );
    } catch (e) {
      _connected = false;
      onConnectionChange?.call(false);
      onError?.call('WS connect exception: $e');
      _scheduleReconnect();
    }
  }

  void _scheduleReconnect() {
    if (!autoReconnect || _disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(reconnectDelay, () {
      if (!_disposed) _doConnect();
    });
  }

  void sendBytes(Uint8List bytes) {
    if (!_connected) return;
    try {
      _channel?.sink.add(bytes);
    } catch (e) {
      _connected = false;
      onConnectionChange?.call(false);
      onError?.call('WS send error: $e');
    }
  }

  void disconnect() {
    _disposed = true;
    _connected = false;
    _reconnectTimer?.cancel();
    _reconnectTimer = null;
    _sub?.cancel();
    _channel?.sink.close(status.normalClosure);
    _channel = null;
    _sub = null;
  }
}
