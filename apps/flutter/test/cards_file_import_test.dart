// SPDX-License-Identifier: GPL-3.0-or-later

// Focused coverage for PNG/JSON card-file import on the Flutter cards screen.
// The tests drive the production screen and DaemonClient wrapper; only the
// native file picker is replaced, with a platform double that returns real
// bytes so no desktop dialog is needed.

import 'dart:convert';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:anima_control/daemon_client/daemon_client.dart';
import 'package:anima_control/features/cards/cards_screen.dart';

import 'support/fakes.dart';

final class _PickedFile extends PlatformFile {
  _PickedFile(this.name, this.bytes) : uri = Uri.file('/picked/$name');

  @override
  final String name;

  @override
  final Uri uri;

  final Uint8List bytes;

  @override
  XFile get xFile => XFile.fromData(bytes, name: name);

  @override
  int? lengthSync() => bytes.length;

  @override
  Future<int?> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => bytes;

  @override
  Stream<Uint8List> readAsByteStream() => Stream.value(bytes);
}

final class _RecordingPicker extends FilePickerPlatform
    with MockPlatformInterfaceMixin {
  _PickedFile? file;
  Object? error;
  FileType? type;
  List<String>? allowedExtensions;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    this.type = type;
    this.allowedExtensions = allowedExtensions;
    if (error != null) throw error!;
    return file;
  }
}

final class _RecordingCardsClient extends FakeChatClient {
  final List<Map<String, dynamic>?> importPayloads = <Map<String, dynamic>?>[];

  @override
  Future<RpcReply> call(String action, {Map<String, dynamic>? payload}) async {
    if (action == 'cards.import') {
      importPayloads.add(payload);
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'id': 'card-2',
          'name': 'Imported File Card',
          'renamed': false,
        },
      );
    }
    if (action == 'cards.list') {
      return RpcReply(
        action: action,
        ok: true,
        data: <String, dynamic>{
          'cards': <Map<String, dynamic>>[],
          'truncated': false,
        },
      );
    }
    return const RpcReply(action: 'cards.unused', ok: true);
  }
}

