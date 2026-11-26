# Bundled distribution notices (GPL-3.0-or-later)

`THIRD_PARTY_NOTICES.md` and `LICENSES/*.txt` are byte-identical copies of the
repository-root notice set (`/THIRD_PARTY_NOTICES.md`, `/LICENSES/`). They are
declared as Flutter assets in `apps/flutter/pubspec.yaml` so a release AAB or
IPA built by `.github/workflows/release-flutter-mobile.yml` carries the notices
inside the app bundle; `apps/flutter/lib/features/about/about_screen.dart` reads
them through `rootBundle`.

Do not edit a copy here. Change the repository-root files and re-copy, or the
in-app text and the repository text will disagree.

Live2D / Cubism notices are deliberately absent; see §7 of the notice set and
`docs/design-live2d-legal-gate.md`.