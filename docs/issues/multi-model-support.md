# 多模型切换功能设计方案

## 需求概述
支持配置多个大语言模型（LLM），并可在菜单栏快速切换当前使用的模型。

---

## 方案评估

### 1. 数据模型设计

#### 1.1 新增 `LLMModel` 结构体

```swift
struct LLMModel: Codable, Identifiable {
    let id: UUID
    var name: String           // 显示名称，如 "OpenAI GPT-4"
    var apiBaseURL: String
    var apiKey: String
    var model: String          // 模型标识，如 "gpt-4o"
    var isEnabled: Bool        // 是否启用
    
    // 便捷构造
    static let `default` = LLMModel(
        id: UUID(),
        name: "OpenAI",
        apiBaseURL: "https://api.openai.com/v1",
        apiKey: "",
        model: "gpt-4o-mini",
        isEnabled: true
    )
}
```

#### 1.2 `LLMRefiner` 重构

当前单例存储单个配置，改为存储模型数组：

```swift
final class LLMRefiner {
    static let shared = LLMRefiner()
    
    // 存储所有模型
    var models: [LLMModel] {
        get { /* 从 UserDefaults 读取 */ }
        set { /* 保存到 UserDefaults */ }
    }
    
    // 当前选中的模型 ID
    var selectedModelId: UUID? {
        get { UserDefaults.standard.string(forKey: "selectedLLMModelId").flatMap(UUID.init) }
        set { UserDefaults.standard.set(newValue?.uuidString, forKey: "selectedLLMModelId") }
    }
    
    // 当前选中的模型
    var currentModel: LLMModel? {
        models.first { $0.id == selectedModelId && $0.isEnabled }
        ?? models.first { $0.isEnabled }  // fallback 到第一个启用的
    }
    
    var isConfigured: Bool { currentModel?.apiKey.isEmpty == false }
}
```

#### 1.3 UserDefaults 存储格式

```json
{
  "llmModels": [
    {
      "id": "550e8400-e29b-41d4-a716-446655440000",
      "name": "OpenAI GPT-4",
      "apiBaseURL": "https://api.openai.com/v1",
      "apiKey": "sk-xxx",
      "model": "gpt-4o",
      "isEnabled": true
    },
    {
      "id": "660e8400-e29b-41d4-a716-446655440001", 
      "name": "DeepSeek",
      "apiBaseURL": "https://api.deepseek.com/v1",
      "apiKey": "sk-xxx",
      "model": "deepseek-chat",
      "isEnabled": true
    }
  ],
  "selectedLLMModelId": "550e8400-e29b-41d4-a716-446655440000"
}
```

---

### 2. UI 设计方案

#### 2.1 菜单栏集成（推荐）

在现有 LLM Refinement 子菜单中添加模型切换：

```
┌─────────────────────────┐
│ LLM Refinement    ▶     │
├─────────────────────────┤
│ ☑ Enabled               │
│ ─────────────────────── │
│ ● OpenAI GPT-4    ✓     │  ← 当前选中
│ ○ DeepSeek              │  ← 其他模型
│ ○ Claude 3.5            │
│ ─────────────────────── │
│ Manage Models...        │  ← 打开设置窗口
└─────────────────────────┘
```

**优点**：
- 切换模型无需打开设置窗口
- 与现有菜单结构一致
- 操作路径短

**实现位置**：`AppDelegate.swift` 的 `setupStatusBar()` 方法

#### 2.2 设置窗口重构

将当前的表单界面改为模型列表管理：

```
┌─────────────────────────────────────────────┐
│ Manage LLM Models                      [+]  │
├─────────────────────────────────────────────┤
│ ┌───────────────────────────────────────┐   │
│ │ ● OpenAI GPT-4                 [🖊️ 🗑️] │   │
│ │   https://api.openai.com/v1           │   │
│ └───────────────────────────────────────┘   │
│ ┌───────────────────────────────────────┐   │
│ │ ○ DeepSeek                     [🖊️ 🗑️] │   │
│ │   https://api.deepseek.com/v1         │   │
│ └───────────────────────────────────────┘   │
│ ┌───────────────────────────────────────┐   │
│ │ ○ Claude 3.5 (Disabled)        [🖊️ 🗑️] │   │
│ │   https://api.anthropic.com/v1        │   │
│ └───────────────────────────────────────┘   │
├─────────────────────────────────────────────┤
│ [Test Selected Model]        [Close]        │
└─────────────────────────────────────────────┘
```

**点击 [+] 弹出添加/编辑表单**：

```
┌────────────────────────────┐
│ Add LLM Model              │
├────────────────────────────┤
│ Name:        [________]    │
│ API Base URL:[________]    │
│ API Key:     [________]    │
│ Model:       [________]    │
├────────────────────────────┤
│              [Cancel][Add] │
└────────────────────────────┘
```

---

### 3. 架构调整

#### 3.1 文件变更

