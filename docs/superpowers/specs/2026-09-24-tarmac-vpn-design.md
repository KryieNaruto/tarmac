# Tarmac — 免费机场节点管理 + 智能连接 App 设计

- 日期：2026-09-24
- 状态：待用户审阅
- 范围：架构级（新项目）

## 1. 背景与目标

用户需要一个 Android App：从若干"机场"订阅源收集免费代理节点，展示每个节点的延迟，并支持切换连接。免费节点存活期短（几小时到几天），因此不采用硬编码节点列表，而是采用**订阅源模式**——App 内置几个已验证存活的订阅 URL，运行时拉取 + 解析 + 测速，用户也可自行增删订阅源。

**最小可落地可用**（用户原话）是首要目标，不做过度设计。

## 2. 范围

### 范围内
- 订阅源管理：内置 4 个默认源，支持启停/删除/编辑/新增
- 拉取订阅 → 自动探测编码格式（整篇 base64 或明文逐行）→ 解析分享链接 → 去重合并
- 逐节点测速（`getServerDelay`，不建立隧道）
- 智能连接：按延迟升序级联尝试真实连接，连上后做真实可达性探测，失败自动换下一个
- 手动连接/断开单个节点
- 基础错误处理（订阅失败/解析失败/测速超时/连接失败均不崩溃、不阻塞其他节点）

### 范围外（YAGNI，明确不做）
- iOS / 桌面端
- 按应用分流 UI（插件支持 `blockedApps` 参数，但先不做设置界面）
- 流量统计图表、自定义 DNS/路由规则编辑器
- 账号系统、云同步

## 3. 技术选型

