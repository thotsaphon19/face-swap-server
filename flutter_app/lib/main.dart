import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'connection_screen.dart';
import 'ws_service.dart';



/// Converts CameraImage buffers to an upright JPEG off the UI isolate.
/// The payload only contains primitive values and byte arrays, so it is safe
/// to pass through compute(). Android uses YUV420; iOS uses BGRA8888.
Uint8List? _encodeCameraFrame(Map<String, dynamic> payload) {
  final width = payload['width'] as int;
  final height = payload['height'] as int;
  final format = payload['format'] as String;
  final quality = payload['quality'] as int;
  final rotation = payload['rotation'] as int;
  final mirror = payload['mirror'] as bool;
  final maxLongEdge = payload['maxLongEdge'] as int;
  final planes = (payload['planes'] as List).cast<Map<String, dynamic>>();

  img.Image? frame;
  if (format == 'yuv420' && planes.length >= 3) {
    frame = img.Image(width: width, height: height);
    final y = planes[0];
    final u = planes[1];
    final v = planes[2];
    final yBytes = y['bytes'] as Uint8List;
    final uBytes = u['bytes'] as Uint8List;
    final vBytes = v['bytes'] as Uint8List;
    final yRow = y['rowStride'] as int;
    final uRow = u['rowStride'] as int;
    final vRow = v['rowStride'] as int;
    final yPix = y['pixelStride'] as int;
    final uPix = u['pixelStride'] as int;
    final vPix = v['pixelStride'] as int;

    for (var py = 0; py < height; py++) {
      final uvY = py >> 1;
      for (var px = 0; px < width; px++) {
        final uvX = px >> 1;
        final yi = py * yRow + px * yPix;
        final ui = uvY * uRow + uvX * uPix;
        final vi = uvY * vRow + uvX * vPix;
        if (yi >= yBytes.length || ui >= uBytes.length || vi >= vBytes.length) {
          continue;
        }
        final yy = yBytes[yi].toDouble();
        final uu = uBytes[ui].toDouble() - 128.0;
        final vv = vBytes[vi].toDouble() - 128.0;
        final r = (yy + 1.402 * vv).round().clamp(0, 255);
        final g = (yy - 0.344136 * uu - 0.714136 * vv).round().clamp(0, 255);
        final b = (yy + 1.772 * uu).round().clamp(0, 255);
        frame.setPixelRgba(px, py, r, g, b, 255);
      }
    }
  } else if (format == 'bgra8888' && planes.isNotEmpty) {
    final plane = planes.first;
    final bytes = plane['bytes'] as Uint8List;
    final row = plane['rowStride'] as int;
    final pix = plane['pixelStride'] as int;
    frame = img.Image(width: width, height: height);
    for (var py = 0; py < height; py++) {
      for (var px = 0; px < width; px++) {
        final i = py * row + px * pix;
        if (i + 3 >= bytes.length) continue;
        frame.setPixelRgba(px, py, bytes[i + 2], bytes[i + 1], bytes[i], bytes[i + 3]);
      }
    }
  }

  if (frame == null) return null;
  if (rotation != 0) frame = img.copyRotate(frame, angle: rotation.toDouble());
  if (mirror) frame = img.flipHorizontal(frame);
  final longEdge = frame.width > frame.height ? frame.width : frame.height;
  if (longEdge > maxLongEdge) {
    final scale = maxLongEdge / longEdge;
    frame = img.copyResize(
      frame,
      width: (frame.width * scale).round(),
      height: (frame.height * scale).round(),
      interpolation: img.Interpolation.linear,
    );
  }
  return Uint8List.fromList(img.encodeJpg(frame, quality: quality));
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final cameras = await availableCameras();
  runApp(FaceSwapApp(cameras: cameras));
}

