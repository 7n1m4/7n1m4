// SPDX-License-Identifier: GPL-3.0-or-later

// Option C (audio-file playback + PCM reader) deterministic harness from
// docs/decision-client-local-tts-pcm.md. Reads the RIFF/WAVE data chunk into
// interleaved f32 samples; no audio hardware, no codec dependency. Also usable
// as an asset/file source for a real client path until the on-device Piper
// synth lands.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'pcm_source.dart';

/// Minimal PCM WAVE reader: 8/16/24/32-bit integer PCM and 32/64-bit float.
class WavPcmSource implements PcmSource {
  WavPcmSource._({
    required this.sampleRate,
    required this.channels,
    required List<double> samples,
  }) : _samples = List<double>.unmodifiable(samples);

  /// Parse a complete WAVE file held in memory.
  factory WavPcmSource.fromBytes(Uint8List bytes) {
    if (bytes.length < 12 ||
        String.fromCharCodes(bytes.sublist(0, 4)) != 'RIFF' ||
        String.fromCharCodes(bytes.sublist(8, 12)) != 'WAVE') {
      throw const FormatException('not a RIFF/WAVE file');
    }

    final view = ByteData.sublistView(bytes);
    int? audioFormat;
    int? channels;
    int? sampleRate;
    int? bitsPerSample;
    Uint8List? data;

    var offset = 12;
    while (offset + 8 <= bytes.length) {
      final id = String.fromCharCodes(bytes.sublist(offset, offset + 4));
      final length = view.getUint32(offset + 4, Endian.little);
      final start = offset + 8;
      if (start + length > bytes.length) {
        throw const FormatException('truncated WAVE chunk');
      }
      switch (id) {
        case 'fmt ':
          if (length < 16) throw const FormatException('short WAVE fmt chunk');
          audioFormat = view.getUint16(start, Endian.little);
          channels = view.getUint16(start + 2, Endian.little);
          sampleRate = view.getUint32(start + 4, Endian.little);
          bitsPerSample = view.getUint16(start + 14, Endian.little);
        case 'data':
          data = Uint8List.sublistView(bytes, start, start + length);
      }
      // Chunks are word-aligned; odd-length chunks carry a pad byte.
      offset = start + length + (length.isOdd ? 1 : 0);
      if (data != null && audioFormat != null) break;
    }

    if (audioFormat == null ||
        channels == null ||
        channels == 0 ||
        sampleRate == null ||
        sampleRate == 0 ||
        bitsPerSample == null ||
        data == null) {
      throw const FormatException('WAVE missing fmt/data chunk');
    }

    return WavPcmSource._(
      sampleRate: sampleRate,
      channels: channels,
      samples: _decode(data, audioFormat, bitsPerSample),
    );
  }

  /// Read a WAVE file from disk.
  static Future<WavPcmSource> fromFile(String path) async =>
      WavPcmSource.fromBytes(await File(path).readAsBytes());

  @override
  final int sampleRate;

  @override
  final int channels;

  final List<double> _samples;

  @override
  Stream<double> open() => Stream<double>.fromIterable(_samples);

  static List<double> _decode(
    Uint8List data,
    int audioFormat,
    int bitsPerSample,
  ) {
    final view = ByteData.sublistView(data);
    final samples = <double>[];
    if (audioFormat == 3) {
      switch (bitsPerSample) {
        case 32:
          for (var i = 0; i + 4 <= data.length; i += 4) {
            samples.add(view.getFloat32(i, Endian.little));
          }
          return samples;
        case 64:
          for (var i = 0; i + 8 <= data.length; i += 8) {
            samples.add(view.getFloat64(i, Endian.little));
          }
          return samples;
      }
    } else if (audioFormat == 1) {
      switch (bitsPerSample) {
        case 8:
          // WAVE 8-bit PCM is unsigned with 128 as silence.
          for (final byte in data) {
            samples.add((byte - 128) / 128.0);
          }
          return samples;
        case 16:
          for (var i = 0; i + 2 <= data.length; i += 2) {
            samples.add(view.getInt16(i, Endian.little) / 32768.0);
          }
          return samples;
        case 24:
          for (var i = 0; i + 3 <= data.length; i += 3) {
            var value = data[i] | (data[i + 1] << 8) | (data[i + 2] << 16);
            if (value & 0x800000 != 0) value -= 0x1000000;
            samples.add(value / 8388608.0);
          }
          return samples;
        case 32:
          for (var i = 0; i + 4 <= data.length; i += 4) {
            samples.add(view.getInt32(i, Endian.little) / 2147483648.0);
          }
          return samples;
      }
    }
    throw FormatException(
      'unsupported WAVE format: format=$audioFormat bits=$bitsPerSample',
    );
  }
}
