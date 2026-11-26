// SPDX-License-Identifier: GPL-3.0-or-later

// Ports around the native file picker. The DataScreen injects these so widget
// tests can exercise the whole flow without opening real OS dialogs.

import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';

/// A native-file-picker interaction: pick a `.jsonl` file to import, or choose
/// where to save an exported `.jsonl` file. The ZIP methods carry the full
/// vault archive; the same ports are injected in widget tests.
abstract interface class VaultFilePorts {
  Future<PlatformFile?> pickJsonl();
  Future<Uri?> saveJsonl(String fileName, Uint8List bytes);
  Future<PlatformFile?> pickZip();
  Future<Uri?> saveZip(String fileName, Uint8List bytes);
}

VaultFilePorts _vaultFilePorts = const NativeVaultFilePorts();
VaultFilePorts get vaultFilePorts => _vaultFilePorts;
set vaultFilePorts(VaultFilePorts ports) => _vaultFilePorts = ports;

/// Production implementation backed by `file_picker`.
class NativeVaultFilePorts implements VaultFilePorts {
  const NativeVaultFilePorts();

  @override
  Future<PlatformFile?> pickJsonl() => FilePicker.pickFile(
        dialogTitle: 'Import chat session (JSONL)',
        type: FileType.custom,
        allowedExtensions: <String>['jsonl'],
      );

  @override
  Future<Uri?> saveJsonl(String fileName, Uint8List bytes) =>
      FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/x-ndjson',
        dialogTitle: 'Export chat session',
      );

  @override
  Future<PlatformFile?> pickZip() => FilePicker.pickFile(
        dialogTitle: 'Import vault archive (ZIP)',
        type: FileType.custom,
        allowedExtensions: <String>['zip'],
      );

  @override
  Future<Uri?> saveZip(String fileName, Uint8List bytes) => FilePicker.saveFile(
        fileName: fileName,
        bytes: bytes,
        mimeType: 'application/zip',
        dialogTitle: 'Export vault archive',
      );
}
