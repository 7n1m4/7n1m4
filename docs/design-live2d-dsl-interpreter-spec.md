# Live2D DSL Interpreter & Dating Sim — Architecture

Architecture-level pointer. The capability is a generic, stateful Live2D DSL virtual machine
that runs the interactive "special sauce" scripting embedded in third-party Live2D manifests
(visual-novel branching, RPG affinity gating, dynamic dialogue menus) plus the single-window
"Dating Sim Blend" staging vision (generative background + Live2D character + subtitles +
choices in one canvas).

Source of truth for all technical detail — VarFloats schema, choice overlay UX, command
grammar, intimacy gating, delta ticking, test-model corpus — now lives in
`packages/live2d-runtime/src/dsl/README.md` (code-colocated), with the host bridge and
`change_cos` design record in `packages/stage-ui-live2d/src/runtime/README.md`.

Historical status: VM, parser, heap, selector and host adapter are implemented; the
multi-`.moc3` `change_cos` hot-swap remains deferred (see the runtime README).

## Relevant Skills

- [[airi-live2d-dsl-interpreter]]
