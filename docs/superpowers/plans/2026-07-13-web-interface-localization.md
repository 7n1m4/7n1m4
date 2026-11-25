# Web 사용자 인터페이스 한국어화 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 한국어 환경에서 주요 Web 사용자 경로가 더 이상 영어로 폴백되거나 하드코딩되지 않도록 하고, 정적 번역 키 완전성 검사를 구축한다.

**Architecture:** 기존 Vue I18n 과 `packages/i18n` YAML 언어 팩을 계속 사용한다. 먼저 소스 계약 테스트로 프로덕션 코드의 정적 `t()` 키를 수집하고 한국어 커버리지를 검증한 뒤, 사용자 가시성에 따라 하드코딩된 문구를 마이그레이션한다; 브랜드, 모델, 프로토콜, 정확한 설정 키는 명시적 화이트리스트로 원문을 유지한다.

**Tech Stack:** Vue 3、TypeScript、Vue I18n、YAML、Vitest、Vite、pnpm 10.32.1、Node.js 24.13.0

---

## 文件结构

- `packages/stage-layouts/src/localization/web-localization.test.ts`：跨 Web 生产源码检查静态 i18n 键、插值变量和已确认的硬编码英文。
- `packages/stage-layouts/package.json`：为上述测试声明 `yaml` 开发依赖。
- `packages/i18n/src/locales/en/settings.yaml`、`packages/i18n/src/locales/en/stage.yaml`：新增从组件迁出的英文源文案。
- `packages/i18n/src/locales/ko/settings.yaml`、`packages/i18n/src/locales/ko/stage.yaml`：한국어 키를 보완하고 사용자 가시 문구를 번역한다.
- `packages/stage-pages/src/pages/settings/**`：迁移设置页、角色卡和向导中的硬编码文案。
- `packages/stage-ui/src/components/scenarios/settings/**`：迁移模型设置中的硬编码文案。
- `packages/stage-ui/src/components/scenarios/chat/**`、`packages/stage-ui/src/components/scenarios/dialogs/onboarding/**`：迁移聊天弹窗和首次引导文案。
- `packages/stage-layouts/src/components/**`：迁移桌面和移动聊天布局中的英文提示。
- `apps/stage-web/src/pages/auth/login.vue`、`apps/stage-web/src/pages/settings/characters/**`：处理仍可访问的登录和角色管理界面。
- `docs/superpowers/README.md`：维护计划链接、状态和最终实现依据。

## 统一命令前缀

以下命令均在 `D:\Tools\airi` 执行，并使用项目专用 Corepack：

```powershell
$corepack = 'D:\Tools\airi\.node24.local\node-v24.13.0-win-x64\corepack.cmd'
```

### Task 1: Web 한국어 키 완전성 보호 구축 및 기존 누락 키 보완

**Files:**
- Create: `packages/stage-layouts/src/localization/web-localization.test.ts`
- Modify: `packages/stage-layouts/package.json`
- Modify: `packages/i18n/src/locales/ko/settings.yaml`
- Modify: `packages/i18n/src/locales/ko/stage.yaml`

- [ ] **Step 1: 声明 YAML 测试依赖**

在 `packages/stage-layouts/package.json` 的 `devDependencies` 中加入：

```json
{ "yaml": "catalog:" }
```

- [ ] **Step 2: 写入静态键覆盖失败测试**

创建 `packages/stage-layouts/src/localization/web-localization.test.ts`：