| 文件 | 变更类型 | 说明 |
|------|----------|------|
| `LLMModel.swift` | 新增 | 数据模型定义 |
| `LLMRefiner.swift` | 修改 | 支持多模型存储和切换 |
| `SettingsWindow.swift` | 重写 | 模型列表管理界面 |
| `AppDelegate.swift` | 修改 | 菜单栏添加模型切换子菜单 |

#### 3.2 调用流程

```
用户选择模型
    ↓
AppDelegate.changeModel(id:)
    ↓
LLMRefiner.selectedModelId = id (保存到 UserDefaults)
    ↓
更新菜单栏选中状态

---

用户触发语音输入
    ↓
AppDelegate.finishTranscription()
    ↓
LLMRefiner.refine(text) 
    ↓
使用 currentModel 的配置发送请求
```

---

### 4. 数据迁移方案

#### 4.1 兼容旧版本配置

首次启动时检测旧配置，自动迁移：

```swift
private func migrateLegacyConfig() {
    // 检测是否存在旧配置
    guard UserDefaults.standard.object(forKey: "llmAPIKey") != nil,
          UserDefaults.standard.object(forKey: "llmModels") == nil else {
        return
    }
    
    // 读取旧配置
    let legacyModel = LLMModel(
        id: UUID(),
        name: "Default",
        apiBaseURL: UserDefaults.standard.string(forKey: "llmAPIBaseURL") ?? "https://api.openai.com/v1",
        apiKey: UserDefaults.standard.string(forKey: "llmAPIKey") ?? "",
        model: UserDefaults.standard.string(forKey: "llmModel") ?? "gpt-4o-mini",
        isEnabled: UserDefaults.standard.bool(forKey: "llmEnabled")
    )
    
    // 保存为新格式
    models = [legacyModel]
    selectedModelId = legacyModel.id
    
    // 清理旧配置
    UserDefaults.standard.removeObject(forKey: "llmAPIBaseURL")
    UserDefaults.standard.removeObject(forKey: "llmAPIKey")
    UserDefaults.standard.removeObject(forKey: "llmModel")
    UserDefaults.standard.removeObject(forKey: "llmEnabled")
}
```

---

### 5. 实现步骤

#### Phase 1: 数据层（约 2h）
1. 创建 `LLMModel.swift` 定义数据结构
2. 重构 `LLMRefiner.swift` 支持多模型
3. 添加数据迁移逻辑

#### Phase 2: UI 层 - 设置窗口（约 3h）
1. 重写 `SettingsWindow.swift` 为模型列表界面
2. 实现添加/编辑/删除模型功能
3. 实现模型启用/禁用开关

#### Phase 3: UI 层 - 菜单栏（约 2h）
1. 修改 `AppDelegate.swift` 动态生成模型子菜单
2. 实现模型切换逻辑
3. 更新选中状态显示

#### Phase 4: 测试（约 1h）
1. 测试数据迁移
2. 测试模型切换
3. 测试添加/编辑/删除

**预估总耗时：约 8 小时**

---

### 6. 风险与注意事项

| 风险 | 影响 | 缓解措施 |
|------|------|----------|
| 数据迁移失败 | 高 | 保留旧配置读取作为 fallback |
| 菜单栏过长 | 中 | 最多显示 5 个模型，超出时折叠 |
| API Key 安全 | 低 | 后续可考虑迁移到 Keychain |
| 代码复杂度增加 | 中 | 保持向后兼容的单例接口 |

---

### 7. 替代方案对比

| 方案 | 优点 | 缺点 | 推荐度 |
|------|------|------|--------|
| A. 菜单栏切换 + 列表管理 | 操作快捷，结构清晰 | 菜单可能较长 | ⭐⭐⭐ |
| B. 仅设置窗口切换 | 实现简单 | 切换需多步操作 | ⭐⭐ |
| C. 快捷键循环切换 | 最快切换 | 用户不知道有哪些模型 | ⭐ |

**推荐方案 A**：菜单栏子菜单 + 设置窗口列表管理

---

### 8. 示例预设模型

提供常见模型预设，方便用户快速添加：

```swift
struct LLMModelPresets {
    static let all: [LLMModel] = [
        LLMModel(
            name: "OpenAI GPT-4o",
            apiBaseURL: "https://api.openai.com/v1",
            model: "gpt-4o"
        ),
        LLMModel(
            name: "OpenAI GPT-4o-mini",
            apiBaseURL: "https://api.openai.com/v1", 
            model: "gpt-4o-mini"
        ),
        LLMModel(
            name: "DeepSeek Chat",
            apiBaseURL: "https://api.deepseek.com/v1",
            model: "deepseek-chat"
        ),
        LLMModel(
            name: "Claude 3.5 Sonnet",
            apiBaseURL: "https://api.anthropic.com/v1",
            model: "claude-3-5-sonnet-20241022"
        ),
        LLMModel(
            name: "SiliconFlow (国内)",
            apiBaseURL: "https://api.siliconflow.cn/v1",
            model: "Qwen/Qwen2.5-72B-Instruct"
        )
    ]
}
```

用户添加模型时，可选择从预设导入或自定义。