- **平台**：Flutter，仅构建 Android（minSdkVersion 24），侧载安装（adb install 到用户已打通隧道的真机 `XCD1205AF826201978`），不考虑应用商店合规
- **核心依赖**：[`flutter_v2ray_client`](https://pub.dev/packages/flutter_v2ray_client)（MIT 协议）
  - 内置 Xray 核心，原生 TUN VPN（`VpnService`）
  - `V2ray.parseFromURL(link)` 解析 `vmess://` `vless://` `trojan://` `ss://` `socks://` 分享链接
  - `v2ray.getServerDelay(config: ...)` 真实测速，不需要 VPN 权限
  - `v2ray.requestPermission()` / `startV2Ray(...)` / `stopV2Ray()` / `onStatusChanged` 管理隧道生命周期
  - 选型理由：现成、维护活跃（2026-09-17 仍有更新）、协议覆盖完整，避免自己实现代理协议或 `VpnService`
- **本地持久化**：`shared_preferences`，JSON 编码存储订阅列表、用户手动添加的节点、最近一次延迟缓存、上次连接的节点 ID。不引入 SQLite/Hive——数据量小、结构简单

## 4. 默认内置订阅源（均已实测存活，2026-09-24 验证）

| 源 | Raw URL | 编码格式 |
|---|---|---|
| freefq/free | `https://raw.githubusercontent.com/freefq/free/master/v2` | 整篇 base64 |
| Pawdroid/Free-servers | `https://raw.githubusercontent.com/Pawdroid/Free-servers/main/sub` | 整篇 base64 |
| ermaozi/get_subscribe | `https://raw.githubusercontent.com/ermaozi/get_subscribe/main/subscribe/v2ray.txt` | 明文逐行 |
| mahdibland/V2RayAggregator | `https://raw.githubusercontent.com/mahdibland/V2RayAggregator/master/sub/airport_merge_base64.txt` | 整篇 base64 |

验证方式：`curl` 拉取确认 HTTP 200 + 非空内容，并抽样解码确认内容是可解析的分享链接。调研到的其他仓库（`jichangx/free-nodes` 内容嵌在 README 里不是干净的 raw 端点、`hwanz` `clashv2ray-hub` `chaishpish` 几个路径核实不通）暂不收录，用户可在订阅管理页自行添加。

## 5. 架构

```
lib/
  main.dart
  models/
    proxy_node.dart
    subscription.dart
  services/
    subscription_service.dart   — 拉取订阅、格式探测、解析、去重
    v2ray_service.dart          — 封装 flutter_v2ray_client：初始化/测速/连接/断开/状态流
    smart_connect_service.dart  — 智能连接级联状态机
    storage_service.dart        — shared_preferences 读写
  screens/
    node_list_screen.dart       — 主页
    subscription_screen.dart    — 订阅源管理
  widgets/
    node_tile.dart
    connection_bar.dart
```

## 6. 数据模型

```dart
class ProxyNode {
  final String id;              // md5/hash(rawLink)，用于去重
  final String remark;          // 节点备注（机场给的名字，常带国旗 emoji）
  final String protocol;        // vmess / vless / trojan / ss / socks
  final String rawLink;         // 原始分享链接，交给插件 parseFromURL
  final String sourceSubId;     // 来源订阅 id，或 "manual"
  int? delayMs;                 // 测速结果；null=未测，-1=超时/失败
  DateTime? lastTestedAt;
}

class ProxySubscription {
  final String id;
  String name;
  String url;
  bool enabled;
  DateTime? lastFetchedAt;
  int nodeCount;
  String? lastError;
}
```

## 7. 核心流程

### 7.1 刷新订阅
1. 并发拉取所有 `enabled` 的订阅 URL（单个超时如 10s）
2. **格式自动探测**：尝试对整篇内容做 base64 解码；解码失败，或解码结果不含 `://`，则视为明文，直接按行处理原始内容
3. 逐行喂给 `V2ray.parseFromURL`，解析失败的行跳过并计数
4. 按 `rawLink` 哈希去重，合并进全局节点表（含用户手动添加的节点）
5. 单个订阅拉取/解析失败只记录 `lastError`，不影响其他订阅

### 7.2 批量测速
- 对当前节点表并发调用 `getServerDelay`，并发上限 8
- 逐个回填 `delayMs`，列表实时按延迟升序刷新（超时/失败的沉底显示灰色"超时"）
- 不需要 VPN 权限，不建立隧道

### 7.3 智能连接（核心交互）
单一总开关，点击后的级联状态机：
1. 从节点表中筛出 `delayMs` 有效（非 null 非 -1）的节点，按延迟升序取前 15 个作为候选
2. 依次尝试候选节点 A、B、C...：
   - 若已有隧道在跑，先 `stopV2Ray()`
   - 首次需要 `requestPermission()`（系统 VPN 授权弹窗，只弹一次）
   - `startV2Ray(remark, config: node.getFullConfiguration(), proxyOnly: false)`
   - 等待 `onStatusChanged` 报告隧道建立（或最多等 3s）
   - 对 `https://cp.cloudflare.com/generate_204` 发起 HTTP 请求，5s 超时
   - 成功（收到 204/200）→ 停止级联，状态栏显示"已连接 · 节点X"
   - 失败/超时 → `stopV2Ray()`，换下一个候选
3. 总耗时预算 60s（覆盖 15 个候选 × 单个约 4s），超预算或候选耗尽 → 状态栏显示"全部节点不可用，请刷新订阅重试"
4. 列表里手动点单个节点 = 只单独尝试这一个（同样走"建隧道 + 探测"两步，但不级联到下一个），用于用户手动排查/指定

### 7.4 断开
`stopV2Ray()`，状态栏回到"未连接"。

## 8. UI

**主页（节点列表）**
- 顶部连接状态栏：未连接 / 连接中(级联第几个) / 已连接+节点名+断开按钮 / 全部不可用
- 一键连接按钮（触发 7.3）
- 节点列表：国旗+备注、协议标签、延迟数字+颜色（绿 <150ms、黄 150-400ms、红 >400ms、灰=超时），按延迟升序
- 下拉刷新 = **只**重新拉订阅，不触发测速；测速收敛进「一键连接」内部（猎取过程顺带测速并落盘），不再有独立的测速入口

**订阅管理页**
- 4 个内置源默认开启，可关闭/删除/编辑名字
- 可添加自定义订阅 URL
- 每行显示上次更新时间、节点数、`lastError`（若有）

**设置页**
- 一行风险提示文案："免费公益节点可能被运营方记录流量，不建议登录网银/重要账号"

## 9. 错误处理一览

| 场景 | 处理 |
|---|---|
| 订阅拉取超时/404/内容非法 | 记 `lastError`，跳过，不影响其他源 |
| 单条分享链接解析失败 | 跳过计数，不中断整批 |
| 测速超时 | 标记该节点为超时（灰色），不阻塞其他节点（并发限流 8） |
| VPN 权限被拒 | 提示文案，不崩溃，级联终止 |
| 单节点连接失败 | 智连模式自动换下一个；手动模式提示"连接失败" |
| 级联全部失败 | 状态栏提示"全部节点不可用，请刷新订阅重试" |

## 10. 测试计划

- 单元测试：订阅编码自动探测（base64/明文两种输入）、按 `rawLink` 去重逻辑、延迟排序、智能连接状态机的成功/失败/超预算三种路径
- `flutter analyze` 静态检查
- 交给 `verify-green` 子代理跑完编译+测试闭环，并装到真机 `XCD1205AF826201978` 做一次真实连接验证（人工确认能连上、延迟数字合理、断开正常）

## 11. 风险与免责

免费公益机场节点可能被运营方记录/篡改流量，不适合传输敏感信息。此风险已通过设置页提示文案告知用户（见第 8 节）。
