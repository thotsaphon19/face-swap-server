import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kBaseUrlKey = 'server_base_url';
const _kTokenKey = 'server_token';

const _kDefaultBaseUrl = 'http://192.168.1.49:8000';
const _kDefaultToken = 'testing123';

/// Read persisted settings.
Future<({String baseUrl, String token})> loadSettings(
    SharedPreferences prefs) async {
  return (
    baseUrl: prefs.getString(_kBaseUrlKey) ?? _kDefaultBaseUrl,
    token: prefs.getString(_kTokenKey) ?? _kDefaultToken,
  );
}

class SettingsScreen extends StatefulWidget {
  final SharedPreferences prefs;
  const SettingsScreen({super.key, required this.prefs});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final TextEditingController _urlCtrl;
  late final TextEditingController _tokenCtrl;

  @override
  void initState() {
    super.initState();
    _urlCtrl = TextEditingController(
        text: widget.prefs.getString(_kBaseUrlKey) ?? _kDefaultBaseUrl);
    _tokenCtrl = TextEditingController(
        text: widget.prefs.getString(_kTokenKey) ?? _kDefaultToken);
  }

  @override
  void dispose() {
    _urlCtrl.dispose();
    _tokenCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await widget.prefs.setString(_kBaseUrlKey, _urlCtrl.text.trim());
    await widget.prefs.setString(_kTokenKey, _tokenCtrl.text.trim());
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D1B2A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0D1B2A),
        title: const Text('Settings', style: TextStyle(color: Colors.white)),
        iconTheme: const IconThemeData(color: Colors.white),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Server URL',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _urlCtrl,
              style: const TextStyle(color: Colors.white),
              keyboardType: TextInputType.url,
              decoration: _inputDecoration('http://192.168.1.49:8000'),
            ),
            const SizedBox(height: 20),
            const Text('API Token',
                style: TextStyle(color: Colors.white70, fontSize: 13)),
            const SizedBox(height: 6),
            TextField(
              controller: _tokenCtrl,
              style: const TextStyle(color: Colors.white),
              obscureText: true,
              decoration: _inputDecoration('testing123'),
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _save,
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF1565C0),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: const Text('Save & Reconnect',
                    style: TextStyle(fontSize: 16, color: Colors.white)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white30),
        filled: true,
        fillColor: const Color(0xFF1A2A3A),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide.none,
        ),
      );
}
