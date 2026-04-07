# VoiceInput 代码架构分析

## 项目概述

VoiceInput 是一个 macOS 菜单栏应用程序，通过 Fn 键触发语音输入，将语音实时转换为文本并自动粘贴到当前输入框。

**技术栈**: Swift + AppKit + Speech 框架 + AVFoundation

---

## 系统架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                        VoiceInput App                               │
├─────────────────────────────────────────────────────────────────────┤
│                                                                     │
│  ┌─────────────────┐      ┌─────────────────┐      ┌─────────────┐ │
│  │   KeyMonitor    │◄────►│   AppDelegate   │◄────►│SpeechEngine │ │
│  │   (键盘监听)     │      │   (核心协调器)   │      │  (语音识别)  │ │
│  └─────────────────┘      └────────┬────────┘      └──────┬──────┘ │
│                                    │                      │        │
│                                    ▼                      ▼        │
│                           ┌─────────────────┐      ┌─────────────┐ │
│                           │  OverlayPanel   │      │LLMRefiner   │ │
│                           │  (悬浮面板UI)    │      │ (文本优化)   │ │
│                           └─────────────────┘      └──────┬──────┘ │
│                                    ▲                      │        │
│                                    │                      ▼        │
│                           ┌─────────────────┐      ┌─────────────┐ │
│                           │ SettingsWindow  │      │TextInjector │ │
│                           │  (设置窗口)      │      │ (文本注入)   │ │
│                           └─────────────────┘      └─────────────┘ │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
                                    │
                                    ▼
                           ┌─────────────────┐
                           │  macOS System   │
                           │ - Speech API    │
                           │ - Audio Engine  │
                           │ - Event Tap     │
                           └─────────────────┘
```

---

## 模块职责

### 1. main.swift
**职责**: 应用程序入口点
- 创建 NSApplication 实例
- 设置应用为菜单栏模式（`.accessory`）
- 初始化 AppDelegate 并启动主循环

### 2. AppDelegate.swift
**职责**: 核心协调器，负责模块间通信和状态管理

**关键状态**:
```swift
private var isEnabled: Bool       // 功能开关
private var isRecording: Bool     // 录音状态
private var lastPartialResult: String  // 最后识别结果
```

**核心流程**:
1. **Fn 键按下**: 启动录音 → 显示 OverlayPanel → 播放提示音
2. **Fn 键释放**: 停止录音 → 等待最终结果
3. **识别完成**: 调用 LLMRefiner 优化 → 调用 TextInjector 注入文本

### 3. KeyMonitor.swift
**职责**: 全局键盘事件监听（CGEventTap）

**技术细节**:
- 使用 `CGEvent.tapCreate` 创建全局事件监听
- 监听 `flagsChanged` 事件检测 Fn 键状态
- 返回 `nil` 阻止事件传播（防止触发系统表情选择器）
- 需要辅助功能权限（Accessibility）

### 4. SpeechEngine.swift
**职责**: 语音识别核心

**功能**:
- 请求麦克风和语音识别权限
- 使用 `SFSpeechRecognizer` 进行实时识别
- 通过 `AVAudioEngine` 捕获音频
- 计算音频电平用于波形动画
- 支持多语言（通过设置 locale）

**回调接口**:
```swift
var onPartialResult: ((String) -> Void)?   // 中间结果
var onFinalResult: ((String) -> Void)?     // 最终结果
var onError: ((String) -> Void)?           // 错误处理
var onAudioLevel: ((Float) -> Void)?       // 音频电平
```

### 5. OverlayPanel.swift
**职责**: 语音输入时的悬浮 UI 面板

**UI 组成**:
- 圆角胶囊形面板（HUD 风格）
- 波形动画视图（WaveformView）
- 文本标签显示识别内容
- 弹性动画效果（入场/更新/退场）

**波形动画**:
- 5 个条形图，根据音频电平动态变化
- 平滑的 attack/release 过渡
- 添加随机抖动增加自然感

### 6. TextInjector.swift
**职责**: 将文本注入到当前输入框

**实现策略**:
1. 保存当前剪贴板内容
2. 将目标文本写入剪贴板
3. 检测当前输入法是否为 ASCII 模式
4. 如需要，临时切换到 ASCII 输入法（防止中文输入法拦截粘贴）
5. 模拟 Cmd+V 粘贴
6. 恢复原始输入法和剪贴板内容

### 7. LLMRefiner.swift
**职责**: 使用 LLM API 优化识别结果

**设计模式**: 单例模式（`shared`）

**优化场景**:
- 中英文混杂修正（如 "配森" → "Python"）
- 同音字错误修正
- 英文单词分割/合并错误

**配置项**:
- API Base URL（默认 OpenAI）
- API Key
- Model（默认 gpt-4o-mini）
- 启用/禁用开关

**Prompt 设计**: 保守策略，只修复明显错误，不改变原文语义

### 8. SettingsWindow.swift
**职责**: LLM 设置窗口 UI

**功能**:
- 配置 API Base URL、API Key、Model
- 测试连接功能
- 保存到 UserDefaults

---

## 数据流

```
┌──────────────┐    Fn Down     ┌──────────────┐
│   用户按下    │───────────────►│  KeyMonitor  │
│    Fn 键     │                └──────┬───────┘
└──────────────┘                       │
                                       ▼
