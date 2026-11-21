# Design: Flutter control/chat a11y and i18n parity vs Vue

**Status:** design (E3-T7). **Bead:** `airi-wxp.3.7` (parent `airi-wxp.3` E3).
**Reference:** Vue web app (`apps/stage-web`, `apps/stage-tamagotchi`) remains the full-UI behaviour reference (E0-D1).

## 1. Surfaces and required labels

| Surface | File | Required semantics |
|---|---|---|
| Navigation shell | `lib/navigation/navigation_shell.dart` | `Semantics` label per `NavigationDestination` (Control/Chat/Settings/Connections/About); selected state announced. |
| Home | `lib/features/home/home_screen.dart` | Status rows labeled `label: value`; health card `Semantics` live region. |
| Chat | `lib/features/chat/chat_screen.dart` | Composer/TextField labeled; send button tooltip; deferred notice announced. |
| Settings | `lib/features/settings/settings_screen.dart` | ListTile titles as labels; disabled items marked `button: false`. |
| Connections | `lib/features/connections/connections_screen.dart` | Status card live region; error text `Semantics` error. |
| Connection form | `lib/connection/connection_settings_screen.dart` | Field labels, validation errors, derived endpoint announced. |
| About | `lib/features/about/about_screen.dart` | Headings as `header: true`. |

## 2. i18n key parity

Flutter uses ARB (`lib/l10n/app_en.arb`) keyed by the same leaf keys as `packages/i18n` where surfaces overlap (navigation, connection, status). Deferred full parity until surfaces land (3.2/3.3).

Initial keys (en): `nav.control`, `nav.chat`, `nav.settings`, `nav.connections`, `nav.about`, `status.gatewayHost`, `status.attempt`, `connection.host`, `connection.port`, `connection.token`, `connection.connect`, `connection.disconnect`.

## 3. Implementation notes

- Add `flutter_localizations` + `intl` when keys land; `MaterialApp.localizationsDelegates`.
- Wrap status text in `Semantics(liveRegion: true)`.
- Do not fork Vue business logic; daemon remains owner.

## 4. Verification

- `flutter analyze` 0 errors.
- Manual screen-reader pass on each surface.
- Key count diff vs Vue subset tracked in `docs/port-manifest/i18n-keys.md`.