```ts
import { readdirSync, readFileSync } from 'node:fs'
import { resolve } from 'node:path'

import { describe, expect, it } from 'vitest'
import { parse } from 'yaml'

const workspaceRoot = resolve(import.meta.dirname, '../../../..')
const sourceRoots = [
  'apps/stage-web/src',
  'apps/ui-server-auth/src',
  'packages/stage-pages/src',
  'packages/stage-layouts/src',
  'packages/stage-ui/src',
]

const excludedPath = /[\\/]devtools[\\/]|[\\/]dist[\\/]|[\\/]stories[\\/]|\.test\.ts$|\.story\.vue$/

function listSourceFiles(directory: string): string[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(directory, entry.name)
    if (excludedPath.test(path))
      return []
    if (entry.isDirectory())
      return listSourceFiles(path)
    return /\.(?:ts|tsx|vue)$/.test(entry.name) ? [path] : []
  })
}

function flatten(value: unknown, prefix = '', output: Record<string, unknown> = {}) {
  if (value && typeof value === 'object' && !Array.isArray(value)) {
    for (const [key, child] of Object.entries(value))
      flatten(child, prefix ? `${prefix}.${key}` : key, output)
  }
  else {
    output[prefix] = value
  }
  return output
}

function loadWebMessages(locale: 'en' | 'ko') {
  const localeRoot = resolve(workspaceRoot, 'packages/i18n/src/locales', locale)
  return flatten({
    base: parse(readFileSync(resolve(localeRoot, 'base.yaml'), 'utf8')),
    settings: parse(readFileSync(resolve(localeRoot, 'settings.yaml'), 'utf8')),
    stage: parse(readFileSync(resolve(localeRoot, 'stage.yaml'), 'utf8')),
  })
}

function collectStaticTranslationKeys() {
  const keys = new Set<string>()
  for (const root of sourceRoots) {
    for (const file of listSourceFiles(resolve(workspaceRoot, root))) {
      const source = readFileSync(file, 'utf8')
      for (const match of source.matchAll(/\b(?:t|\$t)\(\s*['"]([^'"]+)['"]/g))
        keys.add(match[1])
    }
  }
  return [...keys].sort()
}

function interpolationVariables(value: unknown) {
  if (typeof value !== 'string')
    return []
  return [...value.matchAll(/\{([^{}]+)\}/g)].map(match => match[1]).sort()
}

describe('Korean web localization', () => {
  const english = loadWebMessages('en')
  const korean = loadWebMessages('ko')
  const referencedKeys = collectStaticTranslationKeys().filter(key => key in english)

  it('defines every statically referenced English key in Korean', () => {
    expect(referencedKeys.filter(key => !(key in korean))).toEqual([])
  })

  it('preserves interpolation variables from English messages', () => {
    const mismatches = referencedKeys
      .filter(key => key in korean)
      .filter(key => interpolationVariables(english[key]).join('|') !== interpolationVariables(korean[key]).join('|'))
    expect(mismatches).toEqual([])
  })
})
```

- [ ] **Step 3: 运行测试并确认当前缺口**

Run:

```powershell
& $corepack pnpm --filter @proj-anima/stage-layouts exec vitest run src/localization/web-localization.test.ts
```

Expected: FAIL; first test lists 84 missing Korean keys, mainly in `settings.pages.modules`, `settings.dialogs.onboarding`, `settings.pages.data`, `settings.chat`, and `settings.pages.chat`.

- [ ] **Step 4: 补齐所有静态引用缺键**

按英文文件的相同层级向한국어 YAML 加入键。以下核心翻译必须使用这些文字，其余同组键保持相同术语：

```yaml
chat:
  send-mode:
    title: 전송 키
    description: 채팅 입력창에서 메시지를 전송하는 키 방식을 선택합니다.
    options:
      enter: Enter로 전송
      ctrl-enter: Ctrl+Enter로 전송
      double-enter: Enter 두 번으로 전송
  stream-idle-timeout:
    title: 스트리밍 응답 유휴 타임아웃
    description: 모델 스트리밍 응답에 새 이벤트가 오랫동안 없으면 이번 응답을 자동으로 취소합니다.
    options:
      10s: 10초
      15s: 15초
      30s: 30초
      45s: 45초
      60s: 60초
      120s: 2분
```

同时补齐并翻译这些完整键组：

