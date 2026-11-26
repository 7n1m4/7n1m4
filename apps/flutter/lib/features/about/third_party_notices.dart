// SPDX-License-Identifier: GPL-3.0-or-later

// Static licensing policy for the mobile client. No telemetry, no update
// checks, no daemon state: the facts below are properties of the shipped
// artifact, so they live in the client rather than in daemon-owned settings.
//
// The authoritative notice set is `THIRD_PARTY_NOTICES.md` plus the verbatim
// texts in `LICENSES/` at the repository root. Both are declared as bundled
// assets of this client (`apps/flutter/pubspec.yaml`), so an AAB or IPA built
// by `.github/workflows/release-flutter-mobile.yml` carries them inside the
// app bundle and [thirdPartyNoticesAssetPath] / [licenseTextAssetPath] resolve
// on device with no network and no repository checkout.

/// Bundled path of the distribution notice set.
const String thirdPartyNoticesAssetPath =
    'assets/notices/THIRD_PARTY_NOTICES.md';

/// Bundled directory of verbatim license texts.
const String licenseTextsAssetDirectory = 'assets/notices/LICENSES';

/// Verbatim text of one entry of `LICENSES/`, e.g. `GPL-3.0-or-later.txt`.
String licenseTextAssetPath(String fileName) =>
    '$licenseTextsAssetDirectory/$fileName';

/// The license that governs this client and the combined work.
const String projectLicenseSummary = 'GPL-3.0-or-later';

/// One bundled license text, as shown in the in-app notice list.
class BundledLicenseNotice {
  const BundledLicenseNotice({required this.fileName, required this.covers});

  /// File name inside [licenseTextsAssetDirectory].
  final String fileName;

  /// What the text applies to, in the client's own words.
  final String covers;

  String get assetPath => licenseTextAssetPath(fileName);
}

/// The texts a recipient of an AAB/IPA may need, in reading order.
const List<BundledLicenseNotice> bundledLicenseNotices = <BundledLicenseNotice>[
  BundledLicenseNotice(
    fileName: 'GPL-3.0-or-later.txt',
    covers: 'This client, the anima-daemon it talks to, and the combined work.',
  ),
  BundledLicenseNotice(
    fileName: 'MIT.txt',
    covers: 'Repository-level TypeScript/JavaScript packages and plugins.',
  ),
  BundledLicenseNotice(
    fileName: 'BSD-3-Clause.txt',
    covers: 'Flutter SDK packages (Copyright 2013 The Flutter Authors).',
  ),
  BundledLicenseNotice(
    fileName: 'Apache-2.0.txt',
    covers: 'Apache-2.0 components, including a2ui_core.',
  ),
  BundledLicenseNotice(
    fileName: 'ISC.txt',
    covers: 'The `yaml` package (Eemeli Aro).',
  ),
  BundledLicenseNotice(
    fileName: 'OFL-1.1.txt',
    covers: 'Bundled fonts; per-font copyright is recorded in the notice set.',
  ),
  BundledLicenseNotice(
    fileName: 'Spine-Runtimes-License-Agreement-2025-04-05.txt',
    covers:
        'Spine Runtimes 4.2 line (Copyright 2013-2025, Esoteric Software LLC).',
  ),
  BundledLicenseNotice(
    fileName: 'Spine-Runtimes-License-Agreement-2019-05-01.txt',
    covers: 'Spine Runtimes 4.0/4.1 lines (Copyright 2013-2019, Esoteric Software LLC).',
  ),
];

/// Facts the notice set records that a user of a build must be told.
const List<String> distributionNoticeFacts = <String>[
  'Every user of a build that embeds the Spine Runtimes must hold their own '
      'Spine Editor license; redistribution must carry the copyright notice '
      'and the full agreement text.',
  'No character model is bundled. VRM, PMX/PMD, VMD and Spine skeleton sets are '
      'user-supplied, and the user is responsible for the license of every '
      'asset they load.',
  'Live2D / Cubism notices and binaries are deliberately not shipped; the model '
      'kind stays blocked until the maintainer records the legal review as '
      'resolved (docs/design-live2d-legal-gate.md).',
];
