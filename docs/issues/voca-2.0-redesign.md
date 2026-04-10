# Voca 2.0: First-Principles Redesign

## Context

Voca is a macOS voice input tool. The current implementation is a monolithic Swift app (~2700 LOC) that uses Apple's built-in Speech Recognition for transcription and a single OpenAI-compatible LLM call for post-processing refinement. While functional, it has fundamental architectural limitations:

**Core Problems Identified:**

1. **Apple Speech Recognition is the accuracy bottleneck** -- limited vocabulary, no custom terms, poor with mixed languages, no cloud ASR options (Whisper, etc.)
2. **Monolithic AppDelegate (515 lines)** acts as god object -- orchestrates audio, UI, LLM, keyboard, state all in one class
3. **Clipboard-based text injection** -- fragile race condition (saves clipboard, pastes, restores after 500ms), destroys user clipboard temporarily
4. **API keys stored in plaintext UserDefaults** -- security risk
5. **No streaming LLM** -- UI blocks during refinement, 10s hard timeout
6. **No history** -- transcriptions are fire-and-forget
7. **No per-app context awareness** -- same prompt regardless of whether user is in Slack, VS Code, or email
8. **No self-correction detection** -- if user says "no wait, I meant X", both versions are kept
9. **No filler word removal** -- "um", "uh" pass through
10. **Thread safety issues** -- `currentTask`, `models`, `prompts` accessed from multiple threads without synchronization
11. **No personal dictionary** -- can't learn user-specific terms/names
12. **Single language per session** -- no mixed-language or auto-detection

**Goal:** Split Voca into a thin macOS client + a Go server (dmr-plugin-voca) that leverages the DMR agent framework for intelligent voice processing. Inspired by Typeless's "voice keyboard" concept: not raw transcription, but AI-processed, context-aware, polished text output.

---

## Architecture Overview

```
┌──────────────────────────────────┐     HTTP/WebSocket     ┌─────────────────────────────────┐
│        Voca.app (Swift)          │ ◄──────────────────────►│     dmr-plugin-voca (Go)        │
│                                  │                         │                                 │
│  ┌────────────┐ ┌─────────────┐  │    POST /v1/transcribe  │  ┌───────────┐ ┌────────────┐  │
│  │ KeyMonitor │ │ AudioEngine │──│───── audio stream ──────│─►│ ASR Engine│ │ DMR Agent  │  │
│  └─────┬──────┘ └─────────────┘  │                         │  └─────┬─────┘ │  Loop      │  │
│        │        ┌─────────────┐  │    SSE /v1/stream       │        │       └─────┬──────┘  │
│        │        │ OverlayPanel│◄─│──── partial results ────│────────┘             │         │
│        │        └─────────────┘  │                         │  ┌───────────┐       │         │
│        │        ┌─────────────┐  │    final result         │  │ Prompt    │       │         │
│        └───────►│TextInjector │◄─│─────────────────────────│──│ Resolver  │◄──────┘         │
│                 └─────────────┘  │                         │  └───────────┘                  │
│                                  │                         │  ┌───────────┐ ┌────────────┐  │
│  ┌────────────────────────────┐  │    GET /v1/health       │  │ History   │ │ Personal   │  │
│  │ Settings (SwiftUI)        │  │    GET /v1/history       │  │ (Tape)    │ │ Dictionary │  │
│  └────────────────────────────┘  │                         │  └───────────┘ └────────────┘  │
└──────────────────────────────────┘                         └─────────────────────────────────┘
                                                                       │
                                                                ┌──────┴──────┐
                                                                │  DMR Host   │
                                                                │ (Agent/Tape)│
                                                                └─────────────┘
```

---

## Phase 1: dmr-plugin-voca (Go Server)

### 1.1 Project Structure

