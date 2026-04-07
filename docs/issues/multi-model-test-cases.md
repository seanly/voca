# 多模型切换功能测试用例

## 测试环境准备

1. 构建应用：`make build`
2. 运行应用：`make run`
3. 首次运行前清理旧配置：
   ```bash
   defaults delete com.yetone.Voca 2>/dev/null; rm ~/Library/Logs/Voca.log 2>/dev/null
   ```

---

## 测试用例列表

### TC-01: 首次启动自动迁移旧配置

**前置条件**: 应用之前配置过旧版单模型

**步骤**:
1. 在旧版本配置一个模型（设置 API Key）
2. 升级到新版本
3. 启动应用
4. 打开菜单栏 → LLM Refinement → Manage Models...

**预期结果**:
- [ ] 旧配置自动迁移为名为 "Default" 的模型
- [ ] API Key、Base URL、Model 值保持不变
- [ ] 该模型被自动选中

**验证方法**:
```bash
# 检查日志
cat ~/Library/Logs/Voca.log | grep "Migrated"
# 应显示: "Migrated legacy LLM config to new format"
```

---

### TC-02: 添加新模型

**步骤**:
1. 打开菜单栏 → LLM Refinement → Manage Models...
2. 点击 [+] 按钮
3. 选择预设 "DeepSeek Chat"
4. 修改名称: "My DeepSeek"
5. 输入 API Key: `sk-test123`
6. 点击 [Save]

**预期结果**:
- [ ] 模型列表显示新添加的 "My DeepSeek"
- [ ] 状态显示 "Enabled"
- [ ] 菜单栏 → LLM Refinement → Select Model 子菜单显示新模型

---

### TC-03: 从预设添加模型

**步骤**:
1. 点击 [+] 添加模型
2. Preset 下拉选择 "SiliconFlow Qwen"
3. 不修改其他字段
4. 输入 API Key
5. 点击 [Save]

**预期结果**:
- [ ] Name 自动填充为 "SiliconFlow Qwen"
- [ ] API Base URL 自动填充为 "https://api.siliconflow.cn/v1"
- [ ] Model 自动填充为 "Qwen/Qwen2.5-72B-Instruct"

---

### TC-04: 自定义添加模型

**步骤**:
1. 点击 [+] 添加模型
2. Preset 保持 "Custom..."
3. 填写:
   - Name: "Custom GPT"
   - API Base URL: `https://my-proxy.example.com/v1`
   - API Key: `sk-custom`
   - Model: `gpt-4`
4. 勾选 "Enabled"
5. 点击 [Save]

**预期结果**:
- [ ] 模型成功添加
- [ ] 所有字段值正确保存

---

### TC-05: 编辑模型

**步骤**:
1. 在列表中选择一个模型
2. 点击 [Edit] 按钮
3. 修改名称为 "Updated Name"
4. 修改 API Key
5. 点击 [Save]

**预期结果**:
- [ ] 列表中显示更新后的名称
- [ ] 菜单栏中的模型名称同步更新

---

### TC-06: 删除模型

**步骤**:
1. 在列表中选择一个模型
2. 点击 [-] 按钮
3. 确认删除对话框点击 [Delete]

**预期结果**:
- [ ] 模型从列表中移除
- [ ] 菜单栏 Select Model 子菜单中不再显示
- [ ] 如果删除的是当前选中模型，自动选择其他可用模型

---

### TC-07: 禁用/启用模型

**步骤**:
1. 编辑一个模型
2. 取消勾选 "Enabled"
3. 点击 [Save]
4. 查看菜单栏 Select Model 子菜单

**预期结果**:
- [ ] 被禁用的模型不在 Select Model 子菜单中显示
- [ ] 列表中状态显示为 "Disabled"

**步骤 (续)**:
5. 重新编辑该模型，勾选 "Enabled"
6. 点击 [Save]

**预期结果**:
- [ ] 模型重新出现在 Select Model 子菜单中

---