class FaceSwapApp extends StatelessWidget {
  final List<CameraDescription> cameras;
  const FaceSwapApp({super.key, required this.cameras});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'FaceSwap Cam',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A84FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      // Show connection screen first; navigate to camera stream after connect.
      home: _Root(cameras: cameras),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Root widget that wires ConnectionScreen → CameraStreamPage navigation.
// ─────────────────────────────────────────────────────────────────────────────
class _Root extends StatelessWidget {
  final List<CameraDescription> cameras;
  const _Root({required this.cameras});

  @override
  Widget build(BuildContext context) {
    return ConnectionScreen(
      onConnected: (wsUrl, token) {
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => CameraStreamPage(
              cameras: cameras,
              wsUrl: wsUrl,
              token: token,
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class CameraStreamPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  final String wsUrl;
  final String token;
  const CameraStreamPage({
    super.key,
    required this.cameras,
    required this.wsUrl,
    required this.token,
  });

  @override
  State<CameraStreamPage> createState() => _CameraStreamPageState();
}

class _CameraStreamPageState extends State<CameraStreamPage>
    with WidgetsBindingObserver {
  // ── Camera ──────────────────────────────────────────────────────────────
  CameraController? _controller;
  int _cameraIndex = 0;
  bool _cameraReady = false;

  // ── WS / streaming ──────────────────────────────────────────────────────
  WsService? _ws;
  bool _wsConnected = false;
  bool _streaming = false;
  bool _pendingFrame = false;
  bool _encodingFrame = false;
  String? _sessionId;

  // ── Result image ─────────────────────────────────────────────────────────
  Uint8List? _resultBytes;
  Uint8List? _sourceBytes;
  bool _sourceReady = false;
  final ImagePicker _imagePicker = ImagePicker();

  // ── Stats ────────────────────────────────────────────────────────────────
  int _sentFrames = 0;
  int _recvFrames = 0;
  double _latencyMs = 0;
  double _smoothedLatencyMs = 0;
  DateTime? _lastSentAt;
  DateTime? _lastCaptureAt;
  Timer? _frameTimeoutTimer;
  int _droppedFrames = 0;
  double _encodeMs = 0;
  double _serverProcessMs = 0;

  // ── Settings (editable in-app) ────────────────────────────────────────────
  late String _wsUrl;
  late String _token;
  int _fps = 12;
  ResolutionPreset _resolution = ResolutionPreset.medium;

  late final TextEditingController _wsUrlCtrl;
  late final TextEditingController _tokenCtrl;

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _wsUrl = widget.wsUrl;
    _token = widget.token;
    _wsUrlCtrl = TextEditingController(text: _wsUrl);
    _tokenCtrl = TextEditingController(text: _token);
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs().then((_) {
      _connectWs();
      _startCamera();
    });
    WakelockPlus.enable();
  }


  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _fps = prefs.getInt('fps') ?? _fps;
    });
  }

  Future<void> _savePrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('wsUrl', _wsUrl);
    await prefs.setString('token', _token);
    await prefs.setInt('fps', _fps);
  }

  // ── Camera ─────────────────────────────────────────────────────────────
  Future<void> _startCamera() async {
    if (widget.cameras.isEmpty) return;
    final status = await Permission.camera.request();
    if (!status.isGranted) {
      _showSnack('Camera permission denied');
      return;
    }

    await _controller?.dispose();
    final cam = widget.cameras[_cameraIndex % widget.cameras.length];
    final ctrl = CameraController(
      cam,
      _resolution,
      enableAudio: false,
      imageFormatGroup: Platform.isIOS
          ? ImageFormatGroup.bgra8888
          : ImageFormatGroup.yuv420,
    );
    try {
      await ctrl.initialize();
    } catch (e) {
      _showSnack('Camera init error: $e');
      return;
    }
    if (!mounted) return;
    setState(() {
      _controller = ctrl;
      _cameraReady = true;
    });
  }

  Future<void> _flipCamera() async {
    if (widget.cameras.length < 2) return;
    _cameraIndex = (_cameraIndex + 1) % widget.cameras.length;
    await _startCamera();
  }

