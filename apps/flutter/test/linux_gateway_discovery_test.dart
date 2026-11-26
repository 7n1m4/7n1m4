// SPDX-License-Identifier: GPL-3.0-or-later

// Read-only Linux D-Bus discovery: everything is driven through an injected
// Process.run seam, so no daemon, bus, or busctl binary is needed.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/connection/connection_settings.dart';
import 'package:anima_control/connection/linux_gateway_discovery.dart';

ProcessResult _reply(Map<String, dynamic> inner, {int exitCode = 0}) =>
    ProcessResult(
      4321,
      exitCode,
      jsonEncode(<String, dynamic>{'type': 's', 'data': jsonEncode(inner)}),
      '',
    );

Map<String, dynamic> _config({
  Object hostname = '127.0.0.1',
  Object? port = 6121,
  Object? tlsEnabled = false,
  Object? caCertPath,
  Object? authToken = 'SECRET-FROM-DAEMON',
  Object? bound,
}) => <String, dynamic>{
  if (bound != null) 'bound': bound,
  'hostname': hostname,
  'port': port,
  'tlsEnabled': tlsEnabled,
  'caCertPath': caCertPath,
  'authToken': authToken,
};

void main() {
  // The production helper is Linux-gated; the injected runner cannot bypass
  // that guard, so platform-behavior tests must skip off Linux.
  final onLinux = Platform.isLinux;

  group('parseBusctlStringReply', () {
    test('decodes the double-encoded reply into its inner object', () {
      final decoded = parseBusctlStringReply(
        jsonEncode(<String, dynamic>{
          'type': 's',
          'data': jsonEncode(_config()),
        }),
      );

      expect(decoded, isA<Map<String, dynamic>>());
      expect(decoded!['hostname'], '127.0.0.1');
      expect(decoded['authToken'], 'SECRET-FROM-DAEMON');
    });

    final badReplies = <String, String>{
      'wrong type': jsonEncode(<String, dynamic>{
        'type': 'u',
        'data': jsonEncode(_config()),
      }),
      'data not a string': jsonEncode(<String, dynamic>{
        'type': 's',
        'data': 42,
      }),
      'inner not an object': jsonEncode(<String, dynamic>{
        'type': 's',
        'data': jsonEncode(<String>['not', 'a', 'map']),
      }),
      'garbage': 'not json at all',
      'truncated': '{"type":"s","data":"{\\"hostname\\":\\"127.0.0.1\\"',
    };
    badReplies.forEach((description, stdout) {
      test('returns null for $description', () {
        expect(parseBusctlStringReply(stdout), isNull);
      });
    });
  });

  group(
    'discoverGatewayOnLinux',
    () {
  test(
    'happy path adopts endpoint fields but never the daemon token',
    () async {
      final executables = <String>[];
      final argumentLists = <List<String>>[];
      final settings = await discoverGatewayOnLinux(
        run: (executable, args) async {
          executables.add(executable);
          argumentLists.add(args);
          return _reply(_config(caCertPath: '/etc/anima/ca.pem'));
        },
      );

      expect(settings, isNotNull);
      expect(settings!.host, '127.0.0.1');
      expect(settings.port, 6121);
      expect(settings.scheme, 'ws');
      expect(settings.caCertPath, '/etc/anima/ca.pem');
      expect(settings.path, ConnectionSettings.defaultPath);
      expect(settings.authToken, isEmpty);

      expect(executables, <String>['busctl']);
      expect(argumentLists, <List<String>>[
        <String>[
          '--user',
          '--json=short',
          'call',
          'org.moeru.airi.Daemon1',
          '/org/moeru/airi/Daemon1',
          'org.moeru.airi.Daemon1',
          'GetGatewayConfig',
        ],
      ]);
    },
  );

  test('tlsEnabled:true yields the wss scheme', () async {
    final settings = await discoverGatewayOnLinux(
      run: (_, __) async => _reply(_config(tlsEnabled: true)),
    );

    expect(settings, isNotNull);
    expect(settings!.scheme, 'wss');
    expect(settings.effectiveScheme, 'wss');
  });

  test('a null/absent CA path stays null', () async {
    final settings = await discoverGatewayOnLinux(
      run: (_, __) async => _reply(_config()),
    );

    expect(settings, isNotNull);
    expect(settings!.caCertPath, isNull);
  });

  for (final entry in <String, String>{
    'garbage stdout': 'garbage',
    'truncated stdout': '{"type":"s","data":"{',
    'empty stdout': '',
  }.entries) {
    test('returns null on ${entry.key}', () async {
      final settings = await discoverGatewayOnLinux(
        run: (_, __) async => ProcessResult(1, 0, entry.value, ''),
      );
      expect(settings, isNull);
    });
  }

  test('returns null on a non-zero busctl exit code', () async {
    final settings = await discoverGatewayOnLinux(
      run: (_, __) async => _reply(_config(), exitCode: 1),
    );
    expect(settings, isNull);
  });

  for (final entry in <String, Map<String, dynamic>>{
    'port 0': _config(port: 0),
    'port 65536': _config(port: 65536),
    'port as string': _config(port: '6121'),
    'fractional port': _config(port: 6121.5),
    'missing port': <String, dynamic>{
      'hostname': '127.0.0.1',
      'tlsEnabled': false,
    },
    'non-string hostname': _config(hostname: 123),
    'blank hostname': _config(hostname: '   '),
    'non-bool tlsEnabled': _config(tlsEnabled: 'false'),
    'unbound daemon': _config(bound: false),
  }.entries) {
    test('returns null for ${entry.key}', () async {
      final settings = await discoverGatewayOnLinux(
        run: (_, __) async => _reply(entry.value),
      );
      expect(settings, isNull);
    });
  }

  test('returns null when the process runner throws', () async {
    final settings = await discoverGatewayOnLinux(
      run: (_, __) async => throw StateError('busctl missing'),
    );
    expect(settings, isNull);
  });

  test('returns null on timeout', () async {
    final settings = await discoverGatewayOnLinux(
      run: (_, __) => Completer<ProcessResult>().future,
      timeout: const Duration(milliseconds: 5),
    );
    expect(settings, isNull);
  });
    },
    skip: !onLinux,
  );
}