```
dmr-plugin-voca/
  main.go                    # Entry point: goplugin.Serve()
  plugin.go                  # DMRPluginInterface implementation
  config.go                  # Config struct with defaults
  server.go                  # HTTP server (start in Init(), standard net/http)
  handler_transcribe.go      # POST /v1/transcribe -- accept audio, return text
  handler_stream.go          # WebSocket /v1/stream -- real-time streaming mode
  handler_history.go         # GET /v1/history -- past transcriptions
  handler_health.go          # GET /v1/health
  asr.go                     # ASR provider interface
  asr_whisper.go             # OpenAI Whisper API provider
  asr_aliyun.go              # Aliyun Paraformer ASR provider (optional)
  refiner.go                 # LLM refinement via DMR agent RunAgent
  prompt_resolver.go         # Per-app context-aware prompt selection
  dictionary.go              # Personal dictionary (terms, names, abbreviations)
  tools.go                   # DMR tools: vocaTranscribe, vocaHistory, vocaDictAdd
  policies/voca.rego         # OPA policy
  go.mod
  Makefile
  README.md
```

### 1.2 Config (`config.go`)

```go
type VocaPluginConfig struct {
    Listen          string `json:"listen"`           // default ":9800"
    AuthToken       string `json:"auth_token"`       // bearer token for client auth
    ConfigBaseDir   string `json:"config_base_dir"`  // injected by DMR

    // ASR
    ASRProvider     string `json:"asr_provider"`     // "whisper" | "aliyun" | "apple" (passthrough)
    WhisperAPIURL   string `json:"whisper_api_url"`  // default "https://api.openai.com/v1"
    WhisperAPIKey   string `json:"whisper_api_key"`
    WhisperModel    string `json:"whisper_model"`    // default "whisper-1"
    AliyunAccessKey string `json:"aliyun_access_key"`
    AliyunSecret    string `json:"aliyun_secret"`

    // Refinement
    DefaultPrompt   string `json:"default_prompt"`   // default system prompt for refinement
    AppPrompts      string `json:"app_prompts_file"` // per-app prompt mapping JSON
    DictionaryFile  string `json:"dictionary_file"`  // personal dictionary path

    // Behavior
    AutoRefine      bool   `json:"auto_refine"`      // default true
    RemoveFillers   bool   `json:"remove_fillers"`   // default true
    DetectCorrection bool  `json:"detect_correction"` // "no wait" detection, default true
    MaxAudioSeconds int    `json:"max_audio_seconds"` // default 120
}
```

### 1.3 ASR Provider Interface (`asr.go`)

```go
type ASRProvider interface {
    // Transcribe processes a complete audio file/buffer
    Transcribe(ctx context.Context, audio []byte, format string, lang string) (*ASRResult, error)
    // Name returns the provider name for logging
    Name() string
}

type ASRResult struct {
    Text       string
    Language   string  // detected language
    Duration   float64 // audio duration in seconds
    Confidence float64
    Segments   []Segment // word-level timestamps if available
}
```

The `whisper` provider sends audio to the OpenAI Whisper API. The `apple` mode is a passthrough -- the client does Apple Speech Recognition locally and sends the text (for backward compatibility). Future: add `aliyun` Paraformer for Chinese-optimized ASR.

### 1.4 Core API Endpoints (`server.go`)

| Method | Path | Description |
|--------|------|-------------|
| `POST` | `/v1/transcribe` | Accept audio (multipart), return transcribed+refined text |
| `GET` | `/v1/stream` | WebSocket for real-time streaming (future) |
| `GET` | `/v1/history` | List past transcriptions from tape |
| `GET` | `/v1/health` | Health check |
| `POST` | `/v1/dictionary` | Add/remove personal dictionary terms |
| `GET` | `/v1/prompts` | List available prompts |

**`POST /v1/transcribe` flow (handler_transcribe.go):**

1. Receive `multipart/form-data`: audio file + metadata (format, language, app_context, prompt_id)
2. Route to configured ASR provider
3. If `auto_refine` enabled:
   - Resolve prompt (per-app context or explicit prompt_id)
   - Inject personal dictionary into system prompt
   - Call `host.RunAgent` with the transcription as user message
   - Return refined result
4. Store to tape for history
5. Return JSON: `{ "text": "...", "raw": "...", "language": "...", "refined": true }`

### 1.5 Context-Aware Prompt Resolution (`prompt_resolver.go`)

Inspired by Typeless's per-app tone adaptation. A JSON mapping file:

```json
{
  "by_app": {
    "com.apple.mail": { "prompt": "email_professional" },
    "com.tinyspeck.slackmacgap": { "prompt": "chat_casual" },
    "com.microsoft.VSCode": { "prompt": "programming_speech_correction" },
    "com.github.cursor": { "prompt": "programming_speech_correction" }
  },
  "default": { "prompt": "builtin" }
}
```

