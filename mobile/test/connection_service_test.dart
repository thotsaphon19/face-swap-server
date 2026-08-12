import 'package:flutter_test/flutter_test.dart';
import 'package:face_swap_mobile/services/server_connection_service.dart';

void main() {
  group('ServerConnectionService', () {
    test('initial status is disconnected', () {
      final svc = ServerConnectionService(
        baseUrl: 'http://localhost:8000',
        token: 'test',
      );
      expect(svc.status, ConnectionStatus.disconnected);
      expect(svc.serverInfo, isNull);
      expect(svc.sessionId, isNull);
      svc.dispose();
    });

    test('status transitions to searching after startSearch', () async {
      final svc = ServerConnectionService(
        baseUrl: 'http://localhost:8000',
        token: 'test',
      );
      final statuses = <ConnectionStatus>[];
      svc.statusStream.listen(statuses.add);
      svc.startSearch();
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(statuses, contains(ConnectionStatus.searching));
      svc.dispose();
    });

    test('ServerInfo.fromJson parses correctly', () {
      final info = ServerInfo.fromJson({
        'server': 'face-swap-server',
        'version': '0.1',
        'device': 'cpu',
        'hostname': 'myhost',
        'ip': '192.168.1.1',
      });
      expect(info.server, 'face-swap-server');
      expect(info.ip, '192.168.1.1');
      expect(info.device, 'cpu');
    });

    test('ServerInfo.fromJson handles missing fields gracefully', () {
      final info = ServerInfo.fromJson({});
      expect(info.ip, '');
      expect(info.server, '');
    });
  });
}
