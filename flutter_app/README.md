# flutter_app

Primary mobile camera client for face-swap streaming (connection-first flow).

## Open in VS Code

1. Open folder: `<repo-root>/flutter_app`
2. Run:
   ```bash
   flutter pub get
   ```

## Build APK

```bash
flutter build apk --release
```

Notes:
- Android Gradle wrapper is included in `android/gradlew` and `android/gradle/wrapper/`.
- First launch opens a server connection screen.  
  Default URL shown: `http://192.168.1.100:8000`
- Camera starts only after server connection succeeds.
- Debug build allows LAN HTTP/WS connections for local face-swap servers.
- Release build keeps cleartext blocked; use HTTPS/WSS server URLs.

## Runtime flow

1. Connect to server (`/health` check).
2. Enter camera/stream screen.
3. Stream frames over WebSocket (`/ws`) with auto reconnect.