The client sends the active app's bundle identifier; the server resolves the appropriate prompt.

### 1.6 DMR Tools (`tools.go`)

Tools exposed to the DMR agent ecosystem:

| Tool | Group | Description |
|------|-------|-------------|
| `vocaTranscribe` | extended | Transcribe audio from URL/path |
| `vocaHistory` | extended | Query transcription history |
| `vocaDictAdd` | extended | Add term to personal dictionary |
| `vocaDictList` | extended | List personal dictionary |

This allows other DMR agents to leverage voice capabilities (e.g., a Feishu bot could transcribe a voice message via `vocaTranscribe`).

### 1.7 Personal Dictionary (`dictionary.go`)

A JSON file that stores user-specific terms:

```json
{
  "terms": [
    { "spoken": "德莫", "written": "DMR", "context": "project name" },
    { "spoken": "沃卡", "written": "Voca", "context": "product name" },
    { "spoken": "肖恩", "written": "Sean", "context": "person name" }
  ]
}
```

Injected into the refinement prompt as additional context so the LLM knows how to correct these specific terms.

---

## Phase 2: Voca.app Client Refactoring (Swift)

### 2.1 Architecture: MVVM + Protocol-Based DI

Replace the monolithic AppDelegate with clean separation:

```
Sources/Voca/
  main.swift
  App/
    AppDelegate.swift          # Slim (~100 lines): wire dependencies, setup menu
    AppState.swift             # Observable state: isRecording, isRefining, etc.
  Audio/
    AudioCaptureService.swift  # Protocol + AVAudioEngine impl, exports WAV/Opus
  Input/
    KeyMonitor.swift           # Cleaned up, same Fn/custom hotkey logic
    TextInjector.swift         # Improved: Accessibility API as primary, clipboard fallback
  Network/
    VocaClient.swift           # HTTP client to dmr-plugin-voca server
    VocaClientProtocol.swift   # Protocol for testability
  UI/
    OverlayPanel.swift         # Enhanced: draggable, multi-line, progress indicator
    StatusBarController.swift  # Menu bar extracted from AppDelegate
    SettingsView.swift         # SwiftUI settings (replaces 3 AppKit windows)
  Config/
    Settings.swift             # Codable settings, Keychain for secrets
    KeychainHelper.swift       # API keys in Keychain, not UserDefaults
  Util/
    BundleIdentifier.swift     # Detect frontmost app for context-aware prompts
```

### 2.2 Key Client Changes

**a) Audio Export (AudioCaptureService.swift)**

Current: Audio buffers go directly to Apple Speech Recognition.
New: Capture audio to a buffer, export as WAV/Opus when recording stops, send to server.

```swift
protocol AudioCaptureService {
    func startCapture()
    func stopCapture() -> AudioData  // returns raw audio bytes + format
    var onAudioLevel: ((Float) -> Void)? { get set }
}
```

**b) Dual-Mode Operation**

Support both local-only (backward compatible) and server-connected modes:
- **Local mode**: Apple Speech Recognition + direct LLM call (current behavior)
- **Server mode**: Send audio to dmr-plugin-voca, receive refined text

Config determines which mode. Server mode is the default when a server URL is configured.

**c) Text Injection Improvement (TextInjector.swift)**

Primary: Use macOS Accessibility API (`AXUIElement`) to directly set text on the focused element -- no clipboard involvement.
Fallback: Current clipboard-based approach for apps that don't support Accessibility text setting.

```swift
protocol TextInjectionService {
    func inject(_ text: String)
}

class AccessibilityTextInjector: TextInjectionService {
    func inject(_ text: String) {
        // Try AXUIElement.setValue first
        // Fall back to clipboard-based paste if Accessibility fails
    }
}
```

**d) App Context Detection (BundleIdentifier.swift)**

Detect the frontmost application before recording starts, send its bundle ID to the server for context-aware prompt selection:

```swift
func frontmostAppBundleId() -> String? {
    NSWorkspace.shared.frontmostApplication?.bundleIdentifier
}
```

**e) Settings Migration to SwiftUI + Keychain**

