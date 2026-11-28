# 应用架构计划 v2（壳层 / 播放层 / 分区 / 弹幕面板 / 真全屏）

> 依据：通读 DTV 前端（`AppShell` / `routes` / `PlayerUiProvider` / `CategoryBar` /
> `DanmuPanel` / `PlayerControls` / `usePlayerFullscreen` / `lib/window.ts`）与
> Simple Live（`live_room_page.dart` 916 行、`player_controls.dart` 1046 行）。
> 结论先行：**DTV 的壳层架构要照搬思路，播放器必须变成"壳内一层"，而不是独立页面。**

---

## 1. DTV 的做法与好处（读到的原文结论）

### 1.1 壳层：播放时侧栏不消失

```
AppShell
├── Sidebar            ← 关注栏，常驻（全屏时才隐藏）
└── appMain
    ├── Navbar         ← 平台 tab + 搜索
    └── main
        ├── HomeStack      ← 常驻（keep-alive），只是隐藏
        ├── SubscribeStack ← 常驻
        └── Outlet        ← /player 渲染在这里
```

- 播放页是**路由** `/player?platform=&roomId=`，渲染在 `main` 里 ⇒ **侧栏和顶栏都还在**，
  所以能在播放时点侧栏换直播间。这正是你说的"dtv播放时左侧关注栏依旧可以切换"。
- `HomeStack` / `SubscribeStack` 常驻（`Activity` 隐藏）⇒ 从播放返回列表时**不重新加载**。
- `PlayerRoute` 用 `key={platform:roomId}` ⇒ 换房间**整页重建**，
  避免"旧直播间声音没断、新的只是叠上去"（注释里明确记了这个坑）。
- 全屏时 `hideChrome = isFullscreen` ⇒ 外壳整体让位，视频铺满。

### 1.2 两种全屏（我们要分别实现）

| 类型 | 效果 | DTV 实现 | 我们对应 |
|---|---|---|---|
| `cssFullscreen` | 播放器铺满**应用窗口**，侧栏/顶栏让位；系统窗口不变、任务栏可见 | CSS | `_chromeHidden` 状态，壳层让位 |
| `nativeFullscreen` | **真全屏**，覆盖任务栏 | Wails 窗口 API `toggleWindowFullscreen()` | **`window_manager`**（Windows）+ `SystemChrome` immersive（iOS/Android） |

两者都派生出 `isFullscreen` → 壳层隐藏 chrome。

### 1.3 控件自动隐藏

`usePlayerFullscreen` 里维护 `chromeIdleTimer`：鼠标移动重置计时，空闲后隐藏 chrome；
隐藏时若下拉菜单/弹窗打开则**不隐藏**（`[role="dialog"],[role="menu"]` 判定）。
——我们现在是固定 3.5s，需要补"菜单打开时不隐藏"这条。

### 1.4 分区栏（解决"分区显示不全"）

`CategoryBar` 的三段结构：

```
第一行  一级分区：文字 tab + 下划线指示器（选中）
第二行  二级分区：chip 横滑；**溢出时出现「全部 ⌄」按钮**
        点击 → 浮层面板（该分组全部分区，网格排列，「36 个分区」计数）
        同行右侧：+ 订阅分区
第三行  三级分区（仅斗鱼有）：全部 / S15 / 赛事直播 …
```

细节：
- 溢出判定用 `scrollWidth - clientWidth > 2`（真实测量，不是猜数量）
- 浮层：Esc 关闭 / 点外部关闭 / 换一级分组自动关
- **滚动后 compact 模式**：一级+二级收成面包屑 `网游 › 英雄联盟 ⌄` + 「全部分区」，
  三级分类仍完整保留 —— 给内容让出高度

> 这就是你说的"分区依旧显示不全"的正解：不是把所有分区塞一行，
> 而是**行内横滑 + 溢出的进浮层**，并且浮层里是网格全量。

### 1.5 弹幕面板（右侧）

`DanmuPanel`：默认 **196px**，可拖拽 **168–320px**
- 头部：`弹幕` + 关闭按钮
- 列表：`Lv.x 用户名 内容`，系统消息（进场/礼物）弱化样式、不伪装成聊天
- **上滑时暂停自动跟随**，回到底部恢复；期间新消息累计，浮出「新弹幕」胶囊点击回底
- 最多渲染 **200 条**；空态 `暂无弹幕，正在连接…`

### 1.6 播放页其它（`PlayerPage.tsx`）

- 弹幕订阅独立在 `DanmakuFeed`：**切线路不重建弹幕连接**，新消息不重渲染整页
- `PlayerCaptionButtons`：画面右下的悬浮按钮组（弹幕设置/屏蔽/彩色等）
- 键盘：Esc 退出、空格播放暂停（`usePlayerFullscreen` 里也处理 Esc）

---

## 2. Simple Live 的做法（手机端参考）

- `live_room_page.dart`（916）+ `live_room_controller.dart`（1065）+ `player_controls.dart`（1046）
- **全屏页面**，没有侧栏（手机形态），手势：单击显隐控件、双击播放暂停、上下滑音量/亮度
- 控件：线路、清晰度、弹幕设置、全屏；自动隐藏 Timer

**取舍**：桌面用 DTV 的壳内播放；手机用 Simple Live 的全屏页 + 手势。同一套组件，两种编排。

---

## 3. 目标架构（Flutter）

### 3.1 壳层