  // ── WebSocket ─────────────────────────────────────────────────────────
  void _connectWs() {
    _ws?.disconnect();

    final parsed = Uri.parse(_wsUrl);
    final params = Map<String, String>.from(parsed.queryParameters);
    params['token'] = _token;
    _sessionId = params['session_id'];
    final urlWithToken = parsed.replace(queryParameters: params).toString();

    final svc = WsService(
      url: urlWithToken,
      autoReconnect: true,
      reconnectDelay: const Duration(seconds: 3),
    );
    svc.onBinaryFrame = (bytes) {
      _frameTimeoutTimer?.cancel();
      final now = DateTime.now();
      if (_lastSentAt != null) {
        _latencyMs = now.difference(_lastSentAt!).inMilliseconds.toDouble();
        _smoothedLatencyMs = _smoothedLatencyMs == 0
            ? _latencyMs
            : (_smoothedLatencyMs * 0.8) + (_latencyMs * 0.2);
      }
      setState(() {
        _resultBytes = bytes;
        _recvFrames++;
        _pendingFrame = false;
      });
    };
    svc.onText = (message) {
      try {
        final data = jsonDecode(message);
        if (data is Map && data['type'] == 'source_face_ready') {
          if (mounted) setState(() => _sourceReady = true);
          _showSnack('Source face ready');
        } else if (data is Map && data['type'] == 'frame_meta') {
          final value = (data['process_ms'] as num?)?.toDouble() ?? 0;
          if (mounted) setState(() {
            _serverProcessMs = _serverProcessMs == 0 ? value : (_serverProcessMs * 0.8 + value * 0.2);
          });
        } else if (data is Map && data['type'] == 'error') {
          _showSnack('Server: ${data['error']}');
        }
      } catch (_) {}
    };
    svc.onError = (msg) => _showSnack('WS: $msg');
    svc.onConnectionChange = (connected) {
      if (!mounted) return;
      setState(() {
        _wsConnected = connected;
        if (!connected) {
          _pendingFrame = false;
          _frameTimeoutTimer?.cancel();
        }
      });
      // A reconnect may create a new upstream socket. Re-send the source face
      // automatically so the stream can recover without user interaction.
      if (connected && _sourceBytes != null) {
        final payload = jsonEncode({
          'type': 'source_face',
          'session_id': _sessionId,
          'image_base64': base64Encode(_sourceBytes!),
        });
        svc.sendText(payload);
      }
    };
    setState(() {
      _ws = svc;
      _wsConnected = false;
    });
    svc.connect();
  }

  void _disconnectWs() {
    _frameTimeoutTimer?.cancel();
    _stopStream();
    _ws?.disconnect();
    setState(() {
      _ws = null;
      _wsConnected = false;
    });
  }

  Future<void> _pickSourceFace() async {
    if (_ws == null || !_wsConnected) {
      _showSnack('Connect to the server first');
      return;
    }
    final file = await _imagePicker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1200,
      imageQuality: 90,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    final payload = jsonEncode({
      'type': 'source_face',
      'session_id': _sessionId,
      'image_base64': base64Encode(bytes),
    });
    _ws?.sendText(payload);
    if (mounted) setState(() {
      _sourceBytes = bytes;
      _sourceReady = false;
    });
  }

