import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import 'ws_service.dart';

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
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF0A84FF),
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      home: CameraStreamPage(cameras: cameras),
    );
  }
}

class CameraStreamPage extends StatefulWidget {
  final List<CameraDescription> cameras;
  const CameraStreamPage({super.key, required this.cameras});

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
  bool _streaming = false;
  bool _pendingFrame = false;

  // ── Result image ─────────────────────────────────────────────────────────
  Uint8List? _resultBytes;

  // ── Stats ────────────────────────────────────────────────────────────────
  int _sentFrames = 0;
  int _recvFrames = 0;
  double _latencyMs = 0;
  DateTime? _lastSentAt;

  // ── Settings ─────────────────────────────────────────────────────────────
  String _wsUrl = 'ws://YOUR_SERVER_IP/ws';
  String _token = '';  // Set your server SECRET_TOKEN in Settings before connecting
  int _fps = 8;
  ResolutionPreset _resolution = ResolutionPreset.medium;

  final TextEditingController _wsUrlCtrl = TextEditingController();
  final TextEditingController _tokenCtrl = TextEditingController();

  // ─────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadPrefs().then((_) => _startCamera());
    WakelockPlus.enable();
  }

  Future<void> _loadPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _wsUrl = prefs.getString('wsUrl') ?? _wsUrl;
      _token = prefs.getString('token') ?? _token;
      _fps = prefs.getInt('fps') ?? _fps;
    });
    _wsUrlCtrl.text = _wsUrl;
    _tokenCtrl.text = _token;
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
      imageFormatGroup: ImageFormatGroup.jpeg,
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
    if (_ws != null) {
      _ws!.disconnect();
      _ws = null;
    }

    final urlWithToken = _wsUrl.contains('?')
        ? '$_wsUrl&token=${Uri.encodeComponent(_token)}'
        : '$_wsUrl?token=${Uri.encodeComponent(_token)}';

    final svc = WsService(url: urlWithToken);
    svc.onBinaryFrame = (bytes) {
      final now = DateTime.now();
      if (_lastSentAt != null) {
        _latencyMs = now.difference(_lastSentAt!).inMilliseconds.toDouble();
      }
      setState(() {
        _resultBytes = bytes;
        _recvFrames++;
        _pendingFrame = false;
      });
    };
    svc.onError = (msg) => _showSnack('WS error: $msg');
    svc.connect();
    setState(() => _ws = svc);
  }

  void _disconnectWs() {
    _stopStream();
    _ws?.disconnect();
    setState(() => _ws = null);
  }

  // ── Streaming loop ────────────────────────────────────────────────────
  void _startStream() {
    if (_ws == null || !_cameraReady || _controller == null) return;
    setState(() {
      _streaming = true;
      _pendingFrame = false;
    });

    _controller!.startImageStream((CameraImage image) {
      if (!_streaming || _pendingFrame) return;
      // CameraImage with ImageFormatGroup.jpeg has JPEG bytes in plane[0]
      final Uint8List? jpegBytes = _extractJpeg(image);
      if (jpegBytes == null) return;
      _ws?.sendBytes(jpegBytes);
      _lastSentAt = DateTime.now();
      setState(() {
        _pendingFrame = true;
        _sentFrames++;
      });
    });
  }

  /// Extract JPEG bytes from a [CameraImage].
  /// When [ImageFormatGroup.jpeg] is set, plane 0 holds the full JPEG.
  Uint8List? _extractJpeg(CameraImage image) {
    if (image.planes.isEmpty) return null;
    final plane = image.planes.first;
    // plane.bytes is already JPEG when imageFormatGroup is jpeg
    return Uint8List.fromList(plane.bytes);
  }

  void _stopStream() {
    setState(() {
      _streaming = false;
      _pendingFrame = false;
    });
    try {
      _controller?.stopImageStream();
    } catch (_) {
      // Ignore if stream was not active
    }
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
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopStream();
    _ws?.disconnect();
    _controller?.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final wsConnected = _ws?.isConnected ?? false;

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        title: const Text('FaceSwap Cam',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          // ── Dual preview ──────────────────────────────────────────────
          Expanded(
            flex: 5,
            child: Row(
              children: [
                // Local camera
                Expanded(
                  child: Container(
                    color: Colors.black,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (_cameraReady && _controller != null)
                          ClipRect(
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
                          )
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
                // Face-swap result
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
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _statChip('WS', wsConnected ? '● ON' : '○ OFF',
                    wsConnected ? Colors.greenAccent : Colors.redAccent),
                _statChip('Sent', '$_sentFrames', Colors.white70),
                _statChip('Recv', '$_recvFrames', Colors.white70),
                _statChip('RTT', '${_latencyMs.toInt()} ms', Colors.white70),
                _statChip('FPS', '$_fps', Colors.white70),
              ],
            ),
          ),

          // ── Control buttons ───────────────────────────────────────────
          Container(
            color: const Color(0xFF1C1C1E),
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
            child: Row(
              children: [
                // Flip camera
                _iconBtn(Icons.flip_camera_ios, _flipCamera),
                const SizedBox(width: 8),
                // Connect / Disconnect
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          wsConnected ? Colors.orange : Colors.blue,
                      foregroundColor: Colors.white,
                    ),
                    onPressed:
                        wsConnected ? _disconnectWs : _connectWs,
                    child:
                        Text(wsConnected ? 'Disconnect' : 'Connect Server'),
                  ),
                ),
                const SizedBox(width: 8),
                // Start / Stop stream
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor:
                          _streaming ? Colors.red : Colors.green,
                      foregroundColor: Colors.white,
                    ),
                    onPressed:
                        wsConnected ? (_streaming ? _stopStream : _startStream) : null,
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
          Text('Settings',
              style: Theme.of(context).textTheme.titleLarge),
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
                  value: ResolutionPreset.low,
                  child: Text('Low (240p)')),
              DropdownMenuItem(
                  value: ResolutionPreset.medium,
                  child: Text('Medium (480p)')),
              DropdownMenuItem(
                  value: ResolutionPreset.high,
                  child: Text('High (720p)')),
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
              child: const Text('Save & Reconnect Camera'),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }
}
