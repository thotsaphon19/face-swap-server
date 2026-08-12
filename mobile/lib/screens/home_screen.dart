import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/server_connection_service.dart';
import 'settings_screen.dart';

/// iVCam-style home screen
class HomeScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const HomeScreen({super.key, required this.prefs});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with TickerProviderStateMixin {
  late ServerConnectionService _svc;
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  ConnectionStatus _status = ConnectionStatus.disconnected;
  ServerInfo? _serverInfo;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _pulseAnim = Tween<double>(begin: 0.85, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut),
    );

    _initService();
  }

  Future<void> _initService() async {
    final settings = await loadSettings(widget.prefs);
    _svc = ServerConnectionService(
      baseUrl: settings.baseUrl,
      token: settings.token,
    );
    _svc.statusStream.listen((s) {
      if (mounted) setState(() => _status = s);
    });
    _svc.serverInfoStream.listen((info) {
      if (mounted) setState(() => _serverInfo = info);
    });
    _svc.startSearch();
  }

  Future<void> _reinitService() async {
    _svc.dispose();
    await _initService();
  }

  @override
  void dispose() {
    _svc.dispose();
    _pulseCtrl.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------------
  // Actions
  // -----------------------------------------------------------------------

  void _onRefresh() {
    setState(() => _serverInfo = null);
    _svc.stopSearch();
    _svc.startSearch();
  }

  Future<void> _onConnect() async {
    if (_status == ConnectionStatus.connected) {
      await _svc.disconnect();
    } else {
      await _svc.connect();
    }
  }

  Future<void> _openSettings() async {
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
          builder: (_) => SettingsScreen(prefs: widget.prefs)),
    );
    if (changed == true && mounted) {
      await _reinitService();
    }
  }

  void _onHelp() {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: const Color(0xFF1A2A3A),
        title: const Text('Help', style: TextStyle(color: Colors.white)),
        content: const Text(
          '1. Ensure the face-swap-server is running on your network.\n'
          '2. Tap the settings icon (top-right) to enter the server URL and token.\n'
          '3. Tap Refresh to search for the server.\n'
          '4. Tap the phone icon to connect/disconnect.',
          style: TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK', style: TextStyle(color: Color(0xFF42A5F5))),
          )
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // UI helpers
  // -----------------------------------------------------------------------

  String get _statusLabel {
    switch (_status) {
      case ConnectionStatus.searching:
        return 'Searching for server…';
      case ConnectionStatus.connecting:
        return 'Connecting…';
      case ConnectionStatus.connected:
        return 'Connected  ✓';
      case ConnectionStatus.failed:
        return 'Connection failed — tap Refresh';
      case ConnectionStatus.disconnected:
        return 'Not connected';
    }
  }

  Color get _statusColor {
    switch (_status) {
      case ConnectionStatus.connected:
        return const Color(0xFF66BB6A);
      case ConnectionStatus.failed:
        return const Color(0xFFEF5350);
      default:
        return const Color(0xFF42A5F5);
    }
  }

  bool get _isSearching =>
      _status == ConnectionStatus.searching ||
      _status == ConnectionStatus.connecting;

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;

    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      body: SafeArea(
        child: Stack(
          children: [
            // ── Top bar ──────────────────────────────────────────────────
            Positioned(
              top: 8,
              right: 12,
              child: IconButton(
                icon: const Icon(Icons.settings, color: Colors.white70),
                onPressed: _openSettings,
                tooltip: 'Settings',
              ),
            ),

            // ── Main content ─────────────────────────────────────────────
            Column(
              children: [
                const SizedBox(height: 16),
                // Server address / IP chip
                _ServerAddressChip(
                  info: _serverInfo,
                  status: _status,
                ),
                const SizedBox(height: 8),

                // Concentric circles + phone icon (center area)
                Expanded(
                  child: Center(
                    child: GestureDetector(
                      onTap: _onConnect,
                      child: _ConcentricCircles(
                        pulseAnim: _pulseAnim,
                        isSearching: _isSearching,
                        status: _status,
                      ),
                    ),
                  ),
                ),

                // Laptop illustration
                _LaptopIllustration(connected: _status == ConnectionStatus.connected),
                const SizedBox(height: 8),

                // Status text
                Text(
                  _statusLabel,
                  style: TextStyle(
                    color: _statusColor,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 4),

                // Connect button
                if (_serverInfo != null ||
                    _status == ConnectionStatus.connected)
                  TextButton(
                    onPressed: _onConnect,
                    child: Text(
                      _status == ConnectionStatus.connected
                          ? 'Disconnect'
                          : 'Connect',
                      style: const TextStyle(
                          color: Color(0xFF42A5F5), fontSize: 15),
                    ),
                  ),
                const SizedBox(height: 12),

                // Bottom action bar
                _BottomActionBar(
                  onRefresh: _onRefresh,
                  onAdd: _openSettings,
                  onHelp: _onHelp,
                ),
                SizedBox(height: size.height * 0.02),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sub-widgets
// ---------------------------------------------------------------------------

class _ServerAddressChip extends StatelessWidget {
  final ServerInfo? info;
  final ConnectionStatus status;
  const _ServerAddressChip({required this.info, required this.status});

  @override
  Widget build(BuildContext context) {
    final label = info?.ip.isNotEmpty == true ? info!.ip : '—.—.—.—';
    final sub = info?.hostname.isNotEmpty == true
        ? '${info!.server}  •  ${info!.device}'
        : (status == ConnectionStatus.searching ? 'Searching…' : '');
    return Column(
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 22,
            fontWeight: FontWeight.bold,
            letterSpacing: 2,
          ),
        ),
        if (sub.isNotEmpty)
          Text(sub,
              style: const TextStyle(color: Colors.white54, fontSize: 12)),
      ],
    );
  }
}

class _ConcentricCircles extends StatelessWidget {
  final Animation<double> pulseAnim;
  final bool isSearching;
  final ConnectionStatus status;

  const _ConcentricCircles({
    required this.pulseAnim,
    required this.isSearching,
    required this.status,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = status == ConnectionStatus.connected
        ? const Color(0xFF66BB6A)
        : const Color(0xFF1565C0);

    return AnimatedBuilder(
      animation: pulseAnim,
      builder: (_, __) {
        final scale = isSearching ? pulseAnim.value : 1.0;
        return Transform.scale(
          scale: scale,
          child: SizedBox(
            width: 220,
            height: 220,
            child: CustomPaint(
              painter: _ConcentricCirclesPainter(
                status: status,
                animValue: isSearching ? pulseAnim.value : 1.0,
              ),
              child: Center(
                child: Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: iconColor,
                    boxShadow: [
                      BoxShadow(
                        color: iconColor.withOpacity(0.6),
                        blurRadius: 20,
                        spreadRadius: 4,
                      ),
                    ],
                  ),
                  child: const Icon(Icons.phone_android,
                      size: 40, color: Colors.white),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _ConcentricCirclesPainter extends CustomPainter {
  final ConnectionStatus status;
  final double animValue;

  _ConcentricCirclesPainter({required this.status, required this.animValue});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final baseColor = status == ConnectionStatus.connected
        ? const Color(0xFF66BB6A)
        : const Color(0xFF1565C0);

    const radii = [105.0, 80.0, 57.0];
    for (var i = 0; i < radii.length; i++) {
      final opacity = 0.15 + (i * 0.06) * animValue;
      final paint = Paint()
        ..color = baseColor.withOpacity(opacity.clamp(0.0, 1.0))
        ..style = PaintingStyle.fill;
      canvas.drawCircle(center, radii[i], paint);
    }
    // Outer ring border
    final borderPaint = Paint()
      ..color = baseColor.withOpacity(0.5)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, radii[0], borderPaint);
  }

  @override
  bool shouldRepaint(_ConcentricCirclesPainter old) =>
      old.animValue != animValue || old.status != status;
}

/// Simple laptop illustration drawn with widgets.
class _LaptopIllustration extends StatelessWidget {
  final bool connected;
  const _LaptopIllustration({required this.connected});

  @override
  Widget build(BuildContext context) {
    final screenColor =
        connected ? const Color(0xFF42A5F5) : const Color(0xFF1A2A3A);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Screen
        Container(
          width: 130,
          height: 82,
          decoration: BoxDecoration(
            color: const Color(0xFF1E3A5F),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(6),
              topRight: Radius.circular(6),
            ),
            border: Border.all(color: Colors.white24, width: 1.5),
          ),
          child: Center(
            child: Icon(Icons.desktop_windows,
                color: screenColor, size: 38),
          ),
        ),
        // Base
        Container(
          width: 150,
          height: 10,
          decoration: BoxDecoration(
            color: const Color(0xFF1E3A5F),
            borderRadius: const BorderRadius.only(
              bottomLeft: Radius.circular(4),
              bottomRight: Radius.circular(4),
            ),
            border: Border.all(color: Colors.white24, width: 1),
          ),
        ),
        // Hinge
        Container(
          width: 50,
          height: 4,
          color: const Color(0xFF152535),
        ),
      ],
    );
  }
}

class _BottomActionBar extends StatelessWidget {
  final VoidCallback onRefresh;
  final VoidCallback onAdd;
  final VoidCallback onHelp;

  const _BottomActionBar({
    required this.onRefresh,
    required this.onAdd,
    required this.onHelp,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        _ActionButton(
            icon: Icons.refresh, label: 'Refresh', onTap: onRefresh),
        _ActionButton(
            icon: Icons.add_circle_outline, label: 'Add', onTap: onAdd),
        _ActionButton(
            icon: Icons.help_outline, label: 'Help', onTap: onHelp),
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton(
      {required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 28),
            const SizedBox(height: 4),
            Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}