  // ── Streaming loop ────────────────────────────────────────────────────
  void _startStream() {
    if (_ws == null || !_cameraReady || _controller == null) return;
    if (!_sourceReady) {
      _showSnack('Select a source face first');
      return;
    }
    setState(() {
      _streaming = true;
      _pendingFrame = false;
    });

    _controller!.startImageStream((CameraImage image) async {
      if (!_streaming || !_wsConnected) return;
      if (_pendingFrame || _encodingFrame) {
        _droppedFrames++;
        return;
      }
      final now = DateTime.now();
      // Adaptive capture rate: protect latency first.  A lower fresh-frame rate
      // looks better in a call than 30 stale frames queued behind the GPU.
      final effectiveFps = _smoothedLatencyMs > 260
          ? 6
          : (_smoothedLatencyMs > 180 ? 8 : (_smoothedLatencyMs > 120 ? 10 : _fps));
      final intervalMs = (1000 / effectiveFps.clamp(4, _fps)).round();
      if (_lastCaptureAt != null &&
          now.difference(_lastCaptureAt!).inMilliseconds < intervalMs) return;
      _lastCaptureAt = now;
      _encodingFrame = true;
      final encodeStarted = DateTime.now();
      try {
        // Prefer latency over frame count. When RTT rises, lower JPEG quality
        // instead of building a queue of stale frames.
        final quality = _smoothedLatencyMs > 220
            ? 55
            : (_smoothedLatencyMs > 150 ? 62 : 70);
        final cam = widget.cameras[_cameraIndex % widget.cameras.length];
        var rotation = cam.sensorOrientation % 360;
        if (Platform.isIOS) rotation = 0;
        final format = image.format.group == ImageFormatGroup.bgra8888
            ? 'bgra8888'
            : 'yuv420';
        final payload = <String, dynamic>{
          'width': image.width,
          'height': image.height,
          'format': format,
          'quality': quality,
          'rotation': rotation,
          // CameraPreview already mirrors the front camera. Mirror the encoded
          // frame as well so the processed result matches what the user sees.
          'mirror': cam.lensDirection == CameraLensDirection.front,
          'maxLongEdge': _smoothedLatencyMs > 220 ? 512 : (_smoothedLatencyMs > 140 ? 640 : 720),
          'planes': image.planes
              .map((p) => <String, dynamic>{
                    'bytes': Uint8List.fromList(p.bytes),
                    'rowStride': p.bytesPerRow,
                    'pixelStride': p.bytesPerPixel ?? 1,
                  })
              .toList(growable: false),
        };
        final jpegBytes = await compute(_encodeCameraFrame, payload);
        final encodeElapsed = DateTime.now().difference(encodeStarted).inMicroseconds / 1000.0;
        _encodeMs = _encodeMs == 0 ? encodeElapsed : (_encodeMs * 0.8 + encodeElapsed * 0.2);
        if (!_streaming || !_wsConnected || jpegBytes == null) return;
        _ws?.sendBytes(jpegBytes);
        _lastSentAt = DateTime.now();
        if (mounted) {
          setState(() {
            _pendingFrame = true;
            _sentFrames++;
          });
        }
        _frameTimeoutTimer?.cancel();
        _frameTimeoutTimer = Timer(const Duration(milliseconds: 1400), () {
          if (!_pendingFrame || !_streaming) return;
          // A frame older than this is useless for lip-sync. Drop the socket
          // and rebuild the upstream path instead of allowing stale video to
          // accumulate.
          _pendingFrame = false;
          _ws?.reconnectNow();
        });
      } finally {
        _encodingFrame = false;
      }
    });
  }

  void _stopStream() {
    _frameTimeoutTimer?.cancel();
    _frameTimeoutTimer = null;
    setState(() {
      _streaming = false;
      _pendingFrame = false;
      _encodingFrame = false;
    });
    try {
      _controller?.stopImageStream();
    } catch (_) {}
  }

  Future<void> _copyDesktopViewerUrl() async {
    final sid = _sessionId;
    if (sid == null || sid.isEmpty) {
      _showSnack('Session is not ready yet');
      return;
    }
    final ws = Uri.parse(_wsUrl);
    final scheme = ws.scheme == 'wss' ? 'https' : 'http';
    final viewer = ws.replace(
      scheme: scheme,
      path: '/viewer',
      queryParameters: {'session_id': sid, 'token': _token},
    );
    await Clipboard.setData(ClipboardData(text: viewer.toString()));
    _showSnack('OBS/Desktop viewer URL copied');
  }

