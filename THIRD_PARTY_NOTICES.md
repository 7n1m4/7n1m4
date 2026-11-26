# Third-party notices

Status: shipped notice set, 2026-11-25 (bead `airi-7nzd`). This file is the
distribution notice set for AIRI binaries and packages. Verbatim license texts
live in [`LICENSES/`](LICENSES/); this file says which text applies to which
part of the product and records the notices that must travel with a build.

## 1. Scope, and what is deliberately absent

Covered here: the Spine Runtimes (C++ runtime vendored in-tree and the npm
runtimes), user-supplied model/asset notices, plugin notices, GPL notices for
the Rust workspace and the Flutter client, and bundled font notices.

**Live2D / Cubism notices are deliberately NOT shipped.** Live2D is hard-blocked
in this client until the maintainer records the legal/release review as
resolved; the proprietary Cubism Core is user-fetched after the user accepts the
Live2D terms and is never committed. The policy is
[`docs/design-live2d-legal-gate.md`](docs/design-live2d-legal-gate.md) (bead
`airi-l4qa`). Do not add Live2D or Cubism notices to this file, to `LICENSES/`
or to any build artifact until the maintainer records that review as resolved.
Section 7 records the pointer only.

## 2. Project licensing

| Part of the product | License | Text |
| --- | --- | --- |
| Rust workspace (`crates/anima-*`, `Cargo.toml`) | GPL-3.0-or-later | `LICENSES/GPL-3.0-or-later.txt` |
| Flutter client (`apps/flutter/lib/**`, `apps/flutter/android`, `apps/flutter/ios`) | GPL-3.0-or-later | `LICENSES/GPL-3.0-or-later.txt` |
| Flutter plugin `packages/flutter_anima_render` | GPL-3.0-or-later (links the GPL crates) | `packages/flutter_anima_render/LICENSE` |
| TypeScript/JavaScript packages (`packages/**`, `apps/stage-*`, `apps/server`, `plugins/**`) and the repository root | MIT, Copyright (c) 2024-PRESENT Neko Ayaka | `LICENSES/MIT.txt` |
| Bundled fonts | SIL Open Font License 1.1 | `LICENSES/OFL-1.1.txt` (per-font copyright in §6) |

`packages/server-shared/src/types/generated/anima-channel.ts` is generated from
the GPL Rust wire types and carries `SPDX-License-Identifier:
GPL-3.0-or-later`; it stays under the GPL despite living in a MIT package.

## 3. Spine Runtimes

Copyright (c) 2013-2025, Esoteric Software LLC. The Spine Runtimes are **not**
covered by the MIT license above and may not be relicensed under it.

What is shipped:

- Vendored C++ runtime (`spine-cpp` only, no editor, no sample projects), pinned
  in [`third-party/spine-runtimes/VERSIONS.md`](third-party/spine-runtimes/VERSIONS.md):
  `4.0.64/` (tag `4.0.64`), `4.1.00/` (tag `4.1.00`), `4.2/` (branch `4.2` @
  `5cb78e77d3711ddcd80c7bd043bb11cf70fcc88c`). Each tree keeps its own
  `LICENSE`; those files are the license text for that line and are read-only.
  `crates/anima-render/build.rs` compiles exactly one line, selected by
  `AIRI_SPINE_RUNTIME` (default `4.2`).
- npm runtimes in `node_modules` via pnpm: `@esotericsoftware/spine-webgl` and
  `@esotericsoftware/spine-core` at `4.0.31`, `4.1.56` and `4.2.114`
  (`packages/stage-ui-spine/src/utils/spine-runtime.ts` lazy-loads one line per
  skeleton version).

License texts:

- 2025-04-05 text, Copyright (c) 2013-2025: `LICENSES/Spine-Runtimes-License-Agreement-2025-04-05.txt`
  (verbatim copy of `third-party/spine-runtimes/4.2/LICENSE`; the npm `4.2.114`
  package text is the same agreement, differing only in `http` versus `https`
  in the editor-license URL).