Replace the three AppKit NSPanel-based settings windows with a single SwiftUI `Settings` scene:
- Server connection tab (URL, auth token)
- ASR tab (provider selection, language)
- Prompts tab (list, edit, per-app mapping)
- Shortcuts tab (trigger key config)
- All secrets stored in Keychain via `KeychainHelper`

**f) VocaClient (Network Layer)**

```swift
protocol VocaClientProtocol {
    func transcribe(audio: Data, format: String, language: String, appContext: String?, promptId: String?) async throws -> TranscriptionResult
    func health() async throws -> Bool
    func history(limit: Int) async throws -> [HistoryEntry]
}
```

### 2.3 Server 降级容错策略

Voca.app 必须是 **完全自足的独立工具**，dmr-plugin-voca 是增强而非依赖。

**连接状态机:**

```
                    ┌──────────────────────┐
    未配置 server ──►│    LOCAL_ONLY        │ (纯本地，永不尝试连接)
                    └──────────────────────┘

                    ┌──────────────────────┐
   配了 server URL──►│    CONNECTING         │──health check──┐
                    └──────────────────────┘                  │
                         ▲                                    ▼
                    30s 重试                          ┌──────────────┐
                         │                           │   ONLINE      │ (server 模式)
                    ┌────┴─────────────┐             └───────┬──────┘
                    │   OFFLINE        │◄─health check fail──┘
                    │   (本地降级模式)   │
                    └──────────────────┘
```

| 场景 | 行为 |
|------|------|
| 未配置 server URL | 纯本地模式：Apple Speech + 直连 LLM，与 v1 完全一致 |
| 配了 server 但连不上 | 启动时 health check 失败 → 自动降级到本地模式 |
| 录音中途 server 超时 | 本次超时的请求 → fallback 到本地 Apple Speech 处理 |
| server 恢复 | 后台每 30s health check，恢复后自动切回 server 模式 |
| server 不稳定 | 连续 3 次失败 → 进入 OFFLINE，拉长重试间隔到 60s |

**菜单栏状态指示（StatusBarController）:**

```
 🟢 mic      ← server 在线
 ⚪ mic      ← 本地模式（未配置 server）
 🟡 mic      ← server 配置了但离线，已降级到本地
 🔴 mic.fill ← 正在录音
```

### 2.4 UI 改动详细设计

保持 menu bar + 浮窗的核心形态，重点改进浮窗交互和设置界面。

**a) 重新设计的 Overlay Panel**

从单行信息条升级为轻量交互面板：

```
录音中:
┌─────────────────────────────────────┐
│ 🎙 Recording...              [ESC] │
│ ┃┃┃┃┃ (waveform)                   │
│                                     │
│ 我想用配森写代码                      │
└─────────────────────────────────────┘

润色完成 (raw → refined 过渡动画):
┌─────────────────────────────────────┐
│ ✨ Refined                          │
│                                     │
│  Raw:  我想用配森写代码               │
│  ────────────────────────────       │
│  ✨ 我想用Python写代码               │
│                                     │
│  [Inject ↵] [Copy] [Edit] [Retry]  │
└─────────────────────────────────────┘
```

改进点:
- **双行对比**: raw 和 refined 同时展示，用户一眼看出 LLM 改了什么
- **操作按钮**: Inject（注入到光标位置，默认回车触发）、Copy、Edit（在面板内直接编辑）、Retry（重新录音）
- **可拖拽**: 记住用户上次拖拽的位置（UserDefaults 存坐标）
- **自动注入**: 如果 2 秒内无操作，自动注入 refined 文本（保持快捷体验）
- **面板内编辑**: 点击 Edit 后文本变为可编辑，回车确认注入

**b) 新增: 历史记录面板 (HistoryPanel)**

通过菜单栏 "History" 或 Cmd+Shift+H 打开：

```
┌───────────────────────────────────────┐
│ Voca History                    [×]  │
│ ┌─────────────────────────────────┐  │
│ │ 🔍 Search...                    │  │
│ └─────────────────────────────────┘  │
│                                       │
│ Today                                 │
│  10:32  我想用Python写代码        📋  │
│         Raw: 我想用配森写代码          │
│  10:28  帮我看一下这个PR           📋  │
│  09:15  这个bug的原因是...         📋  │
│                                       │
│ Yesterday                             │
│  16:42  Meeting notes for sprint...📋  │
│  ...                                  │
└───────────────────────────────────────┘
```