  // ── Settings sheet ────────────────────────────────────────────────────
  void _openSettings() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => _SettingsSheet(
        wsUrlCtrl: _wsUrlCtrl,
        tokenCtrl: _tokenCtrl,
        fps: _fps,
        resolution: _resolution,
        onSave: (fps, res) async {
          _wsUrl = _wsUrlCtrl.text.trim();
          _token = _tokenCtrl.text.trim();
          setState(() {
            _fps = fps;
            _resolution = res;
          });
          await _savePrefs();
          if (mounted) Navigator.of(ctx).pop();
          _connectWs();
          await _startCamera();
        },
      ),
    );
  }

  // ── UI helpers ────────────────────────────────────────────────────────
  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _stopStream();
      _controller?.dispose();
      setState(() => _cameraReady = false);
    } else if (state == AppLifecycleState.resumed) {
      _startCamera();
      if (_ws == null || !_wsConnected) {
        _connectWs();
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _frameTimeoutTimer?.cancel();
    _stopStream();
    _ws?.disconnect();
    _controller?.dispose();
    _wsUrlCtrl.dispose();
    _tokenCtrl.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: Colors.white),
          tooltip: 'Disconnect',
          onPressed: () {
            _disconnectWs();
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                builder: (_) => ConnectionScreen(
                  onConnected: (wsUrl, token) {
                    Navigator.of(context).pushReplacement(
                      MaterialPageRoute(
                        builder: (_) => CameraStreamPage(
                          cameras: widget.cameras,
                          wsUrl: wsUrl,
                          token: token,
                        ),
                      ),
                    );
                  },
                ),
              ),
            );
          },
        ),
        title: const Text('FaceSwap Cam',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            tooltip: 'Copy OBS / Desktop viewer URL',
            icon: const Icon(Icons.desktop_windows, color: Colors.white),
            onPressed: _copyDesktopViewerUrl,
          ),
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Reconnecting banner ───────────────────────────────────────
          if (!_wsConnected && _ws != null)
            Container(
              color: Colors.orange.shade900,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: const Row(
                children: [
                  SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white),
                  ),
                  SizedBox(width: 10),
                  Text('Reconnecting to server…',
                      style: TextStyle(color: Colors.white, fontSize: 13)),
                ],
              ),
            ),

          // ── Dual preview ──────────────────────────────────────────────
          Expanded(
            flex: 5,
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_cameraReady && _controller != null)
                          Transform(
                            alignment: Alignment.center,
                            transform: Matrix4.identity()
                              ..scale(widget.cameras[_cameraIndex].lensDirection == CameraLensDirection.front ? -1.0 : 1.0, 1.0, 1.0),
                            child: ClipRect(
                              child: FittedBox(
                              fit: BoxFit.cover,
                              child: SizedBox(
                                width: _controller!.value.previewSize?.height ??
                                    640,
                                height: _controller!.value.previewSize?.width ??
                                    480,
                                child: CameraPreview(_controller!),
                              ),
                            ),
                          ),
                        else
                          const Center(
                              child: CircularProgressIndicator(
                                  color: Colors.white)),
                        const Positioned(
                          top: 8,
                          left: 8,
                          child: _PillLabel('📷 Live'),
                        ),
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Container(
                    color: const Color(0xFF111111),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_resultBytes != null)
                          Image.memory(
                            _resultBytes!,
                            fit: BoxFit.cover,
                            gaplessPlayback: true,
                          )
                        else
                          const Center(
                            child: Text('Result will appear here',
                                style: TextStyle(color: Colors.white54)),
                          ),
                        const Positioned(
                          top: 8,
                          left: 8,
                          child: _PillLabel('🎭 Swapped'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Stats bar ─────────────────────────────────────────────────
          Container(
            color: const Color(0xFF1C1C1E),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Wrap(
              alignment: WrapAlignment.spaceEvenly,
              spacing: 12,
              runSpacing: 4,
              children: [
                _statChip('SRC', _sourceReady ? '● READY' : '○ NONE',
                    _sourceReady ? Colors.greenAccent : Colors.orangeAccent),
                _statChip('WS', _wsConnected ? '● ON' : '○ OFF',
                    _wsConnected ? Colors.greenAccent : Colors.redAccent),
                _statChip('RTT', '${_smoothedLatencyMs.toInt()} ms', Colors.white70),
                _statChip('GPU', '${_serverProcessMs.toInt()} ms', Colors.white70),
                _statChip('ENC', '${_encodeMs.toInt()} ms', Colors.white70),
                _statChip('Drop', '$_droppedFrames', Colors.white70),
                _statChip('FPS', '$_fps max', Colors.white70),
              ],
            ),
          ),

          // ── Control buttons ───────────────────────────────────────────
          Container(
            color: const Color(0xFF1C1C1E),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                _iconBtn(Icons.flip_camera_ios, _flipCamera),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _wsConnected ? Colors.orange : Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _wsConnected ? _disconnectWs : _connectWs,
                    child:
                        Text(_wsConnected ? 'Disconnect' : 'Reconnect'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _streaming ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    onPressed: _wsConnected
                        ? (_streaming ? _stopStream : _startStream)
                        : null,
                    child: Text(_streaming ? 'Stop' : 'Start Stream'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _iconBtn(IconData icon, VoidCallback fn) => InkWell(
        onTap: fn,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF2C2C2E),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white),
        ),
      );

  Widget _statChip(String label, String value, Color color) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label,
              style: const TextStyle(color: Colors.white38, fontSize: 10)),
          Text(value, style: TextStyle(color: color, fontSize: 12)),
        ],
      );
}