Future<void> _pumpWithFile(
  WidgetTester tester,
  _RecordingCardsClient client, {
  Future<CardFileSelection?> Function()? pickFile,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: CardsScreen(client: client, pickCardFile: pickFile),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> _tapImportFile(WidgetTester tester) async {
  final button = find.widgetWithText(OutlinedButton, 'Import file');
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

/// Error and status text lives at the top of the cards list; scroll back up
/// before asserting so the offscreen ListView children are laid out.
Future<void> _expectStatusText(WidgetTester tester, String text) async {
  final finder = find.text(text);
  await tester.drag(find.byType(ListView), const Offset(0, 4000));
  await tester.pump();
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  expect(finder, findsOneWidget);
}

void main() {
  testWidgets('a PNG file is sent as base64 pngBase64', (tester) async {
    final client = _RecordingCardsClient();
    addTearDown(client.dispose);
    final png = Uint8List.fromList(<int>[0x89, 0x50, 0x4e, 0x47, 0x01, 0x02]);
    await _pumpWithFile(
      tester,
      client,
      pickFile: () async => CardFileSelection(name: 'card.PNG', bytes: png),
    );

    await _tapImportFile(tester);

    expect(client.importPayloads, <Map<String, dynamic>?>[
      <String, dynamic>{'pngBase64': base64Encode(png)},
    ]);
    await _expectStatusText(tester, 'Imported "Imported File Card" as card-2');
  });

  testWidgets('a JSON card file is sent as a card document', (tester) async {
    final client = _RecordingCardsClient();
    addTearDown(client.dispose);
    final json = utf8.encode('{"name":"From File","spec":"chara_card_v2"}');
    await _pumpWithFile(
      tester,
      client,
      pickFile: () async => CardFileSelection(
        name: 'card.json',
        bytes: Uint8List.fromList(json),
      ),
    );

    await _tapImportFile(tester);

    expect(client.importPayloads, <Map<String, dynamic>?>[
      <String, dynamic>{
        'card': <String, dynamic>{
          'name': 'From File',
          'spec': 'chara_card_v2',
        },
      },
    ]);
  });

  testWidgets('a JSON pngBase64 envelope file keeps the envelope shape', (
    tester,
  ) async {
    final client = _RecordingCardsClient();
    addTearDown(client.dispose);
    await _pumpWithFile(
      tester,
      client,
      pickFile: () async => CardFileSelection(
        name: 'card.json',
        bytes: Uint8List.fromList(utf8.encode('{"pngBase64":"aGk="}')),
      ),
    );

    await _tapImportFile(tester);

    expect(client.importPayloads, <Map<String, dynamic>?>[
      <String, dynamic>{'pngBase64': 'aGk='},
    ]);
  });

  testWidgets('a malformed JSON file surfaces an error without an RPC', (
    tester,
  ) async {
    final client = _RecordingCardsClient();
    addTearDown(client.dispose);
    await _pumpWithFile(
      tester,
      client,
      pickFile: () async => CardFileSelection(
        name: 'broken.json',
        bytes: Uint8List.fromList(utf8.encode('not json')),
      ),
    );

    await _tapImportFile(tester);

    expect(client.importPayloads, isEmpty);
    await _expectStatusText(tester, 'The selected file is not valid JSON.');
  });

  testWidgets('a JSON array file is rejected before the wire', (tester) async {
    final client = _RecordingCardsClient();
    addTearDown(client.dispose);
    await _pumpWithFile(
      tester,
      client,
      pickFile: () async => CardFileSelection(
        name: 'list.json',
        bytes: Uint8List.fromList(utf8.encode('[1,2,3]')),
      ),
    );

    await _tapImportFile(tester);

    expect(client.importPayloads, isEmpty);
    await _expectStatusText(
      tester,
      'The selected file must contain a JSON object.',
    );
  });

  testWidgets('a cancelled picker does nothing', (tester) async {
    final client = _RecordingCardsClient();
    addTearDown(client.dispose);
    await _pumpWithFile(tester, client, pickFile: () async => null);

    await _tapImportFile(tester);

    expect(client.importPayloads, isEmpty);
    expect(find.textContaining('Imported "'), findsNothing);
  });

  testWidgets('a picker failure surfaces the error', (tester) async {
    final client = _RecordingCardsClient();
    addTearDown(client.dispose);
    await _pumpWithFile(
      tester,
      client,
      pickFile: () async => throw StateError('picker unavailable'),
    );

    await _tapImportFile(tester);

    expect(client.importPayloads, isEmpty);
    await _expectStatusText(
      tester,
      'Could not read the card file: Bad state: picker unavailable',
    );
  });

  testWidgets('the real picker is restricted to PNG and JSON files', (
    tester,
  ) async {
    final client = _RecordingCardsClient();
    addTearDown(client.dispose);
    final original = FilePickerPlatform.instance;
    final picker = _RecordingPicker()
      ..file = _PickedFile(
        'roundtrip.png',
        Uint8List.fromList(<int>[1, 2, 3]),
      );
    FilePickerPlatform.instance = picker;
    addTearDown(() => FilePickerPlatform.instance = original);

    await _pumpWithFile(tester, client);
    await _tapImportFile(tester);

    expect(picker.type, FileType.custom);
    expect(picker.allowedExtensions, <String>['json', 'png']);
    expect(client.importPayloads, <Map<String, dynamic>?>[
      <String, dynamic>{'pngBase64': base64Encode(<int>[1, 2, 3])},
    ]);
  });

  testWidgets('the paste flow still sends a card document', (tester) async {
    final client = _RecordingCardsClient();
    addTearDown(client.dispose);
    await _pumpWithFile(tester, client);

    final field = find.widgetWithText(
      TextField,
      'Card JSON (object or envelope)',
    );
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, '{"name":"Pasted"}');
    final import = find.widgetWithText(FilledButton, 'Import');
    await tester.ensureVisible(import);
    await tester.pumpAndSettle();
    await tester.tap(import);
    await tester.pumpAndSettle();

    expect(client.importPayloads, <Map<String, dynamic>?>[
      <String, dynamic>{'card': <String, dynamic>{'name': 'Pasted'}},
    ]);
  });
}
