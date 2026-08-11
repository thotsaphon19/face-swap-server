import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'settings_screen.dart';

enum ServerConnectionState { searching, connected, failed }

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with SingleTickerProviderStateMixin {
  ServerConnectionState _connState = ServerConnectionState.searching;
  String _statusText = 'กำลังหา Face Swap Server...';
  String _backendUrl = '';
  late AnimationController _pulseController;
  Timer? _searchTimer;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _loadUrlAndSearch();
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _searchTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadUrlAndSearch() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString('backend_url') ?? '';
    setState(() {
      _backendUrl = url;
      _connState = ServerConnectionState.searching;
      _statusText = 'กำลังหา Face Swap Server...';
    });
    _startSearch();
  }

  void _startSearch() {
    _searchTimer?.cancel();
    _doConnect();
    _searchTimer = Timer.periodic(const Duration(seconds: 8), (_) {
      if (_connState != ServerConnectionState.connected) _doConnect();
    });
  }

  Future<void> _doConnect() async {
    if (_backendUrl.isEmpty) {
      setState(() {
        _connState = ServerConnectionState.failed;
        _statusText = 'ยังไม่ได้ตั้ง Backend URL\nกดไอคอนเฟืองเพื่อตั้งค่า';
      });
      return;
    }

    setState(() {
      _connState = ServerConnectionState.searching;
      _statusText = 'กำลังเชื่อมต่อ $_backendUrl ...';
    });

    try {
      final uri = Uri.parse('${_backendUrl.trimRight()}/connect');
      final response = await http
          .get(uri)
          .timeout(const Duration(seconds: 6));
      if (response.statusCode == 200) {
        setState(() {
          _connState = ServerConnectionState.connected;
          _statusText = 'เชื่อมต่อสำเร็จ\n$_backendUrl';
        });
        _searchTimer?.cancel();
      } else {
        _setFailed();
      }
    } catch (_) {
      _setFailed();
    }
  }

  void _setFailed() {
    setState(() {
      _connState = ServerConnectionState.failed;
      _statusText = 'ไม่พบ Server\nตรวจสอบ URL หรือกด Refresh';
    });
  }

  void _onRefresh() => _doConnect();

  void _onAdd() => _openSettings();

  void _onHelp() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('วิธีใช้'),
        content: const Text(
          '1. กดไอคอนเฟือง (⚙) เพื่อตั้ง Backend URL\n'
          '   ตัวอย่าง: http://168.144.110.89\n\n'
          '2. แอปจะค้นหา Server อัตโนมัติ\n\n'
          '3. เมื่อเชื่อมต่อสำเร็จ ระบบพร้อมรับ WebSocket\n'
          '   ที่ path /ws?token=<SECRET_TOKEN>',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('ปิด'),
          ),
        ],
      ),
    );
  }

  Future<void> _openSettings() async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => SettingsScreen(
          currentUrl: _backendUrl,
          onSave: (url) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setString('backend_url', url);
            setState(() => _backendUrl = url);
            _startSearch();
          },
        ),
      ),
    );
  }

  Color get _ringColor {
    switch (_connState) {
      case ServerConnectionState.connected:
        return const Color(0xFF42A5F5);
      case ServerConnectionState.failed:
        return const Color(0xFFEF5350);
      case ServerConnectionState.searching:
        return const Color(0xFF1565C0);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D1A),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings, color: Colors.white70),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: _ConcentricRingsWidget(
                pulseController: _pulseController,
                ringColor: _ringColor,
                connState: _connState,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24.0),
            child: Text(
              _statusText,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
          ),
          const SizedBox(height: 24),
          const Icon(Icons.computer, size: 48, color: Colors.white24),
          const SizedBox(height: 8),
          const Text(
            'Face Swap Server',
            style: TextStyle(color: Colors.white38, fontSize: 12),
          ),
          const SizedBox(height: 32),
          _BottomBar(
            onRefresh: _onRefresh,
            onAdd: _onAdd,
            onHelp: _onHelp,
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

class _ConcentricRingsWidget extends StatelessWidget {
  const _ConcentricRingsWidget({
    required this.pulseController,
    required this.ringColor,
    required this.connState,
  });

  final AnimationController pulseController;
  final Color ringColor;
  final ServerConnectionState connState;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: pulseController,
      builder: (_, __) {
        final t = pulseController.value;
        return SizedBox(
          width: 280,
          height: 280,
          child: Stack(
            alignment: Alignment.center,
            children: [
              for (int i = 3; i >= 1; i--)
                _Ring(
                  radius: 50.0 + i * 40,
                  color: ringColor.withOpacity(
                    connState == ServerConnectionState.searching
                        ? (0.15 + 0.1 * ((t + i * 0.3) % 1.0))
                        : 0.18,
                  ),
                ),
              Container(
                width: 80,
                height: 80,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: ringColor.withOpacity(0.15),
                  border: Border.all(color: ringColor, width: 2),
                ),
                child: Icon(
                  connState == ServerConnectionState.connected
                      ? Icons.check
                      : connState == ServerConnectionState.failed
                          ? Icons.close
                          : Icons.phone_android,
                  color: ringColor,
                  size: 36,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _Ring extends StatelessWidget {
  const _Ring({required this.radius, required this.color});
  final double radius;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: radius * 2,
      height: radius * 2,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(color: color, width: 1.5),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.onRefresh,
    required this.onAdd,
    required this.onHelp,
  });

  final VoidCallback onRefresh;
  final VoidCallback onAdd;
  final VoidCallback onHelp;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _BarButton(icon: Icons.refresh, label: 'Refresh', onTap: onRefresh),
        _BarButton(icon: Icons.add_circle_outline, label: 'Add', onTap: onAdd),
        _BarButton(icon: Icons.help_outline, label: 'Help', onTap: onHelp),
      ],
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Icon(icon, color: Colors.white60, size: 28),
          const SizedBox(height: 4),
          Text(label, style: const TextStyle(color: Colors.white38, fontSize: 11)),
        ],
      ),
    );
  }
}