// ─────────────────────────────────────────────────────────────────────────────
class _PillLabel extends StatelessWidget {
  final String text;
  const _PillLabel(this.text);
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Text(text,
            style: const TextStyle(color: Colors.white, fontSize: 11)),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
class _SettingsSheet extends StatefulWidget {
  final TextEditingController wsUrlCtrl;
  final TextEditingController tokenCtrl;
  final int fps;
  final ResolutionPreset resolution;
  final void Function(int fps, ResolutionPreset res) onSave;
  const _SettingsSheet({
    required this.wsUrlCtrl,
    required this.tokenCtrl,
    required this.fps,
    required this.resolution,
    required this.onSave,
  });
  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late int _fps;
  late ResolutionPreset _res;

  @override
  void initState() {
    super.initState();
    _fps = widget.fps;
    _res = widget.resolution;
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 16,
          right: 16,
          top: 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Settings', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 12),
          TextField(
            controller: widget.wsUrlCtrl,
            decoration: const InputDecoration(
              labelText: 'WebSocket URL',
              hintText: 'ws://192.168.1.1/ws',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: widget.tokenCtrl,
            decoration: const InputDecoration(
              labelText: 'Auth Token',
              border: OutlineInputBorder(),
            ),
            obscureText: true,
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('FPS:'),
              Expanded(
                child: Slider(
                  min: 1,
                  max: 15,
                  divisions: 14,
                  value: _fps.toDouble(),
                  label: '$_fps',
                  onChanged: (v) => setState(() => _fps = v.round()),
                ),
              ),
              Text('$_fps'),
            ],
          ),
          const SizedBox(height: 4),
          DropdownButtonFormField<ResolutionPreset>(
            value: _res,
            decoration: const InputDecoration(
              labelText: 'Camera Resolution',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                  value: ResolutionPreset.low, child: Text('Low (240p)')),
              DropdownMenuItem(
                  value: ResolutionPreset.medium, child: Text('Medium (480p)')),
              DropdownMenuItem(
                  value: ResolutionPreset.high, child: Text('High (720p)')),
            ],
            onChanged: (v) {
              if (v != null) setState(() => _res = v);
            },
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => widget.onSave(_fps, _res),
              child: const Text('Save & Reconnect'),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