- `dialogs.onboarding.modeSelection`：시작 방법, 간편 설정, 고급 설정 및 두 모드 설명.
- `dialogs.onboarding.senseSetup`：지각 진입점, 의식, 음성과 청각, OpenRouter/Deepgram 획득 진입점 및 설명.
- `pages.chat`：채팅 설정 제목, 설명 및 세 가지 전송 모드.
- `pages.connection.hf-token`：Hugging Face 토큰 라벨, 용도 설명 및 `hf_...` 예시.
- `pages.data.sections.characters|memory|backgrounds`：캐릭터, 기억과 일기, 배경 및 가져오기/내보내기 작업.
- `pages.modules.hearing.sections.section.hotkey`：마이크 전환 단축키 및 Scroll/Caps/Num Lock 옵션.
- `pages.modules.messaging-discord`：연결 상태, 제어, 시뮬레이션 메시지 및 개발 콘솔; Discord, VLM 이름 유지.
- `pages.providers.provider.amazon-bedrock.config`：AWS 자격 증명 설명; AWS, IAM, STS 이름 유지.
- `vrm.scale-and-position`：마우스 따라가기, 따라가기 속도 및 설명.
- `stage.chat.reasoning_only`：모델이 추론 내용만 생성할 때 사용자에게 보여주는 안내.

- [ ] **Step 5: 重新运行测试并提交**

Run:

```powershell
& $corepack pnpm --filter @proj-anima/stage-layouts exec vitest run src/localization/web-localization.test.ts
git diff --check
git add packages/stage-layouts/package.json packages/stage-layouts/src/localization/web-localization.test.ts packages/i18n/src/locales/ko/settings.yaml packages/i18n/src/locales/ko/stage.yaml
git commit -m "test(i18n): require Korean web message coverage"
```

Expected: 2 tests PASS；提交只包含测试、依赖和 보완한 한국어 키。

### Task 2: 한국어 언어 팩에 남은 영어 가시 문구 정리

**Files:**
- Modify: `packages/stage-layouts/src/localization/web-localization.test.ts`
- Modify: `packages/i18n/src/locales/ko/settings.yaml`
- Modify: `packages/i18n/src/locales/ko/stage.yaml`

- [ ] **Step 1: 增加“普通英文不得原样回退”失败测试**

在测试文件加入：

```ts
const allowedIdenticalEnglishKeys = new Set([
  'settings.pages.flux.title',
  'settings.pages.modules.messaging-discord.title',
  'settings.pages.modules.x.title',
  'settings.pages.admin.officialGateway.providers.openrouter',
  'stage.chat.message.character-name.airi',
])

function canRemainEnglish(key: string) {
  return allowedIdenticalEnglishKeys.has(key)
    || /^settings\.pages\.providers\.provider\.[^.]+\.title$/.test(key)
    || /\.(?:apiKey|baseURL|flux)$/.test(key)
}
```

并在 `describe` 中加入：

```ts
it('does not leave referenced user-facing sentences identical to English', () => {
  const untranslated = referencedKeys.filter(key => (
    typeof english[key] === 'string'
    && english[key] === korean[key]
    && /[A-Z]{3}/i.test(english[key] as string)
    && !canRemainEnglish(key)
  ))
  expect(untranslated).toEqual([])
})
```

- [ ] **Step 2: 运行测试确认失败**

Run:

```powershell
& $corepack pnpm --filter @proj-anima/stage-layouts exec vitest run src/localization/web-localization.test.ts
```

Expected: FAIL；列出 Provider 分类说明、连接说明、模型设置、账户危险操作等仍为英文的可见键。

- [ ] **Step 3: 翻译普通文案并保留专有词**

翻译测试列出的全部普通句子。采用以下术语：

```text
Speech -> 음성 합성
Transcription -> 음성 전사
Vision -> 비전
Gaming -> 게임
Messaging -> 메시징
Maximum FPS -> 최대 FPS
Render Scale -> 렌더 비율
Unlimited -> 무제한
Confirm new password -> 새 비밀번호 확인
Danger Zone -> 위험 구역
```

Provider 名称、模型名、OpenAI、OpenRouter、AWS、WebSocket、API、URL、Flux、Live2D、VRM 保持原文，但其前后说明翻译成한국어。开发工具命名和 `Markdown Stress` 不纳入此测试。

- [ ] **Step 4: 验证并提交**

Run:

```powershell
& $corepack pnpm --filter @proj-anima/stage-layouts exec vitest run src/localization/web-localization.test.ts
git diff --check
git add packages/stage-layouts/src/localization/web-localization.test.ts packages/i18n/src/locales/ko/settings.yaml packages/i18n/src/locales/ko/stage.yaml
git commit -m "fix(i18n): translate referenced Korean web messages"
```

