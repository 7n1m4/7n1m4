# Desktop Controls & Shortcuts

How the floating Control Strip, window modes, caption docking, and shortcuts are wired in code.

## The Floating Control Strip

The **Control Strip** is a compact, floating dock that gives you quick access to all essential companion controls without opening the full settings menu.

### Control Strip Buttons
- **Microphone (STT)**: Toggle open-mic listening or push-to-talk state.
- **Stop**: Instantly halts any ongoing speech or text generation.
- **Chat**: Opens or focuses the 3-column Desktop Chatbox window.
- **Captions / Subtitles**: Toggles the floating subtitle overlay on/off.
- **Customizer**: Opens the floating live customization drawer for quick expression and lighting tweaks.
- **Settings**: Opens the comprehensive application configuration hub.

> [!TIP]
> **Customizing the Dock**: You can reorder buttons, pin favorite tools, or switch between compact and expanded layouts in **Settings &rarr; Appearance &rarr; Control Strip**.

## Code Homes

- Control Strip component: [`packages/stage-ui/src/components/scenarios/layout/ControlStrip.vue`](ControlStrip.vue) and host [`packages/stage-ui/src/components/scenes/ControlStripHost.vue`](../../scenes/ControlStripHost.vue).
- Control Strip action composable: [`packages/stage-ui/src/composables/use-control-strip-action.ts`](../../../composables/use-control-strip-action.ts).
- Stage control editor: [`packages/stage-ui/src/components/scenarios/settings/StageControlEditor.vue`](../settings/StageControlEditor.vue).

## Window Modes & Positioning

Anima's desktop interface consists of several modular windows that can be repositioned and pinned anywhere on your monitors:

### Stage Window (Avatar Display)
- **Dragging**: Click and drag the model stage to place your avatar anywhere on your screen (e.g., bottom-right corner or perched on your taskbar).
- **Always on Top**: By default, the Stage window floats above other applications so your companion remains visible. You can toggle this off in Appearance settings.
- **Mouse Transparency (Click-Through)**: Enable click-through mode so clicks pass through the avatar to the desktop or game underneath. Hold `Ctrl+Shift` to temporarily interact with the stage while click-through is enabled.

### Floating Caption Overlay
- **Subtitles on Demand**: Displays live transcribed user speech and character TTS responses in real time.
- **Docking & Resizing**: Drag the caption plank below your avatar, or detach it to position anywhere on screen.
- **Theme & Opacity**: Adjust subtitle background transparency, font size, and text contrast in **Settings &rarr; Appearance &rarr; Captions**.

## Global Keyboard Shortcuts

| Shortcut | Action | Scope |
| :--- | :--- | :--- |
| `Ctrl + Shift + A` | Focus / Toggle Chatbox | Global |
| `Ctrl + Space` *(Default PTT)* | Hold to Speak (Push-to-Talk) | Global |
| `Ctrl + Shift + S` | Emergency Stop Speech / Generation | Global |
| `Ctrl + Shift + C` | Toggle Floating Captions | Global |
| `Ctrl + Shift + M` | Toggle Mute / Deafened Mode | Global |

*(You can customize all hotkeys in **Settings &rarr; General &rarr; Shortcuts**.)*

## Multi-Monitor Setup

If you use multiple monitors:
- You can drag the Stage window and Control Strip across different displays.
- Anima remembers window positions across restarts and restores each window to its designated screen.
