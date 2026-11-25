# Captions, Subtitles & Speech Bubbles

How the subtitle and caption surfaces, sentence-sync highlighting, and appearance settings are wired in code.

## Caption Display Surfaces

Anima supports several distinct caption presentation modes:

| Mode | Appearance | Behavior |
| :--- | :--- | :--- |
| **Floating Caption Window** | Transparent floating bar | Can be dragged anywhere on your desktop, docked below your avatar, or pinned to your taskbar. |
| **Inline Chat Captions** | Embedded chat bubbles | Displayed directly inside the 3-column Chatbox stream with emotion badges. |
| **Comic Speech Bubbles** | Head-tethered manga bubbles | (Live2D & VRM) Floats dynamically above the character's head, bobbing with head tilt and movement. |
| **Dating Sim Dialogue HUD** | Bottom visual novel bar | Classic visual novel text box with typewriter effects and actor nameplates. |

## Code Homes

- Caption panel component: [`packages/stage-ui/src/components/scenes/CaptionPanel.vue`](CaptionPanel.vue).
- Floating caption window (Electron main): [`apps/stage-tamagotchi/src/main/windows/caption/index.ts`](../../../../../apps/stage-tamagotchi/src/main/windows/caption/index.ts).
- TTS playback / sentence-sync events: [`packages/stage-ui/src/libs/speech/playback-events.ts`](../../libs/speech/playback-events.ts).

## Sentence-Sync Audio Highlighting

Anima features **Sentence-Sync Audio Playback**:
- As the synthesized TTS audio plays, the active phrase or sentence is highlighted in real time.
- Clicking any highlighted phrase replays that specific audio segment.
- Transcribed microphone input from the user is displayed in an alternating accent color, making multi-turn dialogues easy to follow.

## Customizing Caption Appearance

Open **Settings &rarr; Appearance &rarr; Captions** to adjust:

- **Typography & Font Size**: Scale text from compact (14px) to large broadcast sizes (28px).
- **Background Opacity & Blur**: Choose from solid contrast, frosted glass blur, or completely transparent background.
- **Docking Lock**: Lock the caption bar to follow the avatar Stage window when dragging it across screens.
- **Auto-Hide Timeout**: Automatically fade out subtitles after 5–10 seconds of silence.