Expected: 3 tests PASS。

### Task 3: 迁移系统、数据和模块设置页的硬编码英文

**Files:**
- Modify: `packages/stage-layouts/src/localization/web-localization.test.ts`
- Modify: `packages/i18n/src/locales/en/settings.yaml`
- Modify: `packages/i18n/src/locales/ko/settings.yaml`
- Modify: `packages/stage-pages/src/pages/settings/modules/speech.vue`
- Modify: `packages/stage-pages/src/pages/settings/modules/vision.vue`
- Modify: `packages/stage-pages/src/pages/settings/modules/hearing.vue`
- Modify: `packages/stage-pages/src/pages/settings/modules/beat-sync.vue`
- Modify: `packages/stage-pages/src/pages/settings/modules/memory-short-term.vue`
- Modify: `packages/stage-pages/src/pages/settings/modules/memory-long-term.vue`
- Modify: `packages/stage-pages/src/pages/settings/modules/memory-signals.vue`
- Modify: `packages/stage-pages/src/pages/settings/data/index.vue`
- Modify: `packages/stage-pages/src/pages/v2/settings/providers.vue`

- [ ] **Step 1: 为当前可见英文加入源码契约失败测试**

在测试文件加入：

```ts
const forbiddenEnglishByFile: Record<string, string[]> = {
  'packages/stage-pages/src/pages/settings/modules/speech.vue': [
    'Add Provider',
    'No Speech Providers Configured',
    'Customize how your AI assistant speaks',
  ],
  'packages/stage-pages/src/pages/settings/modules/vision.vue': [
    'Not Configured',
    'No Vision Providers Configured',
    'Search models...',
    'Direct Response',
    'Forward to LLM',
  ],
  'packages/stage-pages/src/pages/settings/modules/hearing.vue': [
    'No Providers Configured',
    'Click here to set up your Transcription providers',
    'Voice Activity',
    'Last 2 seconds',
  ],
  'packages/stage-pages/src/pages/settings/modules/memory-short-term.vue': [
    'Active Character',
    'Window Size',
    'Rebuild From History',
    'Context Strategy',
    'Dream State Synthesis',
  ],
  'packages/stage-pages/src/pages/settings/modules/memory-long-term.vue': [
    'Character Filter',
    'Search Archive',
    'Archive Purpose',
    'Operational Rules',
    'Identity Anchors',
  ],
  'packages/stage-pages/src/pages/settings/modules/memory-signals.vue': [
    'The Dream State',
    'Enable Dream State',
    'Journaling Threshold',
    'Strict AFK Gating',
  ],
  'packages/stage-pages/src/pages/settings/data/index.vue': [
    'Backup Provider:',
    'Last Backup:',
    'Nuke Selected',
    'Restore Selected',
    'Confirm Restore',
  ],
  'packages/stage-pages/src/pages/v2/settings/providers.vue': [
    'Search configured...',
    'Customize options',
    'Search supported providers...',
    'No providers',
  ],
}

it('does not reintroduce audited English literals in production settings', () => {
  const violations = Object.entries(forbiddenEnglishByFile).flatMap(([file, phrases]) => {
    const source = readFileSync(resolve(workspaceRoot, file), 'utf8')
    return phrases.filter(phrase => source.includes(phrase)).map(phrase => `${file}: ${phrase}`)
  })
  expect(violations).toEqual([])
})
```

- [ ] **Step 2: 运行测试确认源码契约失败**

Run:

```powershell
& $corepack pnpm --filter @proj-anima/stage-layouts exec vitest run src/localization/web-localization.test.ts
```

Expected: FAIL；报告上述文件和英文短语。

- [ ] **Step 3: 将文案迁移到 i18n**

每个没有 `useI18n()` 的组件加入：

```ts
import { useI18n } from 'vue-i18n'

const { t } = useI18n()
```

模板统一改为动态属性或插值，例如：

