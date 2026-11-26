// SPDX-License-Identifier: GPL-3.0-or-later

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../theme/app_theme.dart';
import 'third_party_notices.dart';

/// Static about page. No telemetry, no update checks (window chrome does not
/// move into the daemon per design-flutter-godot-pivot.md §4.1).
class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: const <Widget>[
        Card(
          color: AppTheme.surface,
          child: Padding(
            padding: EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text('Anima', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
                SizedBox(height: 8),
                Text('Full stage UI driven by anima-daemon.'),
                SizedBox(height: 12),
                Text(
                  'The daemon owns all core state. Flutter renders models natively '
                  'on desktop and mobile. The Vue web app remains the full-UI '
                  'behaviour reference.',
                ),
              ],
            ),
          ),
        ),
        ListTile(
          title: Text('Gateway protocol'),
          subtitle: Text('airi-channel/1 · JSON text frames · WS /ws :6121'),
        ),
        ListTile(
          title: Text('Design reference'),
          subtitle: Text('docs/design-flutter-godot-pivot.md'),
        ),
        ListTile(
          title: Text('License'),
          subtitle: Text('$projectLicenseSummary · texts bundled with this build'),
        ),
        AboutLinksSection(),
        _NoticesTile(),
      ],
    );
  }
}

/// Official links, kept in sync with
/// `apps/stage-tamagotchi/src/renderer/pages/about.vue:27-31` and
/// `packages/stage-ui/src/components/scenarios/about/about-content.vue:16-19`.
const List<({String label, String url, IconData icon})> aboutLinks =
    <({String label, String url, IconData icon})>[
  (
    label: 'Documentation',
    url: 'https://dasilva333.github.io/airi/en/docs/overview/',
    icon: Icons.description_outlined,
  ),
  (
    label: 'Web Stage',
    url: 'https://dasilva333.github.io/airi/web-stage/',
    icon: Icons.language,
  ),
  (
    label: 'GitHub',
    url: 'https://github.com/dasilva333/airi',
    icon: Icons.code,
  ),
];

typedef LaunchUrl = Future<bool> Function(Uri url);

/// Links-only slice: no build-info/`--dart-define` plumbing this wave.
///
/// [launch] is injectable so the exact URLs can be asserted without opening a
/// browser; production uses [_launchExternal].
class AboutLinksSection extends StatelessWidget {
  const AboutLinksSection({super.key, this.launch = _launchExternal});

  final LaunchUrl launch;

  static Future<bool> _launchExternal(Uri url) =>
      launchUrl(url, mode: LaunchMode.externalApplication);

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Text(
            'Links',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
          ),
        ),
        for (final ({String label, String url, IconData icon}) link in aboutLinks)
          ListTile(
            leading: Icon(link.icon),
            title: Text(link.label),
            subtitle: Text(link.url),
            onTap: () => launch(Uri.parse(link.url)),
          ),
      ],
    );
  }
}

/// Opens the bundled notice set. The assets are declared in
/// `apps/flutter/pubspec.yaml`, so this resolves inside an AAB/IPA with no
/// network and no repository checkout.
class _NoticesTile extends StatelessWidget {
  const _NoticesTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.description_outlined),
      title: const Text('Third-party notices'),
      subtitle: const Text('Bundled license texts and distribution notices'),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (BuildContext context) => const ThirdPartyNoticesScreen(),
        ),
      ),
    );
  }
}

/// In-app access path for the bundled notice set and license texts.
class ThirdPartyNoticesScreen extends StatelessWidget {
  const ThirdPartyNoticesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Third-party notices')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: <Widget>[
          const Text(
            'The distribution notice set ships inside this build as '
            '$thirdPartyNoticesAssetPath. Verbatim license texts ship beside it '
            'under $licenseTextsAssetDirectory.',
          ),
          const SizedBox(height: 12),
          for (final String fact in distributionNoticeFacts)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(fact),
            ),
          const Divider(),
          for (final BundledLicenseNotice notice in bundledLicenseNotices)
            ListTile(
              leading: const Icon(Icons.article_outlined),
              title: Text(notice.fileName),
              subtitle: Text(notice.covers),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => _openText(context, notice),
            ),
        ],
      ),
    );
  }
}

Future<void> _openText(
  BuildContext context,
  BundledLicenseNotice notice,
) async {
  final String text = await rootBundle.loadString(notice.assetPath);
  if (!context.mounted) return;
  await Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(notice.fileName)),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: SelectableText(text),
        ),
      ),
    ),
  );
}
