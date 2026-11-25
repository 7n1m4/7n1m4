# Dating Sim & Interactive Scenarios

How the visual-novel gameplay, mood/intimacy mechanics, branching choices, and scene overlays are wired in code.

## Entering Dating Sim Mode

To start a Dating Sim scenario:
1. Open the **Desktop Chatbox** or **Control Strip**.
2. Click the **"Scenario / Dating Sim"** heart icon.
3. Choose a storyline preset from the **Story Selector** (e.g., *After-School Study Session*, *Festival Fireworks*, *Late Night Convenience Store Run*, or *Coffee Shop First Encounter*).
4. Click **Start Scenario**.

## Code Homes

- Dating sim store (phases, mood states, choices, scoring): [`packages/stage-ui/src/stores/dating-sim.ts`](dating-sim.ts).
- Storyline presets: [`packages/stage-ui/src/constants/dating-sim/storylines.ts`](../constants/dating-sim/storylines.ts).
- Overlay and selector UI: [`packages/stage-ui/src/components/scenes/DatingSimOverlay.vue`](../components/scenes/DatingSimOverlay.vue) and [`packages/stage-ui/src/components/scenes/StorySelectorModal.vue`](../components/scenes/StorySelectorModal.vue).

## Core Game Mechanics

When a Dating Sim scenario is active, the UI switches to a visual novel presentation:

### Intimacy & Tension Points
- **Affection (Heart Meter)**: Increases when you make choices that align with your companion's personality, remember past memories, or show empathy.
- **Tension / Awkwardness**: High-stakes dialogue choices may increase tension, making your companion flustered, shy, or defensive.

### The 4 Mood States
Your companion's responses, expression animations, and voice tone dynamically adapt to 4 distinct mood tiers:

| Mood Tier | Emotional State | Character Behavior |
| :--- | :--- | :--- |
| **Low / Distant** | Guarded, polite | Short responses, neutral resting expressions. |
| **Normal** | Comfortable, friendly | Casual conversational banter, smiles, inquisitive questions. |
| **High** | Excited, warm | Blushing, animated gestures, deeper emotional disclosures. |
| **Max / Spark** | Deeply attached | High intimacy dialogue, exclusive expressions, special event triggers. |

## Branching Choices & Dialogue Wheels

During dramatic story beats, the AI generates **Interactive Choice Cards**:
- **Topic Selection Wheels**: Choose between talking about *Hobbies*, *School/Work*, *Secrets*, or *Playful Teasing*.
- **Action Choices**: Choose physical actions (e.g., *Offer your jacket*, *Take her hand*, *Look away shyly*).
- **Freeform Input**: You can always bypass the choices and type your own custom dialogue at any time.

## Scene Backgrounds & Music

Scenarios automatically switch the Stage background image and lighting to match the active narrative location (e.g., transitioning from a bright classroom at sunset to a starry park bench at night).