```vue
<FieldInput
  :label="t('settings.pages.modules.memory-short-term.fields.window-size.label')"
  :description="t('settings.pages.modules.memory-short-term.fields.window-size.description')"
/>

<span>
{{ t('settings.pages.modules.speech.actions.add-provider') }}
</span>
```

英文和한국어 YAML 使用同一键结构。技术示例 `tts-1`、`whisper-1`、`gpt-4o-mini`、`hf_...` 和模型 ID 保持原样；按钮、状态、说明和可访问性标签全部翻译。

- [ ] **Step 4: 验证模块设置并提交**

Run:

```powershell
& $corepack pnpm --filter @proj-anima/stage-layouts exec vitest run src/localization/web-localization.test.ts
& $corepack pnpm --filter @proj-anima/stage-pages typecheck
git diff --check
git add packages/i18n/src/locales/en/settings.yaml packages/i18n/src/locales/ko/settings.yaml packages/stage-layouts/src/localization/web-localization.test.ts packages/stage-pages/src/pages/settings packages/stage-pages/src/pages/v2/settings/providers.vue
git commit -m "fix(settings): localize core web settings"
```

Expected: 本地化测试 PASS，`stage-pages` 类型检查退出码为 0。

### Task 4: 迁移角色卡向导和模型设置中的高频英文

**Files:**
- Modify: `packages/stage-layouts/src/localization/web-localization.test.ts`
- Modify: `packages/i18n/src/locales/en/settings.yaml`
- Modify: `packages/i18n/src/locales/ko/settings.yaml`
- Modify: `packages/stage-pages/src/pages/settings/airi-card/guided.vue`
- Modify: `packages/stage-pages/src/pages/settings/airi-card/components/CardCreationDialog.vue`
- Modify: `packages/stage-pages/src/pages/settings/airi-card/components/CardImportWizard.vue`
- Modify: `packages/stage-pages/src/pages/settings/airi-card/components/ConceptBuilderModal.vue`
- Modify: `packages/stage-pages/src/pages/settings/airi-card/components/VoiceCreatorModal.vue`
- Modify: `packages/stage-pages/src/pages/settings/airi-card/components/tabs/CardCreationTabIdentity.vue`
- Modify: `packages/stage-pages/src/pages/settings/airi-card/components/tabs/CardCreationTabGeneration.vue`
- Modify: `packages/stage-pages/src/pages/settings/airi-card/components/tabs/CardCreationTabProactivity.vue`
- Modify: `packages/stage-pages/src/pages/settings/airi-card/components/tabs/CardCreationTabTools.vue`
- Modify: `packages/stage-ui/src/components/scenarios/settings/model-settings/audio-studio.vue`
- Modify: `packages/stage-ui/src/components/scenarios/settings/model-settings/live2d.vue`
- Modify: `packages/stage-ui/src/components/scenarios/settings/model-settings/mmd.vue`
- Modify: `packages/stage-ui/src/components/scenarios/settings/model-settings/spine.vue`
- Modify: `packages/stage-ui/src/components/scenarios/settings/model-settings/components/ModelSceneSettings.vue`

- [ ] **Step 1: 扩展源码契约测试**

向 `forbiddenEnglishByFile` 增加这些条目：

```ts
const forbiddenEnglishByFile: Record<string, string[]> = {
  'packages/stage-ui/src/components/scenarios/settings/model-settings/audio-studio.vue': [
    'New Profile',
    'Profile Name',
    'Base Provider',
    'Pitch Tuning',
    'Custom Replacement Rules',
    'Stop Playback',
  ],
  'packages/stage-ui/src/components/scenarios/settings/model-settings/live2d.vue': [
    'Character Customizations',
    'Auto Blink',
    'Force Auto Blink (fallback)',
    'Reset value to default',
    'Mouse Tracking',
  ],
  'packages/stage-ui/src/components/scenarios/settings/model-settings/mmd.vue': [
    'Character Customizations',
    'Enable Physics',
    'Enable IK Solvers',
    'Gravity Strength',
  ],
  'packages/stage-pages/src/pages/settings/airi-card/guided.vue': [
    'Confirm & Create',
    'Roster Settings',
    'Model Preview',
    'Auto-Assign Voices',
  ],
}
```

Run the focused test and expect FAIL with these phrases.