- 按天分组，显示时间戳 + refined 文本
- 展开显示 raw 原文
- 📋 按钮一键复制
- 搜索框支持全文搜索
- 本地存储（SQLite 或 JSON 文件），server 模式下同步到 tape

**c) SwiftUI 设置窗口 (SettingsView)**

合并现有 3 个 AppKit 窗口为一个标签页式 SwiftUI 设置：

```
┌───────────────────────────────────────────────┐
│ Voca Settings                                 │
│ ┌──────┬──────┬──────┬──────┬──────┐          │
│ │Server│ ASR  │Prompt│ Dict │ Keys │          │
│ └──────┴──────┴──────┴──────┴──────┘          │
│                                               │
│ [Server Tab]                                  │
│  Server URL: [http://localhost:9800    ]       │
│  Auth Token: [••••••••••        ] [Show]      │
│  Status:  🟢 Connected (Whisper mode)         │
│  [Test Connection]                            │
│                                               │
│ [Dict Tab]                                    │
│  Personal Dictionary:                         │
│  ┌──────────┬──────────┬───────────┐          │
│  │ Spoken   │ Written  │ Context   │          │
│  ├──────────┼──────────┼───────────┤          │
│  │ 德莫     │ DMR      │ project   │          │
│  │ 沃卡     │ Voca     │ product   │          │
│  │ 肖恩     │ Sean     │ person    │          │
│  └──────────┴──────────┴───────────┘          │
│  [+] [-]                                      │
└───────────────────────────────────────────────┘
```

5 个标签页:
- **Server**: 服务端连接配置 + 状态
- **ASR**: 语音识别选项（语言、provider 选择）
- **Prompt**: Prompt 管理 + 每应用 prompt 映射
- **Dict**: 个人词典管理（增删改查）
- **Keys**: 触发快捷键设置（保留当前功能）

**d) 菜单栏菜单精简**

```
┌──────────────────────┐
│ ✓ Enabled            │
│ ──────────────────── │
│   Language        ►  │
│   Prompt          ►  │
│   LLM Refinement  ►  │
│ ──────────────────── │
│ 🟢 Server: Online    │  ← 新增：连接状态一目了然
│ ──────────────────── │
│   History...    ⇧⌘H  │  ← 新增：打开历史面板
│   Settings...    ⌘,  │
│   Quit           ⌘Q  │
└──────────────────────┘
```

---

## Phase 3: Smart Refinement Features

These are implemented server-side in dmr-plugin-voca's refinement pipeline:

### 3.1 Filler Word Removal
Pre-process transcription before LLM: remove Chinese fillers ("嗯", "啊", "那个") and English fillers ("um", "uh", "you know", "like"). Use a simple rule-based filter before sending to LLM to save tokens.

### 3.2 Self-Correction Detection
Detect patterns like "不对/no wait/I mean" and only keep the corrected version. Can be a lightweight regex pass or part of the LLM prompt.

### 3.3 Auto-Formatting
LLM prompt instructs: "If the user dictates a list, format as bullet points. If they dictate steps, format as numbered list."

### 3.4 Personal Dictionary Injection
Append dictionary terms to the system prompt:
```
The user has the following custom terms. When you encounter similar-sounding words, prefer these:
- "德莫" should be written as "DMR"
- "沃卡" should be written as "Voca"
```

---

## Implementation Order

| Step | Scope | Description |
|------|-------|-------------|
| **1** | Go | Create `dmr-plugin-voca` scaffold: main.go, plugin.go, config.go, server.go, health endpoint |
| **2** | Go | Implement `POST /v1/transcribe` with Whisper ASR provider |
| **3** | Go | Implement refinement via DMR `RunAgent` with prompt resolution |
| **4** | Go | Add personal dictionary, filler removal, history (tape) |
| **5** | Swift | Refactor Voca.app: extract AudioCaptureService, add VocaClient + ConnectionManager (降级状态机) |
| **6** | Swift | Add server mode with auto-fallback: send audio to plugin, 超时/失败自动降级到本地 |
| **7** | Swift | 重做 OverlayPanel: 双行对比、操作按钮、可拖拽、面板内编辑 |
| **8** | Swift | 新增 HistoryPanel: 历史记录面板 + 本地 SQLite 存储 |
| **9** | Swift | SwiftUI SettingsView: 合并 5 标签页（Server/ASR/Prompt/Dict/Keys） |
| **10** | Swift | Improve TextInjector with Accessibility API primary path |
| **11** | Swift | StatusBarController: 连接状态指示 + 菜单精简 |
| **12** | Swift | App context detection (frontmost app bundle ID) |
| **13** | Both | Per-app prompt mapping, streaming mode (WebSocket) |

