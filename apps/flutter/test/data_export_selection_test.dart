// SPDX-License-Identifier: GPL-3.0-or-later

// Focused coverage for selective per-domain vault archive export. The screen
// must offer only the gateway allowlist, default to all of it, and hand exactly
// the selected domains to the daemon client. No byte figure appears unless the
// daemon actually returned one.

import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/data/data_screen.dart';
import 'package:anima_control/features/data/daemon_vault_ports.dart';

import 'support/fakes.dart';

/// Mirrors `VAULT_ARCHIVE_DOMAINS` in crates/anima-daemon/src/gateway.rs.
const List<String> _allowedDomains = <String>[
  'characters',
  'chats',
  'memory',
  'backgrounds',
];

class _ZipPorts implements VaultFilePorts {
  Uri saveResult = Uri.file('/tmp/airi-vault-archive.zip');
  int saveCalls = 0;

  @override
  Future<PlatformFile?> pickJsonl() async => null;

  @override
  Future<Uri?> saveJsonl(String fileName, Uint8List bytes) async => saveResult;

  @override
  Future<PlatformFile?> pickZip() async => null;

  @override
  Future<Uri?> saveZip(String fileName, Uint8List bytes) async {
    saveCalls++;
    return saveResult;
  }
}

class _SelectionClient extends FakeChatClient {
  Map<String, dynamic>? statusStats;
  List<String>? lastCollectedDomains;
  int collectCalls = 0;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    if (action == 'vault.status') {
      final data = <String, dynamic>{'available': true};
      if (statusStats != null) data['stats'] = statusStats;
      return RpcReply(action: action, ok: true, data: data);
    }
    if (action == 'sessions.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'sessions': <dynamic>[]},
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }

  @override
  Future<VaultArchive> vaultArchiveCollect(List<String> domains) async {
    collectCalls++;
    // Copy: the screen must not be able to mutate what was handed to the
    // client after the call.
    lastCollectedDomains = List<String>.of(domains);
    return VaultArchive(
      archive: base64.encode(utf8.encode('zip')),
      bytes: 3,
      domains: domains,
    );
  }
}

Future<void> _pump(WidgetTester tester, DaemonClient client) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: DataScreen(client: client))),
  );
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(Key(key), skipOffstage: false);
Finder _domain(String domain) => _key('data-archive-domain-$domain');

Future<void> _tap(WidgetTester tester, Finder finder) async {
  final list = find.byType(ListView);
  if (list.evaluate().isNotEmpty && finder.evaluate().isEmpty) {
    await tester.drag(list, const Offset(0, -1500));
    await tester.pumpAndSettle();
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pump();
}

Future<void> _scrollToStatus(WidgetTester tester) async {
  final list = find.byType(ListView);
  if (list.evaluate().isNotEmpty) {
    await tester.drag(list, const Offset(0, 4000));
    await tester.pumpAndSettle();
  }
}

void main() {
  late _ZipPorts ports;
  late _SelectionClient client;
  late VaultFilePorts previous;

  setUp(() {
    previous = vaultFilePorts;
    ports = _ZipPorts();
    vaultFilePorts = ports;
    client = _SelectionClient();
  });

  tearDown(() {
    vaultFilePorts = previous;
    client.dispose();
  });

  testWidgets('defaults to every allowed domain and exports them in order',
      (tester) async {
    await _pump(tester, client);

    for (final domain in _allowedDomains) {
      expect(_domain(domain), findsOneWidget, reason: 'missing $domain checkbox');
      expect(
        tester.widget<CheckboxListTile>(_domain(domain)).value,
        isTrue,
        reason: '$domain must be selected by default',
      );
    }

    await _tap(tester, _key('data-export-vault'));

    expect(client.collectCalls, 1);
    expect(client.lastCollectedDomains, _allowedDomains);
    expect(ports.saveCalls, 1);
  });

  testWidgets('passes only the selected subset to the client verbatim',
      (tester) async {
    await _pump(tester, client);
    await _tap(tester, _domain('characters'));
    await _tap(tester, _domain('backgrounds'));

    expect(tester.widget<CheckboxListTile>(_domain('characters')).value, isFalse);
    expect(tester.widget<CheckboxListTile>(_domain('chats')).value, isTrue);
    expect(tester.widget<CheckboxListTile>(_domain('memory')).value, isTrue);
    expect(tester.widget<CheckboxListTile>(_domain('backgrounds')).value, isFalse);

    await _tap(tester, _key('data-export-vault'));

    expect(client.collectCalls, 1);
    expect(client.lastCollectedDomains, <String>['chats', 'memory']);
  });

  testWidgets('never offers or sends a domain outside the gateway allowlist',
      (tester) async {
    await _pump(tester, client);

    expect(_domain('providers'), findsNothing);
    expect(_domain('unknown'), findsNothing);

    await _tap(tester, _domain('chats'));
    await _tap(tester, _key('data-export-vault'));

    expect(client.collectCalls, 1);
    expect(client.lastCollectedDomains, <String>[
      'characters',
      'memory',
      'backgrounds',
    ]);
    expect(client.lastCollectedDomains, isNot(contains('providers')));
    expect(client.lastCollectedDomains!.every(_allowedDomains.contains), isTrue);
  });

  testWidgets('an empty selection never calls the client', (tester) async {
    await _pump(tester, client);
    for (final domain in _allowedDomains) {
      await _tap(tester, _domain(domain));
    }

    await _tap(tester, _key('data-export-vault'));
    await _scrollToStatus(tester);

    expect(client.collectCalls, 0);
    expect(ports.saveCalls, 0);
    expect(
      find.textContaining('Select at least one vault domain', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('byte counts are shown only for domains the daemon reported',
      (tester) async {
    client.statusStats = <String, dynamic>{
      'characters': <String, dynamic>{'count': 1, 'bytes': 128},
      'chats': <String, dynamic>{'sessions': 2, 'messages': 3, 'bytes': 256},
    };
    await _pump(tester, client);

    expect(
      (tester.widget<CheckboxListTile>(_domain('characters')).secondary! as Text).data,
      '128 B',
    );
    expect(
      (tester.widget<CheckboxListTile>(_domain('chats')).secondary! as Text).data,
      '256 B',
    );
    expect(tester.widget<CheckboxListTile>(_domain('memory')).secondary, isNull);
    await tester.drag(find.byType(ListView), const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(_domain('backgrounds')).secondary, isNull);
  });
}