- [ ] **Step 2: 迁移用户可见标签、按钮、说明和 tooltip**

角色卡文案放在 `settings.pages.card` 现有层级下；模型设置放在 `settings.model-settings.common`、`settings.live2d`、`settings.vrm`、`settings.spine` 下。保留角色字段名、模型参数名、文件扩展名、正则示例和 AI 生成提示词原文；仅迁移渲染给用户的文案。

动态三元文案改为翻译键，例如：

```vue
:title="isHidden(morph)
  ? t('settings.model-settings.common.actions.show')
  : t('settings.model-settings.common.actions.hide')"
```

值格式化改为：

```ts
function formatPan(value: number) {
  if (value === 0)
    return t('settings.model-settings.audio-studio.pan.center')
  return value < 0
    ? t('settings.model-settings.audio-studio.pan.left', { value: Math.abs(value) })
    : t('settings.model-settings.audio-studio.pan.right', { value })
}
```

- [ ] **Step 3: 验证并提交角色与模型设置**

Run:

```powershell
& $corepack pnpm --filter @proj-anima/stage-layouts exec vitest run src/localization/web-localization.test.ts
& $corepack pnpm --filter @proj-anima/stage-pages typecheck
& $corepack pnpm --filter @proj-anima/stage-ui typecheck
git diff --check
git add packages/i18n/src/locales/en/settings.yaml packages/i18n/src/locales/ko/settings.yaml packages/stage-layouts/src/localization/web-localization.test.ts packages/stage-pages/src/pages/settings/airi-card packages/stage-ui/src/components/scenarios/settings/model-settings
git commit -m "fix(settings): localize card and model editors"
```

Expected: 本地化测试以及两个类型检查均退出码为 0。

### Task 5: 迁移聊天、导航和首次引导中的明显英文

**Files:**
- Modify: `packages/stage-layouts/src/localization/web-localization.test.ts`
- Modify: `packages/i18n/src/locales/en/settings.yaml`
- Modify: `packages/i18n/src/locales/en/stage.yaml`
- Create: `packages/i18n/src/locales/en/server/index.ts`
- Create: `packages/i18n/src/locales/en/server/auth.yaml`
- Modify: `packages/i18n/src/locales/en/index.ts`
- Modify: `packages/i18n/src/locales/ko/settings.yaml`
- Modify: `packages/i18n/src/locales/ko/stage.yaml`
- Create: `packages/i18n/src/locales/ko/server/index.ts`
- Create: `packages/i18n/src/locales/ko/server/auth.yaml`
- Modify: `packages/i18n/src/locales/ko/index.ts`
- Modify: `packages/stage-layouts/src/components/Widgets/ChatArea.vue`
- Modify: `packages/stage-layouts/src/components/Layouts/MobileInteractiveArea.vue`
- Modify: `packages/stage-layouts/src/components/Layouts/HeaderAvatar.vue`
- Modify: `packages/stage-layouts/src/components/Layouts/InteractiveArea/Actions/ViewControls.vue`
- Modify: `packages/stage-layouts/src/components/Layouts/InteractiveArea/Actions/About.vue`
- Modify: `packages/stage-ui/src/components/scenarios/chat/ProducerGuidanceModal.vue`
- Modify: `packages/stage-ui/src/components/scenarios/chat/ProducerChoiceBubble.vue`
- Modify: `packages/stage-ui/src/components/scenarios/chat/JournalMomentModal.vue`
- Modify: `packages/stage-ui/src/components/scenarios/chat/JournalPreviewModal.vue`
- Modify: `packages/stage-ui/src/components/scenarios/dialogs/onboarding/step-provider-configuration.vue`
- Modify: `packages/stage-ui/src/components/scenarios/dialogs/onboarding/step-provider-selection.vue`
- Modify: `packages/stage-ui/src/components/scenarios/dialogs/onboarding/step-provider-resolver.vue`
- Modify: `packages/stage-ui/src/components/scenarios/dialogs/onboarding/step-selective-sync.vue`
- Modify: `packages/stage-ui/src/components/scenarios/dialogs/onboarding/step-sync-progress.vue`
- Modify: `apps/stage-web/src/pages/auth/login.vue`
- Modify: `apps/stage-web/src/pages/settings/characters/index.vue`
- Modify: `apps/stage-web/src/pages/settings/characters/components/CharacterDialog.vue`

