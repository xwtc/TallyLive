# 页面（UI）建设计划

> 目标：**先把页面骨架和交互做完整，功能后期再接**。
> 原则：页面只依赖数据接口，先用 Mock 数据跑通布局；接功能时只替换实现，不改页面。

---

## 1. 现状盘点

| 已有 | 说明 |
|---|---|
| 播放页 `player_page` | 已可用：视频、清晰度、线路、弹幕开关、调试面板 |
| 设置页 `settings_page` | 弹幕字号/透明度/存活/区域 + 清空最近 |
| 关于页 `about_page` | 版本、技术栈、平台状态 |
| 首页 `home_page` | **临时的「输房间号」验证入口**，要替换掉 |
| `AppSettings` | 最近打开、弹幕设置（已持久化） |
| 平台客户端 | B 站（播放+弹幕+线路）、斗鱼（播放+弹幕+线路）、虎牙（播放，待验证）、抖音（未做） |

**缺口**：没有分区、没有直播列表、没有搜索、没有关注/收藏管理。这些都需要页面先立起来。

---

## 2. 目标页面结构

沿用 `MOBILE-DESIGN.md` 的**四 Tab**（当前是三 Tab：直播/设置/关于）：

```
底部导航
├── 直播      关注中在播 + 平台精选流
├── 分区      平台 tab → 分区网格 → 该分区直播列表
├── 发现      搜索（四平台）+ 热门
└── 我的      关注管理、登录、播放设置、数据同步、关于

二级页面
├── 播放页    （已有）
└── 调试页    原来的「输房间号」入口，保留为验证/排障工具（release 剔除）
```

> 设置与关于从 Tab 降级为「我的」里的二级入口——四个一级 Tab 全部是"看直播"相关，
> 更符合"个人自用、快速进房间"的定位。

---

## 3. 每页内容清单

### 3.1 直播（首页）

| 区块 | 内容 | 状态 |
|---|---|---|
| 顶部 | 平台筛选 chip（全部/斗鱼/虎牙/抖音/B站） | — |
| 关注中在播 | 横向卡片或紧凑列表：头像、昵称、标题、人气、LIVE 点 | 空态：引导去分区找 / 去分区 |
| 平台精选 | 纵向列表（复用列表行组件），无限滚动 | 加载骨架 / 空 / 错误重试 |

### 3.2 分区

| 层次 | 内容 |
|---|---|
| 一级 | 平台 tab（四平台） |
| 二级 | 分区网格（每行 3–4 个紧凑条目，图标+中文名） |
| 三级 | 该分区直播列表（复用列表行，无限滚动，下拉刷新） |

斗鱼的三级分类（cate1→cate2→cate3）在二级页做成"分组 + 子项"，不额外加层级页面。

### 3.3 发现

| 区块 | 内容 | 状态 |
|---|---|---|
| 搜索框 | 防抖 250ms，回车立即搜 | — |
| 搜索历史 | 最近 10 条，可单删/清空（本地存） | 空态：无历史时隐藏 |
| 结果列表 | 主播卡片（头像/昵称/标题/是否直播） | 无结果空态、加载、错误 |
| 热门 | 各平台热门列表（可选，第一阶段先留空位） | — |

### 3.4 我的

| 分组 | 条目 |
|---|---|
| 账号 | B站 / 斗鱼登录：**扫码 + 粘贴 Cookie 双入口**（Cookie 为必备能力）/ 已登录状态与退出 |
| 关注 | 关注列表管理（排序、分组、删除） |
| 播放 | 默认清晰度、默认线路、播放器内核信息（libmpv） |
| 弹幕 | 进入设置页 |
| 数据 | 局域网同步、导入/导出（先占位） |
| 其他 | 调试页入口（release 隐藏）、关于 |

### 3.5 播放页（已有，微调）

- 从卡片/搜索/关注点击进入，参数改为传 `Streamer` 或 `RoomInfo`
- 其余保持不变

---

## 4. 数据契约（照 DTV 的 `common/types.go`）

页面用到的模型必须在 Dart 侧**沿用 DTV 的字段名**，这样后期把 Mock 换成真实接口时不用改页面。

需要新增（当前 `core/models.dart` 只有 RoomInfo/StreamVariant/StreamLine/StreamUrl/StreamInfoResult）：

```dart
class Category      { String id; String name; }
class CategoryGroup { String id; String name; List<Category> categories; }
class Streamer      { String id, platform, nickname, title, cover, avatar;
                      int viewers; String categoryName; bool isLive; }
class StreamerPage  { List<Streamer> items; int page; bool hasMore; int totalPages; }
class SearchHit     { String id, nickname, title, avatar; bool isLive; }
```

复用已有：`StreamVariant`、`StreamLine`、`StreamUrl`、`StreamInfoResult`（对应 DTV `StreamInfo`）。

---

## 5. 分层：页面只认接口

```
UI（页面/组件）
   ↓ 只依赖
LiveRepository（抽象）
   ├── MockLiveRepository    ← 本轮用这个：返回假数据，可控制延迟/错误/空
   └── PlatformRepository    ← 后期接：内部按 platform 分发到各 Client
          ↓
PlatformClient（已有 + 扩展）
   fetchCategories() / fetchLiveList(page, categoryId) / search(keyword)
```

