// SPDX-License-Identifier: GPL-3.0-or-later
//! The frozen method-channel contract, expressed as data.
//!
//! The Dart half of the stage is already frozen (`model_runtime.dart`,
//! `method_channel_backend.dart`): one method channel per kind named
//! `org.moeru.airi/anima/model/<kind>`, with the methods and argument keys
//! below. This module is the native, byte-stable description of that same
//! contract so the Rust backend, the C ABI and any codegen agree on one source
//! of truth. It carries no logic and allocates nothing at call time beyond the
//! returned `String`.

use serde::Serialize;

/// Version of the render/texture contract. Bump when the method set or argument
/// keys change in a way that breaks an already-shipped native backend.
pub const CONTRACT_VERSION: &str = "1";

#[derive(Serialize)]
struct ContractDoc {
    version: &'static str,
    channel_prefix: &'static str,
    methods: &'static [MethodDoc],
}

#[derive(Serialize)]
struct MethodDoc {
    name: &'static str,
    args: &'static [&'static str],
    returns: &'static str,
}

const METHODS: &[MethodDoc] = &[
    MethodDoc {
        name: "load",
        args: &["path", "source"],
        returns: "handle:string, textureId:int",
    },
    MethodDoc {
        name: "setLipSync",
        args: &["handle", "weight"],
        returns: "void",
    },
    MethodDoc {
        name: "setEmotion",
        args: &["handle", "tag", "kind", "intensity", "seq", "tsMs"],
        returns: "void",
    },
    MethodDoc {
        name: "setAmbientPhase",
        args: &["handle", "phase"],
        returns: "void",
    },
    MethodDoc {
        name: "dispose",
        args: &["handle"],
        returns: "void",
    },
];

/// The frozen channel name prefix; the full channel is `<prefix><kind>`.
pub const CHANNEL_PREFIX: &str = "org.moeru.airi/anima/model/";

/// Serialize the frozen render/texture contract to stable JSON.
///
/// The output is deterministic (fixed field order, no maps) so it can be
/// diffed in tests and consumed by codegen without a schema drift check.
pub fn render_contract_json() -> String {
    let doc = ContractDoc {
        version: CONTRACT_VERSION,
        channel_prefix: CHANNEL_PREFIX,
        methods: METHODS,
    };
    serde_json::to_string(&doc).expect("contract doc is always serializable")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn contract_is_byte_stable() {
        let json = render_contract_json();
        assert_eq!(
            json,
            "{\"version\":\"1\",\"channel_prefix\":\"org.moeru.airi/anima/model/\",\"methods\":[{\"name\":\"load\",\"args\":[\"path\",\"source\"],\"returns\":\"handle:string, textureId:int\"},{\"name\":\"setLipSync\",\"args\":[\"handle\",\"weight\"],\"returns\":\"void\"},{\"name\":\"setEmotion\",\"args\":[\"handle\",\"tag\",\"kind\",\"intensity\",\"seq\",\"tsMs\"],\"returns\":\"void\"},{\"name\":\"setAmbientPhase\",\"args\":[\"handle\",\"phase\"],\"returns\":\"void\"},{\"name\":\"dispose\",\"args\":[\"handle\"],\"returns\":\"void\"}]}"
        );
    }
}