- [ ] **Step 1: 恢复认证界面的源语言包**

当前认证语言 YAML 只残留在生成目录，源码索引没有导出 `server.auth`。将
`packages/i18n/dist/locales/locales/en/server/auth.yaml` 和
`packages/i18n/dist/locales/locales/ko/server/auth.yaml` 的现有内容原样恢复到对应 `src/locales` 路径，再修正其中仍为英文的한국어普通文案。两个 `server/index.ts` 均使用：

```ts
import auth from './auth.yaml'

export default {
  auth,
}
```

在英文和한국어 `index.ts` 中加入：

```ts
import server from './server'

export default {
  base,
  docs,
  server,
  settings,
  stage,
  tamagotchi,
}
```

同步扩展 `loadWebMessages()`，让测试读取认证语言包：

```ts
return {
  ...messages,
  server: {
    auth: parse(readFileSync(resolve(localeRoot, 'server/auth.yaml'), 'utf8')),
  },
}
```

运行本地化测试；若恢复的한국어认证文件缺键或插值变量不一致，测试必须失败并在本步骤内补齐。

- [ ] **Step 2: 为共享界面添加失败契约**

向 `forbiddenEnglishByFile` 加入：

```ts
const forbiddenEnglishByFile: Record<string, string[]> = {
  'packages/stage-layouts/src/components/Widgets/ChatArea.vue': [
    'Describe a scene to imagine...',
    'Memory & Context for',
  ],
  'packages/stage-layouts/src/components/Layouts/MobileInteractiveArea.vue': [
    'Hearing',
    'Memory',
    'Cleanup Messages',
  ],
  'packages/stage-ui/src/components/scenarios/dialogs/onboarding/step-provider-selection.vue': [
    'Deployment',
    'Pricing',
    'No providers match your current filters.',
  ],
  'packages/stage-ui/src/components/scenarios/chat/ProducerChoiceBubble.vue': [
    'PRODUCER DIRECTIVES',
    'Regenerate choices',
    'Retry',
    'Dismiss suggestions',
  ],
  'apps/stage-web/src/pages/auth/login.vue': [
    'By continuing, you agree to our',
    'Terms',
    'Privacy Policy',
  ],
  'apps/stage-web/src/pages/settings/characters/index.vue': ['Search...'],
}
```

Run the focused test and expect FAIL.

- [ ] **Step 3: 迁移共享文案**

聊天和布局文案使用 `stage.chat` 或 `settings.chat-ui`；首次引导使用 `settings.dialogs.onboarding`；旧登录页使用 `settings.auth`；角色管理使用 `settings.pages.characters`。Google、GitHub、Provider 名称、模型 ID 和模板占位符名称保持原文。

含角色名或数值的文案必须使用插值：

```vue
:title="t('stage.chat.memory-and-context-for', { name: characterName })"
```

```yaml
memory-and-context-for: '{name} 的记忆与上下文'
```

- [ ] **Step 4: 验证并提交共享界面**

Run:

```powershell
& $corepack pnpm --filter @proj-anima/stage-layouts exec vitest run src/localization/web-localization.test.ts
& $corepack pnpm --filter @proj-anima/i18n typecheck
& $corepack pnpm --filter @proj-anima/stage-layouts typecheck
& $corepack pnpm --filter @proj-anima/stage-ui typecheck
& $corepack pnpm --filter @proj-anima/stage-web typecheck
git diff --check
git add packages/i18n/src/locales packages/stage-layouts/src packages/stage-ui/src/components/scenarios/chat packages/stage-ui/src/components/scenarios/dialogs/onboarding apps/stage-web/src/pages/auth/login.vue apps/stage-web/src/pages/settings/characters
git commit -m "fix(web): localize shared user interface"
```

Expected: 本地化测试及四个类型检查均通过。

### Task 6: 全量复查、生产构建和项目状态收尾

