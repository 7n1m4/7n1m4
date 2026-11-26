// SPDX-License-Identifier: GPL-3.0-or-later
#![deny(missing_docs)]

//! AIRI's Slint renderer crate.
//!
//! P0: seeded from `apps/stage-qt/src/vrm/**`.

pub mod bundle;
pub mod contract;
pub mod mmd_native;
pub mod spine;
pub mod spine_native;
pub mod vrm;
pub mod vrm_native;

pub use contract::*;
pub use mmd_native::*;
pub use vrm::*;
