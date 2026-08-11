import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:web_socket_channel/status.dart' as status;

/// Manages a WebSocket connection to the face-swap backend.
/// Closes cleanly on [disconnect]; callers are responsible for reconnecting
/// if needed (see the Connect/Disconnect buttons in the UI).
class WsService {
  final String url;

  WsService({required this.url});

  WebSocketChannel? _channel;
  StreamSubscription? _sub;

  bool _connected = false;
  bool get isConnected => _connected;

  /// Called with the raw JPEG bytes received from the server.
  void Function(Uint8List bytes)? onBinaryFrame;

  /// Called with a human-readable error string.
  void Function(String message)? onError;

  void connect() {
    try {
      _channel = WebSocketChannel.connect(Uri.parse(url));
      _channel!.ready.then((_) {
        _connected = true;
      }).catchError((e) {
        _connected = false;
        onError?.call('Connect failed: $e');
      });

      _sub = _channel!.stream.listen(
        (data) {
          _connected = true;
          if (data is List<int>) {
            onBinaryFrame?.call(Uint8List.fromList(data));
          } else if (data is Uint8List) {
            onBinaryFrame?.call(data);
          }
          // ignore text frames (errors / pings from server)
        },
        onError: (e) {
          _connected = false;
          onError?.call('WS stream error: $e');
        },
        onDone: () {
          _connected = false;
        },
        cancelOnError: false,
      );
    } catch (e) {
      _connected = false;
      onError?.call('WS connect exception: $e');
    }
  }

  void sendBytes(Uint8List bytes) {
    if (!_connected) return;
    try {
      _channel?.sink.add(bytes);
    } catch (e) {
      _connected = false;
      onError?.call('WS send error: $e');
    }
  }

  void disconnect() {
    _connected = false;
    _sub?.cancel();
    _channel?.sink.close(status.normalClosure);
    _channel = null;
    _sub = null;
  }
}