```
RootScaffold
├── 桌面（≥1024）
│   Row
│   ├── Sidebar            关注栏（可折叠 240 ↔ 72）
│   └── Column
│       ├── Navbar         平台分段 + 搜索
│       └── Stack
│           ├── IndexedStack(Home / 分区 / 发现 / 我的)   ← 保活
│           └── PlayerLayer                             ← 壳内一层
└── 手机（<600）
    Stack
    ├── IndexedStack(四个 Tab) + 底部 NavigationBar
    └── PlayerLayer（全屏覆盖，含返回）
```

**关键改动：播放不再是 `Navigator.push` 的新页面，而是壳内的一层 `PlayerLayer`。**

理由（DTV 已验证）：
1. 侧栏在播放时可用 → 直接换直播间（新需求）
2. 返回列表不重建、不重新请求（`IndexedStack` 保活）
3. 全屏只是"壳层让位"，不需要路由栈操作
4. 换房间靠 `ValueKey('$platform:$roomId')` 强制重建播放层，避免旧播放器残留

### 3.2 播放层状态机

```
closed  → 打开直播间 → panel   （壳层可见，视频在内容区）
panel   → css 全屏            → 壳层让位，视频铺满应用窗口
panel   → native 全屏         → window_manager 窗口全屏（覆盖任务栏）/ SystemChrome immersive
任意     → Esc / 返回 / 切 Tab → closed（卸载播放器，停弹幕）
```

新增 `PlayerSession`（ChangeNotifier）：当前 `platform+roomId+variants+lines`、
全屏态、弹幕面板开关、控件显隐。壳层读它决定是否让位。

### 3.3 分区栏 v2（照 DTV 形态，用我们的配色）

- 第一行：一级分组（文字 tab + 底部 2px 指示条），横滑
- 第二行：二级分区 chip 横滑 + **溢出时「全部 ⌄」按钮** + 「订阅」按钮（先占位）
- 浮层：`Overlay` 或 `Stack` 面板，网格 5 列，标题 + `N 个分区`，点外部/Esc 关闭
- 第三行：三级分区（斗鱼，接口已有 `FetchThreeCate`；先跳过，数据层未接）
- 滚动 > 120px：切成 compact 面包屑模式

### 3.4 弹幕面板

- 桌面右侧 240px（可拖 168–320），手机为底部抽屉
- 上滑暂停跟随 + 「新弹幕 N」胶囊
- 最多 200 条；系统消息弱化
- 与画布弹幕共用同一个 `DanmakuClient.messages` 流（不额外订阅）

### 3.5 关注栏

DTV `FollowsList.tsx` 1121 行，能力包括：分组、拖拽排序、搜索、在线状态、折叠。
**第一版做**：列表（头像/昵称/标题/LIVE 点）、在线红点、点击换台、
右键菜单（取消关注 / 复制房间号）、折叠按钮、拖拽排序。
**后续**：分组、搜索、同步（DTV 有 `LanSyncModal`）。

### 3.6 返回逻辑

| 场景 | 行为 |
|---|---|
| 播放中按 Esc（桌面） | 关闭播放层，回到列表（原地，不重新加载） |
| 播放中点返回按钮 | 同上 |
| 手机系统返回 | 同上（`PopScope` 拦截，先关播放层） |
| 全屏中按 Esc | 先退全屏，再按才关闭播放层 |
| 侧栏点另一间房 | 不关闭播放层，直接换房间（key 变 → 重建） |

---

## 4. 新增依赖与风险

| 项 | 说明 | 风险 |
|---|---|---|
| `window_manager` | 桌面真全屏、最大化、窗口尺寸事件 | 需 CI 验证 Windows 构建；iOS/Android 不使用（走 SystemChrome） |
| 无其它新依赖 | 分区浮层用 `Overlay/Stack`，弹幕面板手写，不引 UI 库 | — |

⚠️ `window_manager` 在 Windows 上需要 `await windowManager.ensureInitialized()`
并在 `main()` 里设置 `WindowOptions`；**先单独验证一次 CI 构建**，再往上叠功能。

---

## 5. 分阶段实施（每阶段都能单独验证）

| 阶段 | 内容 | 验收 |
|---|---|---|
| **P1** | 壳层重构：Sidebar + Navbar + **PlayerLayer**（桌面壳内 / 手机全屏） | 播放时桌面侧栏可见可切换；返回列表不重新加载 |
| **P2** | 分区栏 v2：两级 + 溢出「全部」浮层 + compact 面包屑 | 斗鱼/B站分区能看全、能切换 |
| **P3** | 真全屏：`window_manager`（Windows）+ SystemChrome（手机）；Esc/双击切换 | 全屏覆盖任务栏、退出正常 |
| **P4** | 弹幕面板（右侧 240 可拖）+ 新弹幕胶囊 | 上滑不抢滚动、新消息提示 |
| **P5** | 关注栏（分组/排序/右键菜单） | 换台、排序、折叠 |
| **P6** | 订阅分区页 + 分区订阅按钮生效 | 订阅后可直达 |

先做 P1+P2（结构性与用户明确指出问题），P3 单独验证依赖，P4/P5 随后。

---

## 6. 不做 / 延后

- 小窗 PiP（需要额外插件，DTV 有，优先级低）
- 局域网同步、配置导入导出（DTV 有 `lanSync.ts` 587 行，后续）
- 表情包（DTV 的 `emoticons.data.ts` 4408 行，属弹幕增强，后续）
- 三级分区（斗鱼 cate3）：数据层未接，先不做
