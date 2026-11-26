// SPDX-License-Identifier: GPL-3.0-or-later

// Vault status, per-session JSONL import/export, full-vault archive
// export/import and history media scrub. Every action goes through a typed
// daemon client wrapper; nothing is reported as successful unless the daemon
// replied successfully.

import 'dart:convert';

import 'package:flutter/material.dart';

import '../../connection/connection_error.dart';
import '../../daemon_client/daemon_client.dart';
import 'daemon_vault_ports.dart' show VaultFilePorts, vaultFilePorts;

class DataScreen extends StatefulWidget {
  const DataScreen({super.key, required this.client});
  final DaemonClient client;

  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  VaultFilePorts get _files => vaultFilePorts;

  final List<Map<String, dynamic>> _sessions = <Map<String, dynamic>>[];
  Map<String, dynamic>? _vault;
  bool _busy = false;
  String? _error;
  String? _status;
  static const Key _statusKey = Key('data-status');

  /// Local guard matching the daemon's decoded archive limit. Enforced before
  /// a picked file is read into memory and base64-encoded for the wire.
  static const int _maxArchiveBytes = (1024 * 1024 - 8192) * 3 ~/ 4;
  /// The daemon accepts JSONL inside one WebSocket frame; leave room for the
  /// JSON-RPC envelope and the 4/3 base64 expansion of the decoded payload.
  static const int _maxImportBytes = (1024 * 1024 - 8192) * 3 ~/ 4;
  /// Mirrors the daemon's `VAULT_ARCHIVE_DOMAINS` (gateway.rs): `providers`
  /// carries API credentials and must never be offered for archive export.
  static const List<String> _archiveDomains = <String>[
    'characters',
    'chats',
    'memory',
    'backgrounds',
  ];
  static const Map<String, String> _archiveDomainLabels = <String, String>{
    'characters': 'Characters',
    'chats': 'Chat sessions',
    'memory': 'Memory',
    'backgrounds': 'Backgrounds',
  };
  /// All domains are selected by default: existing exports stay unchanged.
  final Set<String> _selectedArchiveDomains = _archiveDomains.toSet();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final vault = await widget.client.vaultStatus();
      final sessions = await widget.client.sessionsList();
      if (!mounted) return;
      setState(() {
        _vault = vault;
        _sessions
          ..clear()
          ..addAll(sessions);
      });
      _loadVaultAvailability(vault);
    } on DaemonClientException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportSession(Map<String, dynamic> session) async {
    final id = (session['id'] as String?) ?? '';
    if (id.isEmpty) {
      _fail('Cannot export a session without an id.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final jsonl = await widget.client.sessionsExport(id);
      if (!mounted) return;
      if (jsonl.trim().isEmpty) {
        setState(() => _error = 'Session $id exported no data; nothing was saved.');
        return;
      }
      final title = (session['title'] as String?) ?? id;
      final saved = await _files.saveJsonl(
        'airi-session-${_safeFileName(title)}.jsonl',
        utf8.encode(jsonl),
      );
      if (!mounted) return;
      final status = saved == null
          ? 'Export cancelled: session $id was not saved.'
          : 'Exported session $id to ${saved.path.isEmpty ? saved : saved.path}';
      setState(() => _status = status);
    } on DaemonClientException catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail('Could not save the export: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _importSession() async {
    setState(() {
      _error = null;
      _status = null;
    });
    final picked = await _files.pickJsonl();
    if (!mounted || picked == null) {
      if (mounted) setState(() => _status = 'Import cancelled; no file was selected.');
      return;
    }
    setState(() => _busy = true);
    try {
      // Check the picker's reported length before the read: a corrupt or
      // malicious file must not be pulled into memory just to be rejected.
      final size = await picked.length();
      if (!mounted) return;
      if (size == null) {
        _fail('Could not check ${picked.name}; nothing was imported.');
        return;
      }
      if (size == 0) {
        _fail('${picked.name} is empty; nothing was imported.');
        return;
      }
      if (size > _maxImportBytes) {
        _fail('${picked.name} exceeds the $_maxImportBytes byte import limit; '
            'nothing was imported.');
        return;
      }
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      // Re-check after reading: the picker length may have been stale.
      if (bytes.length > _maxImportBytes) {
        _fail('${picked.name} exceeds the $_maxImportBytes byte import limit; '
            'nothing was imported.');
        return;
      }
      final reply = await widget.client.call(
        'sessions.import',
        payload: <String, dynamic>{'jsonl': utf8.decode(bytes, allowMalformed: false)},
      );
      if (!mounted) return;
      if (!reply.ok) {
        setState(() => _error = reply.error?.message ?? 'sessions.import failed.');
        return;
      }
      final data = reply.data is Map<String, dynamic>
          ? reply.data as Map<String, dynamic>
          : null;
      final importStatus = data?['status']?.toString() ?? 'unknown';
      final revision = data?['revision']?.toString() ?? '?';
      if (importStatus == 'applied') {
        setState(() => _status = 'Imported ${picked.name} (revision $revision).');
        await _load();
      } else if (mounted) {
        setState(() => _status =
            '${picked.name} was not applied ($importStatus, revision $revision).');
      }
    } on DaemonClientException catch (e) {
      _fail(e.message);
    } on FormatException catch (e) {
      _fail('${picked.name} is not valid UTF-8: ${e.message}');
    } catch (e) {
      _fail('Could not read ${picked.name}: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _loadVaultAvailability(Map<String, dynamic>? vault) {
    if (vault == null || vault['available'] != true) {
      _fail('Vault is not available on this daemon.');
    }
  }

  void _fail(String message) {
    if (mounted) setState(() => _error = message);
  }

  static String _safeFileName(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '-');
    return cleaned.isEmpty ? 'session' : cleaned;
  }

  void _toggleArchiveDomain(String domain, bool? selected) {
    if (!_archiveDomains.contains(domain)) return;
    setState(() {
      if (selected == true) {
        _selectedArchiveDomains.add(domain);
      } else {
        _selectedArchiveDomains.remove(domain);
      }
    });
  }

  /// Only report a size the daemon actually returned in `vault.status`.
  static String? _reportedBytes(Map<String, dynamic>? stats, String domain) {
    final value = stats?[domain];
    if (value is! Map<String, dynamic>) return null;
    final bytes = value['bytes'];
    if (bytes is! num) return null;
    return '${bytes.toInt()} B';
  }

  Widget _archiveDomainTile(String domain, Map<String, dynamic>? stats) {
    final bytes = _reportedBytes(stats, domain);
    return CheckboxListTile(
      key: Key('data-archive-domain-$domain'),
      dense: true,
      value: _selectedArchiveDomains.contains(domain),
      onChanged: _busy ? null : (bool? value) => _toggleArchiveDomain(domain, value),
      title: Text(_archiveDomainLabels[domain] ?? domain),
      secondary: bytes == null ? null : Text(bytes),
    );
  }

  Future<void> _exportVault() async {
    // Order and membership come from the allowlist, never from raw UI state.
    final domains = _archiveDomains.where(_selectedArchiveDomains.contains).toList();
    if (domains.isEmpty) {
      _fail('Select at least one vault domain to export.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final archive = await widget.client.vaultArchiveCollect(domains);
      if (!mounted) return;
      final bytes = base64.decode(archive.archive);
      if (bytes.length > _maxArchiveBytes) {
        _fail('The daemon archive exceeds the $_maxArchiveBytes byte limit; nothing was saved.');
        return;
      }
      final saved = await _files.saveZip('airi-vault-archive.zip', bytes);
      if (!mounted) return;
      if (saved == null) {
        setState(() => _status = 'Archive export cancelled; nothing was saved.');
        return;
      }
      setState(() => _status =
          'Exported ${bytes.length} archive bytes to ${saved.path.isEmpty ? saved : saved.path}.');
    } on FormatException {
      _fail('The daemon returned an invalid archive; nothing was saved.');
    } on DaemonClientException catch (e) {
      _fail(userSafeConnectionError(e, context: 'vault.archive.collect:'));
    } catch (e) {
      _fail(userSafeConnectionError(e, context: 'vault.archive.export:'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Pick a ZIP, check its size locally, then inspect it. Only the typed,
  /// metadata-only report is shown; archive entries are never rendered here.
  Future<void> _importVault() async {
    setState(() {
      _error = null;
      _status = null;
    });
    final picked = await _files.pickZip();
    if (!mounted || picked == null) {
      if (mounted) setState(() => _status = 'Archive import cancelled; no file was selected.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final size = picked.lengthSync() ?? await picked.length();
      if (size == null) {
        _fail('Could not check ${picked.name} size; nothing was imported.');
        return;
      }
      if (size == 0) {
        _fail('${picked.name} is empty; nothing was imported.');
        return;
      }
      if (size > _maxArchiveBytes) {
        _fail('${picked.name} exceeds the $_maxArchiveBytes byte limit; nothing was imported.');
        return;
      }
      final bytes = await picked.readAsBytes();
      if (!mounted) return;
      if (bytes.isEmpty) {
        _fail('${picked.name} is empty; nothing was imported.');
        return;
      }
      if (bytes.length > _maxArchiveBytes) {
        _fail('${picked.name} exceeds the $_maxArchiveBytes byte limit; nothing was imported.');
        return;
      }
      // Encode only after both local size checks. No provider field is ever
      // added to this payload; the daemon rejects secret-bearing archives.
      final encoded = base64.encode(bytes);
      final inspection = await widget.client.vaultArchiveInspect(encoded);
      if (!mounted) return;
      if (inspection.includesSecrets) {
        _fail('${picked.name} advertises provider credentials; nothing was imported.');
        return;
      }
      if (inspection.format != 'airi-vault') {
        _fail('${picked.name} is not an airi-vault archive; nothing was imported.');
        return;
      }
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Import vault archive?'),
          content: Text(
            '${picked.name}: format ${inspection.format} v${inspection.version}, '
            '${inspection.sessionCount} sessions, ${inspection.messageCount} messages, '
            '${inspection.domains.length} domain records, '
            '${inspection.companionCount} companions. '
            'Existing rows are kept; no credentials are included. Continue?',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Import'),
            ),
          ],
        ),
      );
      if (confirmed != true) {
        if (mounted) setState(() => _status = 'Archive import cancelled; nothing was imported.');
        return;
      }
      final applied = await widget.client.vaultArchiveApply(encoded);
      if (!mounted) return;
      setState(() => _status =
          'Imported ${picked.name}: ${applied.sessionsInserted} sessions and '
          '${applied.messagesInserted} messages added, '
          '${applied.sessionsSkipped} sessions and '
          '${applied.messagesSkipped} messages skipped.');
      await _load();
    } on DaemonClientException catch (e) {
      _fail(userSafeConnectionError(e, context: 'vault.archive.apply:'));
    } catch (e) {
      _fail(userSafeConnectionError(e, context: 'vault.archive.import:'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Scrubbing is destructive to inline message images, so the user must make
  /// an explicit backup choice before the gated verb is called.
  Future<void> _scrubHistory() async {
    final backup = await showDialog<bool?>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Scrub session media?'),
        content: const Text(
          'Inline images are extracted to the local backgrounds store and '
          'removed from messages. Choose whether to write a pre-scrub vault '
          'backup first. Nothing changes until you choose.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Scrub without backup'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Back up and scrub'),
          ),
        ],
      ),
    );
    if (backup == null || !mounted) {
      if (mounted) setState(() => _status = 'History scrub cancelled; no data was changed.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _status = null;
    });
    try {
      final result = await widget.client.sessionsMediaScrub(createBackup: backup);
      if (!mounted) return;
      final backupText = result.backupPath == null || result.backupPath!.isEmpty
          ? ''
          : ' Backup: ${result.backupPath}';
      setState(() => _status =
          'Scrubbed ${result.sessionsScanned} sessions: '
          '${result.imagesFound} images extracted, '
          '${result.bytesExtracted} bytes written.$backupText');
      await _load();
    } on DaemonClientException catch (e) {
      _fail(userSafeConnectionError(e, context: 'sessions.media.scrub:'));
    } catch (e) {
      _fail(userSafeConnectionError(e, context: 'sessions.media.scrub:'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final stats = _vault?['stats'] is Map<String, dynamic>
        ? _vault!['stats'] as Map<String, dynamic>
        : null;
    final chats = stats?['chats'];
    final memory = stats?['memory'];
    return Scaffold(
      appBar: AppBar(
        title: const Text('Data'),
        actions: <Widget>[
          IconButton(
            key: const Key('data-refresh'),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh vault status',
            onPressed: _busy ? null : _load,
          ),
        ],
      ),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _load,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: <Widget>[
                  if (_error != null)
                    Text(
                      key: const Key('data-error'),
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  if (_status != null)
                    Text(key: _statusKey, _status!),
                  const ListTile(
                    title: Text('Vault status'),
                    dense: true,
                  ),
                  ListTile(
                    key: const Key('data-vault-available'),
                    title: const Text('Available'),
                    trailing: Text(_vault?['available'] == true ? 'yes' : 'no'),
                  ),
                  if (chats is Map<String, dynamic>) ...<Widget>[
                    ListTile(title: const Text('Chat sessions'), trailing: Text(chats['sessions']?.toString() ?? '—')),
                    ListTile(title: const Text('Chat messages'), trailing: Text(chats['messages']?.toString() ?? '—')),
                  ],
                  if (memory is Map<String, dynamic>) ...<Widget>[
                    ListTile(title: const Text('Summaries'), trailing: Text(memory['summaries']?.toString() ?? '—')),
                    ListTile(title: const Text('Journal entries'), trailing: Text(memory['journalEntries']?.toString() ?? '—')),
                  ],
                  const Divider(),
                  const ListTile(title: Text('Chat session backup'), dense: true),
                  const Text(
                    'Export writes one session as a JSONL file. Import restores a '
                    'JSONL snapshot; conflicts leave local data untouched.',
                  ),
                  const SizedBox(height: 8),
                  FilledButton.icon(
                    key: const Key('data-import-session'),
                    onPressed: _busy ? null : _importSession,
                    icon: const Icon(Icons.file_upload),
                    label: const Text('Import chat session JSONL'),
                  ),
                  const ListTile(title: Text('Sessions'), dense: true),
                  if (_sessions.isEmpty)
                    const ListTile(title: Text('No sessions to export'), dense: true)
                  else
                    for (final session in _sessions)
                      ListTile(
                        key: ValueKey<String>('data-session-${session['id'] ?? ''}'),
                        title: Text((session['title'] as String?) ?? (session['id'] as String?) ?? ''),
                        subtitle: Text((session['id'] as String?) ?? ''),
                        trailing: IconButton(
                          key: Key('data-export-${session['id'] ?? ''}'),
                          icon: const Icon(Icons.download),
                          tooltip: 'Export session as JSONL',
                          onPressed: _busy ? null : () => _exportSession(session),
                        ),
                      ),
                  const Divider(),
                  const ListTile(title: Text('Vault archive'), dense: true),
                  const Text(
                    'Select the domains to include in the ZIP. Provider '
                    'credentials are always excluded. Import inspects metadata '
                    'first and never applies an archive that advertises secrets.',
                  ),
                  const SizedBox(height: 8),
                  for (final domain in _archiveDomains)
                    _archiveDomainTile(domain, stats),
                  OutlinedButton(
                    key: const Key('data-export-vault'),
                    onPressed: _busy ? null : _exportVault,
                    child: const Text('Export vault archive'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const Key('data-import-vault'),
                    onPressed: _busy ? null : _importVault,
                    child: const Text('Import vault archive'),
                  ),
                  const Divider(),
                  const ListTile(title: Text('Session media scrub'), dense: true),
                  const Text(
                    'Extract inline images to the local backgrounds store. '
                    'Choose whether to write a backup before scrubbing.',
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton(
                    key: const Key('data-scrub-history'),
                    onPressed: _busy ? null : _scrubHistory,
                    child: const Text('Scrub history'),
                  ),
                ],
              ),
            ),
    );
  }
}