┌──────────────┐              ┌─────────────────┐
│  显示识别结果  │◄─────────────│   AppDelegate   │
│  + 波形动画   │   updateText   │   (协调中心)     │
└──────────────┘              └───────┬─────────┘
                                      │
                    ┌─────────────────┼─────────────────┐
                    ▼                 ▼                 ▼
            ┌──────────────┐  ┌──────────────┐  ┌──────────────┐
            │ SpeechEngine │  │ OverlayPanel │  │   播放提示音  │
            │  开始录音     │  │  显示面板     │  │   Tink.wav   │
            └──────┬───────┘  └──────────────┘  └──────────────┘
                   │
                   │ 音频数据流
                   ▼
            ┌──────────────┐
            │ SFSpeechRecognizer │
            └──────┬───────┘
                   │
                   │ onPartialResult / onFinalResult
                   ▼
            ┌─────────────────────────────────────┐
            │         识别结果处理流程              │
            │  ┌───────────────────────────────┐  │
            │  │  LLMRefiner 启用且配置正确？    │  │
            │  └───────────────┬───────────────┘  │
            │                  │                  │
            │         ┌────────┴────────┐         │
            │         ▼                 ▼         │
            │      是 → 调用 LLM API   否 → 直接注入│
            │         │                 │         │
            │         ▼                 │         │
            │    显示 "Refining..."      │         │
            │         │                 │         │
            │         ▼                 │         │
            │    获取优化结果 ───────────┘         │
            │         │                          │
            └─────────┼──────────────────────────┘
                      ▼
            ┌─────────────────┐
            │  TextInjector   │
            │  注入文本到输入框 │
            └─────────────────┘
```

---

## 关键设计决策

### 1. 为什么使用剪贴板 + 模拟粘贴？
- 优点：通用性强，适用于任何可输入的文本框
- 缺点：会临时覆盖用户剪贴板（已做恢复处理）

### 2. 为什么使用 CGEventTap 而不是 NSEvent？
- 可以全局监听 Fn 键（即使在其他应用中）
- 可以阻止事件传播（防止触发系统表情选择器）
- 需要辅助功能权限

### 3. 为什么 LLMRefiner 使用单例模式？
- 配置需要在多处访问（菜单项状态、设置窗口、识别流程）
- 避免重复创建网络任务
- 便于管理并发请求（取消正在进行的请求）

### 4. 音频电平如何计算？
```swift
// RMS (均方根) → dB → 归一化
let rms = sqrtf(sum / Float(frameLength))
let dB = 20 * log10(max(rms, 1e-6))
let normalized = max(Float(0), min(Float(1), (dB + 50) / 40))
```

---

## 依赖关系

```
AppDelegate
    ├── KeyMonitor
    ├── SpeechEngine
    ├── TextInjector
    ├── OverlayPanel
    ├── SettingsWindow
    └── LLMRefiner.shared

SettingsWindow
    └── LLMRefiner.shared

TextInjector
    └── Carbon 框架 (TISInputSource)

SpeechEngine
    ├── Speech 框架
    └── AVFoundation 框架

KeyMonitor
    └── CoreGraphics 框架
```

---

## 权限要求

| 权限 | 用途 | 文件 |
|------|------|------|
| Accessibility | 监听全局 Fn 键 | KeyMonitor.swift |
| Speech Recognition | 语音识别 | SpeechEngine.swift |
| Microphone | 音频输入 | SpeechEngine.swift |

---

## 潜在问题与改进建议

### 1. 并发安全
- `LLMRefiner` 的 `currentTask` 访问没有加锁
- 建议：使用 `DispatchQueue` 或 `actor` 保护

### 2. 内存管理
- `KeyMonitor` 的 `Unmanaged.passUnretained` 使用正确，但需要确保生命周期

### 3. 错误处理
- 网络请求失败时重试机制缺失
- API 限流处理不完善

### 4. 可测试性
- 各模块耦合度较高，缺少接口抽象
- 建议：提取协议（Protocol）便于单元测试

### 5. 国际化
- 硬编码的提示文本（如 "Listening..."）
- 建议：使用 Localizable.strings

---

## 文件统计

| 文件 | 行数 | 职责 |
|------|------|------|
| main.swift | 8 | 入口点 |
| AppDelegate.swift | 323 | 核心协调器 |
| SpeechEngine.swift | 137 | 语音识别 |
| KeyMonitor.swift | 76 | 键盘监听 |
| OverlayPanel.swift | 242 | 悬浮面板 |
| TextInjector.swift | 83 | 文本注入 |
| LLMRefiner.swift | 141 | LLM优化 |
| SettingsWindow.swift | 136 | 设置窗口 |
| **总计** | **~1046** | |
