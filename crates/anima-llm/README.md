<!-- SPDX-License-Identifier: GPL-3.0-or-later -->

# anima-llm

Streaming OpenAI-compatible chat provider registry (pure async: tokio / reqwest;
no toolkit, no `anima-store`, no `anima-core`, no `anima-i18n`).

The crate contract — module map, implemented-vs-stub provider matrix, auth/key
handling, registry caveats and the test story — lives in the rustdoc for
[`src/lib.rs`](src/lib.rs) (`cargo doc -p anima-llm --open`).