---

## Critical Files

### New files to create:
- `../dmr-plugin-voca/main.go` -- plugin entry point
- `../dmr-plugin-voca/plugin.go` -- DMRPluginInterface implementation
- `../dmr-plugin-voca/config.go` -- configuration
- `../dmr-plugin-voca/server.go` -- HTTP server
- `../dmr-plugin-voca/handler_transcribe.go` -- transcription endpoint
- `../dmr-plugin-voca/handler_health.go` -- health check
- `../dmr-plugin-voca/asr.go` + `asr_whisper.go` -- ASR provider interface + Whisper impl
- `../dmr-plugin-voca/refiner.go` -- DMR agent-based refinement
- `../dmr-plugin-voca/prompt_resolver.go` -- per-app prompt selection
- `../dmr-plugin-voca/dictionary.go` -- personal dictionary
- `../dmr-plugin-voca/tools.go` -- DMR tool definitions
- `../dmr-plugin-voca/go.mod` + `Makefile`

### Existing files to modify (Voca.app):
- `Sources/Voca/AppDelegate.swift` -- slim down to ~100 lines, extract responsibilities
- `Sources/Voca/SpeechEngine.swift` -- refactor to AudioCaptureService, keep local mode
- `Sources/Voca/TextInjector.swift` -- add Accessibility API path
- `Sources/Voca/LLMRefiner.swift` -- replace with VocaClient for server mode
- `Sources/Voca/OverlayPanel.swift` -- 重做：双行对比、操作按钮、可拖拽、面板内编辑
- `Sources/Voca/SettingsWindow.swift` + `PromptWindow.swift` + `ShortcutSettingsWindow.swift` -- 合并为 SwiftUI SettingsView

### New Voca.app files:
- `Sources/Voca/Network/VocaClient.swift` -- HTTP client to server
- `Sources/Voca/Network/ConnectionManager.swift` -- 降级状态机 (LOCAL_ONLY/CONNECTING/ONLINE/OFFLINE)
- `Sources/Voca/UI/HistoryPanel.swift` -- 历史记录面板
- `Sources/Voca/UI/StatusBarController.swift` -- 菜单栏状态管理（从 AppDelegate 提取）
- `Sources/Voca/UI/SettingsView.swift` -- SwiftUI 设置窗口
- `Sources/Voca/Config/Settings.swift` -- Codable 配置 + Keychain
- `Sources/Voca/Config/KeychainHelper.swift` -- Keychain 封装
- `Sources/Voca/Util/BundleIdentifier.swift` -- 前台 app 检测
- `Sources/Voca/Storage/HistoryStore.swift` -- 本地历史 SQLite 存储

### Reference files (patterns to follow):
- `../dmr-plugin-gitlab/main.go` -- entry point pattern
- `../dmr-plugin-gitlab/plugin.go` -- DMRPluginInterface implementation pattern
- `../dmr-plugin-gitlab/webhook.go` -- HTTP server-in-Init() pattern
- `../dmr-plugin-gitlab/config.go` -- config struct pattern
- `../dmr/pkg/plugin/proto/types.go` -- RPC interface contract

---

## Verification

1. **dmr-plugin-voca builds**: `cd ../dmr-plugin-voca && go build ./...`
2. **Health check works**: Start plugin via DMR config, `curl http://localhost:9800/v1/health`
3. **Transcription works**: `curl -X POST -F "audio=@test.wav" -F "language=zh-CN" http://localhost:9800/v1/transcribe`
4. **Voca.app builds**: `cd voca && make build`
5. **End-to-end**: Configure Voca.app to point to local dmr-plugin-voca, press hotkey, speak, verify refined text is injected
6. **Backward compatibility**: Voca.app in local mode (no server) still works with Apple Speech + direct LLM
