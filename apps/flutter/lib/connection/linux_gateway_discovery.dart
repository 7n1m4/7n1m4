// SPDX-License-Identifier: GPL-3.0-or-later

import 'dart:convert';
import 'dart:io';

import 'connection_settings.dart';

/// Minimal seam over `Process.run`: literal executable + argv, no shell.
///
/// Mirrors the Node reference
/// `apps/stage-tamagotchi/src/main/services/airi/daemon-gateway.ts:67-107`.
typedef ProcessRunner = Future<ProcessResult> Function(
  String executable,
  List<String> arguments,
);

const String _gatewayBus = 'org.moeru.airi.Daemon1';
const String _gatewayPath = '/org/moeru/airi/Daemon1';

/// Decode busctl's `--json=short` reply: a `{"type":"s","data":"<json>"}`
/// envelope whose `data` is itself JSON-encoded (double-encoded). Returns the
/// inner object, or `null` on any parse/shape failure.
Map<String, dynamic>? parseBusctlStringReply(String stdout) {
  try {
    final outer = jsonDecode(stdout);
    if (outer is! Map<String, dynamic>) return null;
    if (outer['type'] != 's') return null;
    final data = outer['data'];
    if (data is! String) return null;
    final inner = jsonDecode(data);
    if (inner is! Map<String, dynamic>) return null;
    return inner;
  } catch (_) {
    // Malformed, truncated, or non-JSON stdout: the caller falls back.
    return null;
  }
}

Future<ProcessResult> _defaultRunner(
  String executable,
  List<String> arguments,
) => Process.run(executable, arguments); // runInShell defaults to false.

/// Read-only D-Bus discovery of the daemon gateway on Linux.
///
/// Never writes config (`ApplyGatewayConfig`), binds port 6121, or mints a
/// token: the reply's `authToken` is deliberately discarded. Any failure —
/// non-Linux host, missing daemon, timeout, malformed reply, invalid field —
/// resolves to `null` so the caller keeps its in-app settings.
Future<ConnectionSettings?> discoverGatewayOnLinux({
  ProcessRunner? run,
  Duration timeout = const Duration(milliseconds: 1200),
}) async {
  if (!Platform.isLinux) return null;
  try {
    // NOTICE: literal argv, never runInShell — no shell interpolation on a
    // D-Bus method name. Only GetGatewayConfig is ever invoked here.
    const arguments = <String>[
      '--user',
      '--json=short',
      'call',
      _gatewayBus,
      _gatewayPath,
      _gatewayBus,
      'GetGatewayConfig',
    ];
    final result = await (run ?? _defaultRunner)(
      'busctl',
      arguments,
    ).timeout(timeout);
    if (result.exitCode != 0) return null;
    final stdout = result.stdout;
    if (stdout is! String) return null;

    final value = parseBusctlStringReply(stdout);
    if (value == null) return null;
    // A config reply with bound:false means no daemon is listening on that
    // endpoint; prefill would point the user at a dead address.
    if (value['bound'] == false) return null;

    final hostname = value['hostname'];
    if (hostname is! String || hostname.trim().isEmpty) return null;
    final port = value['port'];
    if (port is! int || port < 1 || port > 65535) return null;
    final tlsEnabled = value['tlsEnabled'];
    if (tlsEnabled is! bool) return null;
    final caCertPath = value['caCertPath'];

    return ConnectionSettings(
      host: hostname,
      port: port,
      scheme: tlsEnabled ? 'wss' : 'ws',
      caCertPath: caCertPath is String ? caCertPath : null,
      // The D-Bus reply carries a token, but discovery must never adopt it:
      // the user keeps control of the token in the connection form.
      authToken: '',
    );
  } catch (_) {
    // Daemon absent, bus unavailable, timeout, or busctl missing — fall back.
    return null;
  }
}