- 2019-05-01 text, Copyright (c) 2013-2019: `LICENSES/Spine-Runtimes-License-Agreement-2019-05-01.txt`
  (verbatim copy of `third-party/spine-runtimes/4.0.64/LICENSE`, identical to
  `4.1.00/LICENSE` and to the npm `4.0.31`/`4.1.56` package texts).

User editor-license notice, verbatim from the agreement:

> Integration of the Spine Runtimes into software or otherwise creating
> derivative works of the Spine Runtimes is permitted under the terms and
> conditions of Section 2 of the Spine Editor License Agreement:
> https://esotericsoftware.com/spine-editor-license
>
> Otherwise, it is permitted to integrate the Spine Runtimes into software
> or otherwise create derivative works of the Spine Runtimes (collectively,
> "Products"), provided that each user of the Products must obtain their own
> Spine Editor license and redistribution of the Products in any form must
> include this license and copyright notice.

The practical consequence for a build: every user of a Product that embeds the
Spine Runtimes must hold their own Spine Editor license, and any redistribution
must carry the copyright notice and the full agreement text. The in-tree
reference is `packages/stage-ui-spine/LICENSE.md` (MIT for the package's own
code, Spine Runtimes excluded).

Links: <https://esotericsoftware.com/spine-runtimes-license>,
<https://esotericsoftware.com/spine-editor-license>.

## 4. User-supplied assets

No character model is committed to or downloaded by this repository. VRM,
PMX/PMD, VMD and Spine skeleton/atlas/texture sets are supplied by the user, and
the user is responsible for the license of every asset they load. The client
never redistributes them and never guesses a license for them.

