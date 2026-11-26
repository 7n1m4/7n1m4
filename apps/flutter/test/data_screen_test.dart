// SPDX-License-Identifier: GPL-3.0-or-later

// DataScreen covers vault.status, per-session JSONL import/export, full-vault
// archive export/import and media scrub. No action is reported as successful
// unless the daemon replied successfully.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/data/data_screen.dart';
import 'package:anima_control/features/data/daemon_vault_ports.dart';

import 'support/fakes.dart';

const _snapshot = '{"type":"session","session":{"id":"s1"}}\n';

class _FakeVaultFilePorts implements VaultFilePorts {
  PlatformFile? picked;
  Uri? saveResult;
  Object? pickError;
  Object? saveError;
  String? lastSavedName;
  Uint8List? lastSavedBytes;
  int pickCalls = 0;
  int saveCalls = 0;
  int zipPickCalls = 0;
  int zipSaveCalls = 0;
  String? lastSavedZipName;
  Uint8List? lastSavedZipBytes;

  @override
  Future<PlatformFile?> pickJsonl() async {
    pickCalls++;
    if (pickError != null) throw pickError!;
    return picked;
  }

  @override
  Future<Uri?> saveJsonl(String fileName, Uint8List bytes) async {
    saveCalls++;
    lastSavedName = fileName;
    lastSavedBytes = bytes;
    if (saveError != null) throw saveError!;
    return saveResult;
  }

  @override
  Future<PlatformFile?> pickZip() async {
    zipPickCalls++;
    return picked;
  }

  @override
  Future<Uri?> saveZip(String fileName, Uint8List bytes) async {
    zipSaveCalls++;
    lastSavedZipName = fileName;
    lastSavedZipBytes = bytes;
    return saveResult;
  }
}

base class _FakePlatformFile extends PlatformFile {
  _FakePlatformFile(this.name, this.bytes, {int? length}) : reportedLength = length;

  @override
  final String name;
  final Uint8List bytes;
  final int? reportedLength;

  @override
  Uri get uri => Uri.file('/picked/$name');

  @override
  XFile get xFile => XFile(uri.path);

  @override
  int? lengthSync() => reportedLength ?? bytes.length;

  @override
  Future<int?> length() async => reportedLength ?? bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream<Uint8List>.value(bytes);
}

class _RecordingDataClient extends FakeChatClient {
  final List<String> actions = <String>[];
  String exportJsonl = _snapshot;
  bool exportFails = false;
  String importStatus = 'applied';
  bool importFails = false;
  String archive = 'YWJj';
  String archiveFormat = 'airi-vault';
  bool includesSecrets = false;
  bool inspectFails = false;
  bool applyFails = false;
  Map<String, dynamic>? lastPayload;
  final Map<String, Map<String, dynamic>?> payloads = <String, Map<String, dynamic>?>{};
  Map<String, dynamic> scrubReport = <String, dynamic>{
    'imagesFound': 2,
    'bytesExtracted': 128,
    'sessionsScanned': 1,
    'backupPath': '/backups/vault.zip',
  };
  bool scrubFails = false;

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    actions.add(action);
    lastPayload = payload;
    payloads[action] = payload;
    if (action == 'vault.status') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'available': true,
          'stats': <String, dynamic>{
            'chats': <String, dynamic>{'sessions': 1, 'messages': 2},
            'memory': <String, dynamic>{'summaries': 3, 'journalEntries': 4},
          },
        },
      );
    }
    if (action == 'sessions.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'sessions': <Map<String, dynamic>>[
            <String, dynamic>{'id': 's1', 'title': 'first'},
          ],
        },
      );
    }
    if (action == 'sessions.export') {
      if (exportFails) {
        return RpcReply(
          action: action,
          ok: false,
          error: const RpcError(code: 'rpc', message: 'export failed'),
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'jsonl': exportJsonl},
      );
    }
    if (action == 'vault.archive.collect') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'archive': archive,
          'bytes': 3,
          'domains': <String>['characters', 'chats', 'memory', 'backgrounds'],
        },
      );
    }
    if (action == 'vault.archive.inspect') {
      if (inspectFails) {
        return RpcReply(
          action: action,
          ok: false,
          error: const RpcError(code: 'rpc_handler_error', message: 'invalid vault archive'),
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'format': archiveFormat,
          'version': 1,
          'createdAt': 1700000000000,
          'includesSecrets': includesSecrets,
          'domains': <Map<String, dynamic>>[
            <String, dynamic>{'domain': 'chats', 'sessions': 1},
          ],
          'sessionCount': 1,
          'messageCount': 2,
          'companionNames': <String>['secret-companion-name'],
        },
      );
    }
    if (action == 'vault.archive.apply') {
      if (applyFails) {
        return RpcReply(
          action: action,
          ok: false,
          error: const RpcError(code: 'rpc_actions_disabled', message: 'actions off'),
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'sessionsInserted': 1,
          'sessionsSkipped': 2,
          'messagesInserted': 3,
          'messagesSkipped': 4,
          'summariesInserted': 5,
          'journalEntriesInserted': 6,
          'applied': <String>['chats', 'memory'],
          'notApplied': <String>['characters'],
        },
      );
    }
    if (action == 'sessions.media.scrub') {
      if (scrubFails) {
        return RpcReply(
          action: action,
          ok: false,
          error: const RpcError(code: 'rpc_actions_disabled', message: 'actions off'),
        );
      }
      return RpcReply(action: action, ok: true, data: scrubReport);
    }
    if (action == 'sessions.import') {
      if (importFails) {
        return RpcReply(
          action: action,
          ok: false,
          error: const RpcError(code: 'actions_disabled', message: 'actions off'),
        );
      }
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{'status': importStatus, 'revision': 7},
      );
    }
    return RpcReply(action: action, ok: true, data: <String, dynamic>{});
  }
}