`PlatformClient` 需要扩展三个方法（对应 DTV 的 `FetchCategories` / `FetchLiveList` / `SearchAnchor|SearchRoom`）：

```dart
Future<List<CategoryGroup>> fetchCategories();
Future<StreamerPage> fetchLiveList({String? categoryId, int page = 1});
Future<List<SearchHit>> search(String keyword);
```

- 已有实现类**暂时抛 `UnimplementedError`**，页面走 Mock，不会崩
- 后期逐个平台补真实实现，页面不动

**Mock 开关**：`const kUseMockData = true;`（或 `--dart-define=MOCK=1`），
release 前后期切成 false；Mock 数据要**看起来真实**（真实昵称/标题/封面 URL）。

---

## 6. 基础组件清单（先做，后面所有页面复用）

| 组件 | 用途 |
|---|---|
| `TallyCard` | 统一卡片：`surface` 底 + `hairline` 边 + 6px 圆角 |
| `StreamerRow` | 直播列表行：头像、昵称、标题、人气、LIVE 点、平台标记 |
| `StreamerGrid` | 网格卡片（分区/精选用）：封面 + 标题 + 昵称 + 人气 |
| `LiveDot` | ON AIR 红点（唯一允许用 tallyRed 的地方） |
| `PlatformChips` | 平台筛选 chip 组 |
| `CategoryTile` | 分区条目：图标 + 名称 + 在播数 |
| `EmptyState` | 空态：图标 + 一行说明 + 可选动作 |
| `ErrorState` | 错误：文案 + 重试按钮 |
| `LoadingList` / `Skeleton` | 加载骨架（3–5 行灰色块） |
| `SectionHeader` | 区块标题 + 右侧动作（更多/刷新） |
| `PullToRefresh` | 统一下拉刷新包装 |

配色沿用 `ui/theme.dart` 的 `TallyColors`（夜间 token），**不要引入新颜色**。

---

## 7. 实施步骤（每步都能单独跑起来看）

| 步 | 内容 | 产出 |
|---|---|---|
| **1** | 基础组件 + 模型补齐（`Streamer`/`Category`/`StreamerPage`/`SearchHit`） | 组件可单独预览 |
| **2** | `LiveRepository` 接口 + `MockLiveRepository`（假数据 30+ 条，含空/错误场景） | 数据层就绪 |
| **3** | 应用骨架：四 Tab + 路由 + 「我的」页（迁移设置/关于入口） | 导航完整 |
| **4** | 直播页：关注在播（空态）+ 平台精选（真列表渲染） | 首页可用 |
| **5** | 分区页：平台 tab → 分区网格 → 列表（含无限滚动/下拉刷新） | 分区可用 |
| **6** | 发现页：搜索框 + 历史 + 结果（Mock 搜索） | 发现可用 |
| **7** | 播放页适配：卡片/列表点击进入；调试页收纳原「输房间号」入口 | 全链路可点 |

后续（功能接入，不在本轮）：
- 各平台 `fetchCategories` / `fetchLiveList` / `search` 真实实现
- 关注/收藏管理（复用 `AppSettings`）
- 扫码登录、局域网同步

---

## 8. 与已有功能的衔接

- **播放页**：已可用，只需把入参从「房间号」改成「点击的卡片」
- **收藏/关注**：`AppSettings` 已有 `recentRooms`；关注列表需要新增 `follows`（结构沿用 DTV：platform+roomId+nickname+avatar+order）
- **调试页**：原首页的「选平台+输房间号」整体搬过去，作为排障工具，`kDiagnosticsEnabled` 门禁
- **弹幕设置**：已在设置页，直接挂到「我的 → 弹幕」

---

## 9. 验收标准

- [ ] 四个 Tab 都能进入，二级页面能返回
- [ ] 每个列表页都有：加载骨架、空态、错误重试
- [ ] 桌面窗口 1440×810 与手机竖屏 390×844 都能正常布局（无溢出、无遮挡）
- [ ] Mock 模式下**不联网也能跑完所有页面**
- [ ] 点击任意卡片能进播放页
- [ ] release 构建里无诊断面板、无连接圆点、无调试 Tab
- [ ] `flutter analyze` 无 error/warning，`flutter test` 全绿

---

## 10. 本轮明确不做

- 登录逻辑（扫码 + Cookie 两种入口的弹层可以先做 UI，按钮提示"待接入"）；**Cookie 登录为必备能力，不可只做扫码**，详见 UI-DESIGN §4.4.1
- 局域网同步 / 导入导出（同上）
- 搜索真实接口
- 分区/列表真实接口
- 抖音平台

---

## 11. 风险与注意

- **不要为 Mock 数据写死布局**：列表必须靠真实的分页/无限滚动组件渲染，否则接功能要返工
- **图片**：Mock 用真实 CDN 图（B站/斗鱼封面），顺带验证图片加载与占位符
- **性能**：列表用 `ListView.builder`，避免一次性构建几百个卡片
- **不要新增依赖**：本轮不引入状态管理库/图标库，用 Flutter 自带的 `Icons` + `ChangeNotifier`