**Files:**
- Modify: `docs/superpowers/README.md`
- Modify only if audit finds user-visible omissions: files already listed in Tasks 1-5

- [ ] **Step 1: 重新执行英文候选扫描**

Run:

```powershell
rg -n -g '*.vue' -g '*.ts' -g '!**/*.test.ts' -g '!**/*.story.vue' -g '!**/devtools/**' '(title|subtitle|label|description|placeholder|aria-label):?="[A-Za-z]|>[[:space:]]*[A-Za-z][^<{]*<' packages/stage-pages/src/pages/settings packages/stage-layouts/src packages/stage-ui/src/components apps/stage-web/src apps/ui-server-auth/src
```

逐项分类：用户可见普通文案继续迁移；品牌、模型、协议、精确配置字段、开发内部、日志、提示词和不可达页面记录为保留项，不为消除扫描结果而修改业务逻辑。

- [ ] **Step 2: 解析 YAML 并验证编码**

Run:

```powershell
& 'D:\Tools\airi\.node24.local\node-v24.13.0-win-x64\node.exe' -e "const fs=require('fs'),YAML=require('yaml');for(const f of ['packages/i18n/src/locales/en/settings.yaml','packages/i18n/src/locales/en/stage.yaml','packages/i18n/src/locales/ko/settings.yaml','packages/i18n/src/locales/ko/stage.yaml'])YAML.parse(fs.readFileSync(f,'utf8'));console.log('YAML OK')"
$files = git diff --name-only fork/main -- '*.yaml' '*.vue' '*.ts' '*.md'
foreach ($file in $files) {
  $bytes = [IO.File]::ReadAllBytes((Resolve-Path $file))
  if ($bytes.Length -ge 3 -and $bytes[0] -eq 239 -and $bytes[1] -eq 187 -and $bytes[2] -eq 191) { throw "BOM detected: $file" }
  if ([Text.Encoding]::UTF8.GetString($bytes).Contains("`r`n")) { throw "CRLF detected: $file" }
}
```

Expected: 输出 `YAML OK`，没有 BOM 或 CRLF 异常。

- [ ] **Step 3: 运行完整定向验证**

Run:

```powershell
& $corepack pnpm --filter @proj-anima/stage-layouts exec vitest run src/localization/web-localization.test.ts
& $corepack pnpm --filter @proj-anima/i18n typecheck
& $corepack pnpm --filter @proj-anima/stage-pages typecheck
& $corepack pnpm --filter @proj-anima/stage-layouts typecheck
& $corepack pnpm --filter @proj-anima/stage-ui typecheck
& $corepack pnpm --filter @proj-anima/stage-web typecheck
& $corepack pnpm --filter @proj-anima/stage-web build
```

Expected: 所有命令退出码为 0，Stage Web 生产构建成功。

- [ ] **Step 4: 浏览器抽查한국어界面**

在后台启动本地 Stage Web，在한국어下检查：

```powershell
$web = Start-Process -FilePath $corepack -ArgumentList @('pnpm', '--filter', '@proj-anima/stage-web', 'dev', '--host', '127.0.0.1') -WindowStyle Hidden -PassThru
# 浏览器抽查完成后：
Stop-Process -Id $web.Id
```

检查 `/settings/`、系统/聊天/数据设置、听觉/语音/视觉/记忆模块、角色卡向导、模型设置、聊天弹窗、首次引导、旧登录页和角色管理。验收结果应为：普通按钮、标题、说明、空状态和 tooltip 显示한국어；仅品牌、模型、协议和技术字段保留英文。

- [ ] **Step 5: 更新索引并提交收尾**

将 `docs/superpowers/README.md` 中本工作项状态改为 `done`，实施计划链接设为 `[Plan](plans/2026-07-13-web-interface-localization.md)`；运行 `git rev-parse HEAD` 获取最近实现提交 SHA，并写入实现依据。

Run:

```powershell
git diff --check
git status --short
git add docs/superpowers/README.md
git commit -m "docs: close web interface localization plan"
git status --short
```

Expected: 文档提交成功，最终工作区干净。随后将 `main` 推送到 `fork/main`；除非用户另行要求，不执行生产部署。