- MMD models are usually redistribution-restricted; this is stated at the parser
  boundary in `crates/anima-mmd/src/lib.rs:57-59` ("No model is committed or
  downloaded — the user supplies one locally (MMD models are usually
  redistribution-restricted)").
- The runtime surfaces the same fact to the user: `licenseNote` in
  `apps/flutter/lib/features/stage/model_runtime.dart` says VRM assets are
  user-supplied and that PMX/VMD models are usually redistribution-restricted.
- Live tests are env-gated on a user-supplied path (`AIRI_TEST_MMD_MODEL`,
  `AIRI_TEST_MMD_ZIP`); nothing is fetched.

Bundled motions: the 14 `.vmd` files in
`apps/stage-tamagotchi/src/renderer/public/assets/mmd/animations/` (mirrored at
`apps/stage-web/public/assets/mmd/animations/`) are in-tree AIRI assets, shipped
with the repository under GPL-3.0-or-later and carrying no separate license
file. Each file's VMD header model-name field names a third-party model that is
**not** distributed here — `Tonio 1.01`, `初音ミクver2 ちび`, `LOLA`,
`Sweet Ann Yoi`, `Meme-chan`, `Bruno`, `Big-AL v1.00`, `LUKA v4x`, `Mermaid`,
`Dex (Kemonomimi)`, `LEON`, `Luka base`, `hzeo式KAITOV3ver2.03`,
`Daina (Kemonomimi)`. The motions are authored for models that are absent from
this repository; the names are recorded here so no reader mistakes them for
bundled models. The Spine fixture `assets/test-models/synthetic/` is likewise
synthetic and in-tree.

## 5. Plugin, GPL and dependency notices

Exact versions are governed by `pnpm-lock.yaml`, `Cargo.lock` and
`apps/flutter/pubspec.lock`; the list below names the components and their
license families, not a frozen version set.

Browser extension (`plugins/anima-plugin-web-extension`, WXT + Vue + UnoCSS +
`@iconify-json/*` + `nanoid` + `@proj-anima/server-sdk`): MIT. The extension
talks to the GPL daemon over the gateway; it is a separate process and is not a
derivative work of the GPL crates.

Web stage and renderer dependencies:

| Component | License | Text |
| --- | --- | --- |
| `three` (`0.183.1`), `three-stdlib` | MIT | `LICENSES/MIT.txt` |
| `@pixiv/three-vrm` (pixiv Inc. 2019-2026) | MIT | `LICENSES/MIT.txt` |
| `@moeru/three-mmd` (three.js authors + Moeru AI) | MIT | `LICENSES/MIT.txt` |
| `@pixi/core`, `@pixi/app` and the other `@pixi/*` 6.x packages; `pixi-filters` | MIT (Mathew Groves, Chad Engler) | `LICENSES/MIT.txt` |
| `pixi-live2d-display` | MIT — **Live2D, gated, see §7** | `LICENSES/MIT.txt` |
| `onnxruntime-web` / `onnxruntime-common` | MIT | `LICENSES/MIT.txt` |
| `@mediapipe/tasks-vision` | Apache-2.0 | `LICENSES/Apache-2.0.txt` |
| `@huggingface/transformers` | Apache-2.0 | `LICENSES/Apache-2.0.txt` |
| `localforage` | Apache-2.0 | `LICENSES/Apache-2.0.txt` |
| `jszip` | MIT OR GPL-3.0-or-later | `LICENSES/MIT.txt`, `LICENSES/GPL-3.0-or-later.txt` |
| `ammojs-typed`, `wlipsync` | MIT | `LICENSES/MIT.txt` |
| `vue`, `pinia`, `@vueuse/*`, `reka-ui`, `@formkit/auto-animate`, `nanoid`, `driver.js`, `html2canvas`, `node-vibrant`, `nprogress`, `hono`, `@moeru/eventa`, `@moeru/std`, `@xsai-ext/providers`, `@xsai/generate-speech`, `es-toolkit`, `@tresjs/core` | MIT | `LICENSES/MIT.txt` |
| `yaml` (Eemeli Aro) | ISC | `LICENSES/ISC.txt` |

Flutter client dependencies (`apps/flutter/pubspec.lock`), with the license of
the locked version:

| Component (locked version) | License | Text |
| --- | --- | --- |
| `genui`, `path_provider*`, `url_launcher*`, `flutter_markdown_plus`, Flutter SDK | BSD-3-Clause | `LICENSES/BSD-3-Clause.txt` |
| `a2ui_core` `0.1.1` | Apache-2.0 | `LICENSES/Apache-2.0.txt` plus its bundled `eval/bin/transcrypt` MIT notice (Copyright 2019-2025 James Murty, Copyright 2014-2020 Aaron Bull Schaefer) reproduced in §5.1 |
| `audioplayers*` | MIT (Blue Fire) | `LICENSES/MIT.txt` |
| `dbus` `0.8.1` | MPL-2.0 | `LICENSES/MPL-2.0.txt` |
| `xml` `7.1.0` | MIT (Copyright (c) 2006-2026 Lukas Renggli) | `LICENSES/MIT.txt` |

The shipped `LICENSES/BSD-3-Clause.txt` is the `path_provider` text,
Copyright 2013 The Flutter Authors; other Flutter Authors packages carry the
same terms with their own year (e.g. `genui` 2025). `a2ui_core` is **not**
BSD-3-Clause: `pubspec.lock` pins `0.1.1`, whose LICENSE is the Apache License
2.0 with an appended MIT notice for `eval/bin/transcrypt`. `dbus` `0.8.1` is
MPL-2.0 (not BSD-3-Clause), and `xml` `7.1.0` is MIT (not ISC); `yaml` is the
ISC package in the web stage table above. All four texts ship in the mobile
notice assets.

### 5.1 Bundled `a2ui_core` MIT notice (verbatim)

```
The file eval/bin/transcrypt is licensed under the MIT License:

Copyright (c) 2019-2025 James Murty <james@murty.co>
Copyright (c) 2014-2020 Aaron Bull Schaefer <aaron@elasticdog.com>

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

Rust dependencies are the usual GPL-3.0-or-later-compatible set (`anyhow`,
`serde`, `tokio`, `rusqlite` with bundled SQLite, `reqwest`/`rustls`, `gltf`,
`image`, `zip`, `sha2`, `rodio`, `ort`, `tokenizers`, `tungstenite`,
`tray-item`, `notify-rust`, `tempfile`, …); see `Cargo.lock`. The GPL-3.0-or-later
text is `LICENSES/GPL-3.0-or-later.txt` and covers the combined work.

## 6. Fonts

All bundled fonts are SIL Open Font License 1.1; the license body is
`LICENSES/OFL-1.1.txt` (verbatim from `packages/font-cjkfonts-allseto/license.txt`,
from the `---` separator onward). Copyright statements, which the OFL requires
to travel with each copy:

- **cjkFonts 全瀨體 / allseto** (`packages/font-cjkfonts-allseto`,
  `src/files/cjkFonts_allseto_v1.11.ttf`) — Copyright (c) 2020, redistributed by
  cjkFonts.io, Reserved Font Names `cjkFonts 全瀨體` and `全瀨體`.
- **Xiaolai 小赖字体** (`packages/font-xiaolai`,
  `src/files/XiaolaiSC-Regular.ttf`) — Copyright 2020-2024 LXGW
  (<https://github.com/lxgw/kose-font>); Copyright 2014 Nozomi Seto
  (<https://ja.osdn.net/projects/setofont/>), whose Seto font lineage the
  family derives from. The shipped LICENSE is OFL 1.1; the package metadata declares OFL-1.1.
- **Departure Mono** (`packages/font-departure-mono`) — Copyright 2022–2024
  Helena Zhang (<https://helenazhang.com>). The shipped `LICENSE` is OFL 1.1;
  the package metadata declares `OFL-1.1`.
- **Geist / Geist Mono** (`docs/content/public/fonts/Geist[wght].ttf`,
  `GeistMono[wght].ttf`) — Copyright 2024 The Geist Project Authors
  (<https://github.com/vercel/geist-font.git>), OFL 1.1.

## 7. Live2D (gated, not shipped)

No Live2D or Cubism notice, license text or binary is part of this notice set.
`pixi-live2d-display` appears in §5 only because the package is present in the
web lockfile; the Live2D model kind is unavailable at runtime
(`ModelRuntimeBlocker.cubismLicense` in
`apps/flutter/lib/features/stage/model_runtime.dart`) and the Cubism Core is
never committed. The gate, the consent flow and the release-approval requirement
are recorded in [`docs/design-live2d-legal-gate.md`](docs/design-live2d-legal-gate.md).
Add the Live2D/Cubism notices only after the maintainer records the legal review
as resolved.

## 8. Verification and follow-ups

Verified when this set landed:

- `LICENSES/GPL-3.0-or-later.txt`, `MIT.txt`, `OFL-1.1.txt`,
  `Spine-Runtimes-License-Agreement-2025-04-05.txt` and
  `Spine-Runtimes-License-Agreement-2019-05-01.txt` are byte-identical to their
  sources (`packaging/LICENSE.txt`, root `LICENSE`,
  `packages/font-cjkfonts-allseto/license.txt` from line 7,
  `third-party/spine-runtimes/4.2/LICENSE`, `third-party/spine-runtimes/4.0.64/LICENSE`).
- `LICENSES/Spine-Runtimes-License-Agreement-2019-05-01.txt` is also identical
  to `third-party/spine-runtimes/4.1.00/LICENSE` and to the npm
  `@esotericsoftware/spine-core@4.0.31` text.
- `packages/flutter_anima_render/LICENSE` is byte-identical to
  `packaging/LICENSE.txt`.
- No file under `third-party/spine-runtimes/**` was modified; the vendored
  license texts are read-only inputs to this set.
- `LICENSES/MPL-2.0.txt` is byte-identical to the `dbus` `0.8.1` LICENSE in the
  pub cache; the Apache-2.0 notice for `a2ui_core` `0.1.1` and the MIT text for
  `xml` `7.1.0` match that package's LICENSE tail and the `xml` LICENSE.
- The repository-root notice set is copied byte-for-byte into
  `apps/flutter/assets/notices/` (including `LICENSES/MPL-2.0.txt`) and declared
  as Flutter assets, so mobile AAB/IPA builds ship every text named here.
- New files added by the original notice set: `LICENSES/**`,
  `THIRD_PARTY_NOTICES.md`, `packages/flutter_anima_render/LICENSE`; updated
  2026-11-25 (`airi-jb4q`) with the MPL text and lockfile-correct classifications.