### TC-08: 菜单栏切换模型

**步骤**:
1. 确保至少配置了 2 个模型（Model A 和 Model B）
2. 打开菜单栏 → LLM Refinement → Select Model
3. 确认 Model A 当前被选中（显示 ✓）
4. 点击选择 Model B

**预期结果**:
- [ ] Model B 显示选中状态（✓）
- [ ] Model A 选中状态取消
- [ ] 日志文件记录使用 Model B 的配置

**验证方法**:
```bash
# 触发一次语音输入后检查日志
cat ~/Library/Logs/Voca.log | grep "model="
# 应显示 Model B 的 model 值
```

---

### TC-09: 无模型时的提示

**步骤**:
1. 删除所有模型
2. 打开菜单栏 → LLM Refinement → Select Model

**预期结果**:
- [ ] 显示 "No models configured"（灰色不可点击）

---

### TC-10: 测试模型连接

**步骤**:
1. 配置一个有效的模型（如 OpenAI，填入真实 API Key）
2. 在列表中选中该模型
3. 点击 [Test Selected] 按钮

**预期结果** (有效 Key):
- [ ] 显示 "✅ Success: ..." 对话框

**步骤**:
4. 配置一个无效 Key 的模型
5. 选中并点击 [Test Selected]

**预期结果** (无效 Key):
- [ ] 显示 "❌ Failed: ..." 错误信息

---

### TC-11: 多模型下语音输入使用正确模型

**步骤**:
1. 配置 Model A (OpenAI) 和 Model B (DeepSeek)
2. 在菜单栏选择 Model B
3. 触发语音输入（按 Fn 说话）
4. 观察日志

**预期结果**:
- [ ] 请求发送到 Model B 的 API Base URL
- [ ] 使用 Model B 的 model 参数
- [ ] 使用 Model B 的 API Key

**验证**:
```bash
cat ~/Library/Logs/Voca.log | tail -20
# 应看到 Model B 的 URL 和 model 值
```

---

### TC-12: 删除当前选中模型后的回退

**步骤**:
1. 配置 2 个模型 A 和 B
2. 选中模型 A
3. 在设置窗口中删除模型 A

**预期结果**:
- [ ] 自动选中模型 B（第一个启用的模型）
- [ ] 菜单栏 Select Model 显示模型 B 被选中

---

### TC-13: 数据持久化

**步骤**:
1. 添加/编辑/删除一些模型
2. 完全退出应用（Cmd+Q）
3. 重新启动应用
4. 打开 Manage Models...

**预期结果**:
- [ ] 所有模型配置完整保留
- [ ] 上次选中的模型仍然被选中

---

### TC-14: 菜单栏快速查看当前模型

**步骤**:
1. 配置一个模型，名称较长
2. 鼠标悬停在菜单栏 LLM Refinement → Select Model → 某个模型上

**预期结果**:
- [ ] 显示 Tooltip: "model-name @ https://api.xxx.com/v1"

---

## 回归测试

### RT-01: 语音输入基本功能

**步骤**:
1. 配置一个有效的模型
2. 启用 LLM Refinement
3. 按住 Fn 说话
4. 松开 Fn

**预期结果**:
- [ ] 语音识别正常
- [ ] LLM 优化正常执行
- [ ] 最终文本正确粘贴

---

### RT-02: ESC 取消功能

**步骤**:
1. 触发语音输入
2. 在 LLM 优化过程中按 ESC

**预期结果**:
- [ ] LLM 请求被取消
- [ ] 悬浮面板关闭

---

## 性能测试

### PT-01: 大量模型处理

**步骤**:
1. 添加 10+ 个模型
2. 打开菜单栏 Select Model

**预期结果**:
- [ ] 菜单响应流畅
- [ ] 所有模型正确显示

---

## 清理

测试完成后清理:
```bash
# 退出应用后执行
defaults delete com.yetone.Voca 2>/dev/null
rm ~/Library/Logs/Voca.log 2>/dev/null
```
