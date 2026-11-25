# Proactivity Engine

How the autonomous heartbeat loop senses the environment and decides when to speak.

## How the Proactivity Engine Works

The Proactivity Engine runs on a periodic **Heartbeat Loop** managed in the background.

```text
[ OS Sensors (Window, AFK, Time) ]
               │
               ▼
[ Salience & Cooldown Filter ] ──(Busy / Suppressed)──► [ Skip Turn ]
               │ (Trigger Conditions Met)
               ▼
[ Proactivity Prompt + Ledger ] ──► [ LLM Heartbeat Decision ]
                                          │
                  ┌───────────────────────┴───────────────────────┐
                  ▼                                               ▼
         [ "NO_REPLY" ]                                 [ Spontaneous Remark ]
       (Silent passivity)                            (Speaks via TTS & Avatar)
```

1. **Sensory Polling**: At regular intervals (default: every 30–60 seconds), Anima gathers lightweight sensory telemetry from your system.
2. **Context Compilation**: It builds an awareness snapshot including:
   - Your currently focused window title and process name (e.g., *VS Code*, *Blender*, *YouTube*).
   - How long you have been typing, moving your mouse, or idle/AFK.
   - Current local time and recent system events.
3. **The Heartbeat Decision**: The LLM evaluates whether this is a natural moment to speak.
   - If you are deeply focused, in a meeting, or if nothing noteworthy has changed, the model emits a special `NO_REPLY` sentinel token and remains silent.
   - If an interesting event or extended silence occurs, Anima generates a spontaneous remark or asks a relevant question.

## Code Home

- Heartbeat engine: [`packages/nan0-runtime/src/heartbeat/Nan0HeartbeatEngine.ts`](Nan0HeartbeatEngine.ts).

## Environmental Telemetry & Privacy

Anima respects your privacy and control:
- **Local Evaluation**: Sensory telemetry is processed locally within the Electron main process.
- **Privacy Filters & App Exclusion**: You can configure an **Excluded Applications List** in Settings to prevent Anima from reading window titles from password managers, banking browsers, or private documents.
- **No Keystroke Logging**: The proactivity system only checks OS-level idle time counters, never recording keystrokes or text you type in other apps.

## Configuring Proactivity

You can tune Anima's proactivity to match your preferences in **Settings &rarr; General &rarr; Proactivity**:

### Proactivity Modes
- **Disabled**: Anima operates strictly as a reactive assistant (speaks only when messaged).
- **Subtle / Low Frequency** (Recommended for work): Heartbeats fire every 5–10 minutes; Anima speaks only after long periods of inactivity or when you return to your PC.
- **Engaged / High Frequency** (Best for casual hanging out): Heartbeats fire every 1–2 minutes, encouraging playful banter and frequent observations.

### Quiet Hours & Focus Mode
- **Quiet Hours**: Define a time range (e.g., 23:00 to 08:00) during which all proactive speech is silenced.
- **AFK Threshold**: Define how many minutes of inactivity qualify as "User is Away" (triggering welcome-back greetings when you move your mouse again).

## Spontaneous Memory & Reflection

During quiet downtime, Anima's proactivity engine can also trigger **Spontaneous Reflection**:
- Looking up an unvisited entry in her Long-Term Text Journal.
- Checking recent Echo Chips to see if an ongoing story thread or unresolved question can be revisited.
- Selecting an existing background image from the local library (read-only) to match the current conversation vibe. (Background generation via Autonomous Artistry is deprecated and disabled.)