Future<void> _pump(tester, DaemonClient client) async {
  await tester.pumpWidget(
    MaterialApp(home: Scaffold(body: DataScreen(client: client))),
  );
  await tester.pumpAndSettle();
}

Finder _key(String key) => find.byKey(Key(key), skipOffstage: false);

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

/// Status and error Text widgets live at the top of the screen's ListView.
/// Tapping an action scrolls down to its button, so return to the top before
/// asserting on messages that the screen published in response to that action.
Future<void> _scrollToStatus(WidgetTester tester) async {
  final list = find.byType(ListView);
  if (list.evaluate().isNotEmpty) {
    await tester.drag(list, const Offset(0, 4000));
    await tester.pumpAndSettle();
  }
}

void main() {

  late _FakeVaultFilePorts ports;
  late _RecordingDataClient client;
  late VaultFilePorts previous;

  setUp(() {
    previous = vaultFilePorts;
    ports = _FakeVaultFilePorts();
    vaultFilePorts = ports;
    client = _RecordingDataClient();
  });

  tearDown(() {
    vaultFilePorts = previous;
    client.dispose();
  });

  testWidgets('shows vault status from vault.status and sessions from sessions.list',
      (tester) async {
    await _pump(tester, client);

    expect(find.text('first', skipOffstage: false), findsOneWidget);
    expect(client.actions, contains('vault.status'));
    expect(client.actions, contains('sessions.list'));
    expect(_key('data-vault-available'), findsOneWidget);
  });

  testWidgets('export writes the daemon JSONL to a picked save location', (
    tester,
  ) async {
    ports.saveResult = Uri.file('/saved/airi-session-first.jsonl');
    await _pump(tester, client);

    await _tap(tester, _key('data-export-s1'));
    await _scrollToStatus(tester);

    expect(client.actions, contains('sessions.export'));
    expect(ports.saveCalls, 1);
    expect(ports.lastSavedName, 'airi-session-first.jsonl');
    expect(ports.lastSavedBytes, utf8.encode(_snapshot));
    expect(_key('data-status'), findsOneWidget);
    expect(find.textContaining('Exported session s1', skipOffstage: false), findsOneWidget);
    expect(_key('data-error'), findsNothing);
  });

  testWidgets('canceling the save dialog does not claim an export', (tester) async {
    ports.saveResult = null;
    await _pump(tester, client);

    await _tap(tester, _key('data-export-s1'));
    await _scrollToStatus(tester);

    expect(find.text('Export cancelled: session s1 was not saved.', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('Exported session s1 to', skipOffstage: false), findsNothing);
  });

  testWidgets('a failed sessions.export shows an error and saves nothing', (
    tester,
  ) async {
    client.exportFails = true;
    await _pump(tester, client);

    await _tap(tester, _key('data-export-s1'));
    await _scrollToStatus(tester);

    expect(_key('data-error'), findsOneWidget);
    expect(find.text('export failed', skipOffstage: false), findsOneWidget);
    expect(ports.saveCalls, 0);
  });

  testWidgets('import sends the picked file to sessions.import only when applied',
      (tester) async {
    ports.picked = _FakePlatformFile('backup.jsonl', utf8.encode(_snapshot));
    await _pump(tester, client);

    await _tap(tester, _key('data-import-session'));
    await _scrollToStatus(tester);

    expect(ports.pickCalls, 1);
    expect(client.actions.where((a) => a == 'sessions.import'), hasLength(1));
    expect(find.text('Imported backup.jsonl (revision 7).', skipOffstage: false), findsOneWidget);
  });

  testWidgets('oversized imports are rejected before reading the file', (
    tester,
  ) async {
    // The reported length must gate the read: no test data is loaded at all.
    const maxImportBytes = (1024 * 1024 - 8192) * 3 ~/ 4;
    ports.picked = _FakePlatformFile('huge.jsonl', Uint8List(0),
        length: maxImportBytes + 1);
    await _pump(tester, client);

    await _tap(tester, _key('data-import-session'));
    await _scrollToStatus(tester);

    expect(find.textContaining('exceeds the $maxImportBytes byte import limit',
        skipOffstage: false), findsOneWidget);
    expect(client.actions.where((a) => a == 'sessions.import'), isEmpty);
  });

  testWidgets('a stale picker length cannot bypass the import bound', (
    tester,
  ) async {
    const maxImportBytes = (1024 * 1024 - 8192) * 3 ~/ 4;
    ports.picked = _FakePlatformFile('huge.jsonl', Uint8List(maxImportBytes + 1),
        length: 10);
    await _pump(tester, client);

    await _tap(tester, _key('data-import-session'));
    await _scrollToStatus(tester);

    expect(find.textContaining('exceeds the $maxImportBytes byte import limit',
        skipOffstage: false), findsOneWidget);
    expect(client.actions.where((a) => a == 'sessions.import'), isEmpty);
  });

  for (final status in <String>['duplicate', 'older', 'conflict']) {
    testWidgets('import status $status is reported as not applied', (tester) async {
      client.importStatus = status;
      ports.picked = _FakePlatformFile('backup.jsonl', utf8.encode(_snapshot));
      await _pump(tester, client);

      await _tap(tester, _key('data-import-session'));
      await _scrollToStatus(tester);

      expect(find.text('backup.jsonl was not applied ($status, revision 7).', skipOffstage: false), findsOneWidget);
      expect(find.textContaining('Imported backup.jsonl', skipOffstage: false), findsNothing);
    });
  }

  testWidgets('a failed sessions.import surfaces the daemon error', (tester) async {
    client.importFails = true;
    ports.picked = _FakePlatformFile('backup.jsonl', utf8.encode(_snapshot));
    await _pump(tester, client);

    await _tap(tester, _key('data-import-session'));
    await _scrollToStatus(tester);

    expect(_key('data-error'), findsOneWidget);
    expect(find.text('actions off', skipOffstage: false), findsOneWidget);
  });

  testWidgets('vault export collects allowed domains and saves the ZIP', (
    tester,
  ) async {
    ports.saveResult = Uri.file('/saved/airi-vault-archive.zip');
    await _pump(tester, client);

    await _tap(tester, _key('data-export-vault'));
    await _scrollToStatus(tester);

    expect(client.actions, contains('vault.archive.collect'));
    expect(
      client.lastPayload?['domains'],
      <String>['characters', 'chats', 'memory', 'backgrounds'],
    );
    expect(client.lastPayload?.containsKey('providers'), isFalse);
    expect(ports.zipSaveCalls, 1);
    expect(ports.lastSavedZipName, 'airi-vault-archive.zip');
    expect(ports.lastSavedZipBytes, utf8.encode('abc'));
    expect(find.textContaining('Exported 3 archive bytes', skipOffstage: false), findsOneWidget);
    expect(_key('data-error'), findsNothing);
  });

  testWidgets('vault export cancellation and failures are not success', (
    tester,
  ) async {
    ports.saveResult = null;
    await _pump(tester, client);
    await _tap(tester, _key('data-export-vault'));
    await _scrollToStatus(tester);
    expect(find.text('Archive export cancelled; nothing was saved.', skipOffstage: false), findsOneWidget);
    expect(find.textContaining('Exported ', skipOffstage: false), findsNothing);

    client.archive = 'not base64';
    ports.saveResult = Uri.file('/saved/archive.zip');
    await _tap(tester, _key('data-export-vault'));
    await _scrollToStatus(tester);
    expect(ports.zipSaveCalls, 1);
    expect(_key('data-error'), findsOneWidget);
  });

  testWidgets('vault import inspects before confirmation and applies after', (
    tester,
  ) async {
    ports.picked = _FakePlatformFile('vault.zip', utf8.encode('abc'));
    await _pump(tester, client);

    await _tap(tester, _key('data-import-vault'));

    expect(ports.zipPickCalls, 1);
    expect(client.actions, contains('vault.archive.inspect'));
    expect(client.actions, isNot(contains('vault.archive.apply')));
    expect(client.payloads['vault.archive.inspect']?['archive'], base64.encode(utf8.encode('abc')));
    // Metadata only: no archive bytes, no companion name and no secrets shown.
    expect(find.textContaining('1 sessions', skipOffstage: false), findsOneWidget);
    expect(find.text('secret-companion-name', skipOffstage: false), findsNothing);

    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(client.actions, isNot(contains('vault.archive.apply')));
    await _scrollToStatus(tester);
    expect(find.text('Archive import cancelled; nothing was imported.', skipOffstage: false), findsOneWidget);

    await _tap(tester, _key('data-import-vault'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pumpAndSettle();

    expect(client.actions.where((a) => a == 'vault.archive.apply').length, 1);
    await _scrollToStatus(tester);
    expect(find.textContaining('Imported vault.zip: 1 sessions', skipOffstage: false), findsOneWidget);
    expect(_key('data-error'), findsNothing);
  });

  testWidgets('vault import refuses secret-bearing and failed inspection', (
    tester,
  ) async {
    client.includesSecrets = true;
    ports.picked = _FakePlatformFile('vault.zip', utf8.encode('abc'));
    await _pump(tester, client);
    await _tap(tester, _key('data-import-vault'));
    await _scrollToStatus(tester);
    expect(
      find.textContaining('advertises provider credentials', skipOffstage: false),
      findsOneWidget,
    );
    expect(client.actions, isNot(contains('vault.archive.apply')));

    client.includesSecrets = false;
    client.inspectFails = true;
    await _tap(tester, _key('data-import-vault'));
    await _scrollToStatus(tester);
    expect(client.actions, isNot(contains('vault.archive.apply')));
    expect(_key('data-error'), findsOneWidget);
    expect(find.text('invalid vault archive', skipOffstage: false), findsNothing);
  });

  testWidgets('a failed gated vault.archive.apply is never a success', (
    tester,
  ) async {
    client.applyFails = true;
    ports.picked = _FakePlatformFile('vault.zip', utf8.encode('abc'));
    await _pump(tester, client);
    await _tap(tester, _key('data-import-vault'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Import'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Import'));
    await tester.pump();
    await tester.pumpAndSettle();
    await _scrollToStatus(tester);
    expect(client.actions.where((a) => a == 'vault.archive.apply'), hasLength(1));
    expect(find.textContaining('Imported vault.zip', skipOffstage: false), findsNothing);
    expect(
      find.textContaining('Connection failed', skipOffstage: false),
      findsNothing,
      reason: 'gated apply failure must be sanitized by userSafeConnectionError',
    );
  });

  testWidgets('an oversized ZIP is rejected before base64 or inspect', (
    tester,
  ) async {
    const maxArchiveBytes = (1024 * 1024 - 8192) * 3 ~/ 4;
    ports.picked = _FakePlatformFile('vault.zip', utf8.encode('abc'), length: maxArchiveBytes + 1);
    await _pump(tester, client);
    await _tap(tester, _key('data-import-vault'));
    await _scrollToStatus(tester);
    expect(client.actions, isNot(contains('vault.archive.inspect')));
    expect(client.actions, isNot(contains('vault.archive.apply')));
    expect(
      find.textContaining('exceeds the $maxArchiveBytes byte limit', skipOffstage: false),
      findsOneWidget,
    );
  });

  testWidgets('scrub asks for a backup choice and reports counts or an error', (
    tester,
  ) async {
    await _pump(tester, client);

    await _tap(tester, _key('data-scrub-history'));
    expect(find.text('Cancel', skipOffstage: false), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(client.actions, isNot(contains('sessions.media.scrub')));

    await _tap(tester, _key('data-scrub-history'));
    await tester.pump();
    expect(find.widgetWithText(FilledButton, 'Back up and scrub'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Back up and scrub'));
    await tester.pump();
    await tester.pump();
    expect(client.payloads['sessions.media.scrub'], <String, dynamic>{'createBackup': true});
    await _scrollToStatus(tester);
    expect(
      find.textContaining('Scrubbed 1 sessions: 2 images extracted, 128 bytes written.', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.textContaining('/backups/vault.zip', skipOffstage: false), findsOneWidget);

    client.scrubFails = true;
    await _tap(tester, _key('data-scrub-history'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(TextButton, 'Scrub without backup'));
    await tester.pumpAndSettle();
    expect(client.payloads['sessions.media.scrub'], <String, dynamic>{'createBackup': false});
    await _scrollToStatus(tester);
    expect(find.textContaining('Scrubbed ', skipOffstage: false), findsNothing);
    expect(_key('data-error'), findsOneWidget);
  });
}
