# DESIGN.md · 阿圈短剧视觉规范

> 这是本项目的**唯一设计真源**。所有颜色、字号、间距、圆角、动效时长都必须能在本文找到出处，并在 `lib/theme/` 找到对应实现。
> 改视觉先改这里 + `lib/theme/`，再改屏幕；**不要在 widget 里写字面量**。

---

## 1. 设计方向：影视剧场感

短剧 / 影视 / 阅读是沉浸式内容消费，界面应当像影厅而不是后台管理系统。

| 原则 | 含义 |
|---|---|
| 内容优先 | 封面、剧照、标题是主角；界面元素退到背景里 |
| 深色为基准 | 深色是主要观看环境；浅色是同一套体系的「暖白剧场」派生，不重做另一套风格 |
| 暖橙只做强调 | 品牌色 `#FF7A45` 出现在主操作、选中、进度、必要角标；不做大面积铺色 |
| 光晕有条件 | 渐变与光晕只允许出现在 §7 白名单的 3 处场景 |
| 层级靠明度 | 用表面明度分层（`canvas → surface1 → surface2 → surface3`），不靠投影堆叠 |

浅色模式规则：同一暖色相降饱和 + 提高明度；**不启用光晕、不使用深色渐变**。

---

## 2. 色彩

### 2.1 三层结构

| 层 | 代码位置 | 规则 |
|---|---|---|
| L1 原始值 | `lib/theme/app_color.dart` 私有常量 | **全库唯一**允许写 `Color(0x...)` 的文件 |
| L2 语义 | `AppColors`（同文件） | UI 只引用这一层；深浅两套由 `AppColors.light()` / `.dark()` 提供 |
| L3 组件 | 各组件内部私有 | 由 L2 派生，不得引入新色值 |

访问：`context.app.colors.xxx`（推荐）或 `Theme.of(context)` 的组件主题。

### 2.2 品牌橙阶

| 阶 | 值 | 用途 | 是否已暴露为 L2 |
|---|---|---|---|
| orange50 | `#FFF2EC` | 浅色下强调底 | 待批次②增补 |
| orange100 | `#FFE0D1` | 浅色选中底 | 待批次②增补 |
| orange200 | `#FFC4A8` | 浅色描边 | 待批次②增补 |
| orange400 | `#FF8C5C` | `brandHover` / 深色 `focusRing` | ✅ |
| **orange500** | **`#FF7A45`** | **`brand`**（= `AppTheme.seed`，**不得改动**） | ✅ |
| orange600 | `#F05F27` | `brandPressed` / 浅色 `focusRing` | ✅ |
| orange700 | `#C94815` | 深色下文字强调 | 待批次②增补 |

### 2.3 表面（Surface）

| Token | 深色 | 浅色 | 用途 |
|---|---|---|---|
| `canvas` | `#0A0A0B` | `#FAF7F5` | 页面背景（`scaffoldBackgroundColor`，深浅均显式赋值） |
| `surface1` | `#121214` | `#FFFFFF` | 卡片 |
| `surface2` | `#191A1D` | `#F4EFEB` | 抬升块 / 输入框 / hover 底 |
| `surface3` | `#222327` | `#FFFFFF` | 弹窗 / 抽屉 / pressed 底 |
| `hairline` | `#FFFFFF12` | `#E6DFD9` | 1px 分隔线与卡片描边（**只做线，不可当文字色**） |
| `outline` | `#8E8985` | `#7C756F` | 描边 / 淡文字（M3 `outline`）。必须同时满足「能当文字读」与「能当描边看」：浅 4.55:1、深 5.7:1 |

### 2.4 文字

| Token | 深色 | 浅色 | 对比度（对 canvas） | 用途 |
|---|---|---|---|---|
| `textPrimary` | `#F2EFED` | `#121214` | ≥15:1 | 正文、标题 |
| `textSecondary` | `#A6A19D` | `#5F5852` | ≥6.3:1 | 次要正文、副标题 |
| `textTertiary` | `#736E6A` | `#96908A` | ≥3.8:1 | 辅助信息（**仅限 ≥12px，且不得承载唯一语义**） |

### 2.5 语义色

| Token | 深色 | 浅色 |
|---|---|---|
| `success` | `#4CC38A` | `#14804A` |
| `warning` | `#E5B34D` | `#A66A00` |
| `danger` | `#FF6B5B` | `#C13515` |
| `info` | `#6BA6FF` | `#1668C1` |
| `focusRing` | `#FF8C5C` | `#F05F27` |

> 语义色**不得**只靠颜色传达状态：必须同时有图标或文案（WCAG 1.4.1）。

---

## 3. 字体与字阶

字体族：`Inter`（西文与数字，随包内置 400/500/600/700，授权见 `assets/fonts/inter/OFL.txt`）。
中文回落链：`Microsoft YaHei UI` → `Microsoft YaHei` → `PingFang SC` → `Noto Sans CJK SC`。

| 名称 | size | weight | lineHeight | letterSpacing | 用途 | 代码 |
|---|---|---|---|---|---|---|
| `display` | 30 | 700 | 1.10 | -0.5 | 首页头图标题 | `context.app.display` |
| `h1` | 24 | 600 | 1.20 | -0.3 | 详情页剧名 | `context.app.h1` |
| `h2` | 20 | 600 | 1.25 | -0.2 | 分区大标题 | `context.app.h2` |
| `h3` | 17 | 600 | 1.30 | -0.1 | 卡片组标题 | `context.app.h3` |
| `title` | 15 | 600 | 1.35 | 0 | 卡片标题 / 列表主行 | `context.app.title` |
| `body` | 14 | 400 | 1.55 | 0 | 正文 | `context.app.body` |
| `bodyStrong` | 14 | 600 | 1.45 | 0 | 强调正文 / 按钮文字 | `context.app.bodyStrong` |
| `label` | 13 | 500 | 1.40 | 0 | 次要信息 / 元数据 | `context.app.label` |
| `caption` | 12 | 400 | 1.40 | 0 | 说明 / 辅助 | `context.app.caption` |
| `micro` | 11 | 600 | 1.30 | +0.4 | 大写小标签（「更新至」「广告」） | `context.app.micro` |

**数字专用**：集数、时长、评分、名次、百分比一律用 `context.app.numbers`（`FontFeature.tabularFigures()`，等宽数字，避免数值跳动时抖动）。

**M3 槽位映射**（与 M3 直觉不同，勿按 M3 习惯取用）：

| M3 槽位 | 实际字阶 |
|---|---|
| `displaySmall` | `display` |
| `headlineMedium` | `h1` |
| `headlineSmall` | `h2` |
| `titleLarge` | `h3` |
| `titleMedium` | `title` |
| `bodyMedium` | `body` |
| `bodyLarge` | `bodyStrong` |
| `titleSmall` | `label` |
| `bodySmall` | `caption` |
| `labelSmall` | `micro` |

**不适用**：阅读器正文（`lib/core/reader/reader_typography.dart`）是用户可配置的独立体系，**不并入**本字阶。

---

## 4. 间距

刻度（`context.app.metrics.s2 … s64`）：`2, 4, 6, 8, 12, 16, 20, 24, 32, 40, 48, 64`。

- **刻度外的值不得出现在布局中。**
- 组内间距小于组间间距（Gestalt）：同一卡片内元素用 `s4/s6/s8`，卡片之间用 `s12/s16`，分区之间用 `s24/s32`。
- 优先用 `Column(spacing: …)` / `Wrap(spacing: …)`，避免嵌套 `SizedBox`。

---

## 5. 圆角与描边

| Token | 值 | 用途 |
|---|---|---|
| `radiusXs` | 4 | 小控件 / 标签 |
| `radiusSm` | 8 | 输入框 / chip / Rail 项 |
| `radiusMd` | 12 | 卡片（保持既有观感） |
| `radiusLg` | 16 | 面板 / 弹窗 |
| `radiusXl` | 24 | 大容器 |
| `radiusPill` | 999 | 胶囊 / 头像 / 角标 |
| `hairline` | 1 | 分隔线与卡片描边（配 `colors.hairline`） |
| `focusRing` | 2 | 焦点环（外扩 2） |

---

## 6. 动效

| 名称 | 时长 | 曲线 | 用途 |
|---|---|---|---|
| `micro` | 120ms | easeOutCubic | 图标 / 角标状态切换 |
| `hover` | 150ms | easeOut | hover / pressed 反馈 |
| `enter` | 200ms | easeOutCubic | 卡片入场、展开 |
| `panel` | 250ms | easeOutCubic | 弹窗 / 底部面板 |
| `page` | 300ms | easeInOutCubic | 路由转场 |

**无障碍**：动画时长必须经过 `AppMetrics.reduceMotionOf(context, duration)`；系统开启「减少动效」时它返回 `Duration.zero`（只压时长，不删代码路径）。

**不做**：布局属性动画（`width`/`height` 补间）、超过 500ms 的常规动效、无意义的持续动画。

---

## 7. 光晕白名单（严格 3 处）

| 场景 | Token | 形态 |
|---|---|---|
| 发现页头图 / 继续观看横幅 | `metrics.brandGlowSoft` | 径向渐变 `brand@28%` → 透明，半径 = 容器短边 ×1.2 |
| 播放器主操作（播放 / 重播） | `metrics.brandGlowStrong` | 外发光 `brand@36%`，模糊 24 |
| 沉浸态指示（全屏 / 投屏连接中） | `metrics.brandGlowPulse` | 呼吸光晕，周期 500ms，respect reduceMotion |

**禁止**：列表卡片背景渐变、按钮常态渐变、文字渐变、第四处光晕、任何自造 `BoxShadow` 彩色投影。
`BrandGlow` 构造函数是私有的——**无法**在别处造出第四种光晕，这是刻意的设计约束。

---

## 8. 组件

组件在 `lib/widgets/ui/`（果冻族在 `lib/widgets/jelly/`），统一通过 `context.app` 取 Token。

| 组件 | 契约要点 |
|---|---|
| `AppInteractive` | 四态基座（hover / pressed / focus / disabled）。`onTap == null` 时不可点、不抢焦点、退化为静态容器。可点击时自动 `SystemMouseCursors.click`。 |
| `AppCard.cover` | 3:4 封面 + 标题 + 副标题 + 可选角标。封面**必须外部传入**（走既有 `CoverImage`，不得 `Image.network`）。**无渐变遮罩**。 |
| `AppCard.wide` | 16:9 缩略图 + 右侧文字块。用于继续观看 / 历史 / 推荐。 |
| `AppCard.row` | 前导图标或图 + 主标题 + 次行 + 尾部控件。用于设置项 / 源列表 / 规则列表。 |
| `AppBadge` | 角标 / 名次 / 状态。`tone`: brand / neutral / success / warning / danger；`size`: sm / md。 |
| `AppSectionHeader` | 分区标题 + 可选副标题 + 可选右侧动作 + 可选折叠（`keyboard_arrow_up/down`，tooltip「收起…」/「展开…」）。 |
| `AppEmptyState` | 空态：标题 + 说明 + 可选 CTA + 可选图标，垂直居中。 |
| `AppStatusView` | 三态容器：`loading()` / `error()` / `empty()`。**`loading` 只渲染 `AppLoading()`**，不新增转圈规格、不恢复骨架屏。错误文案走 `AquaException.friendlyText`；「立即重置」仅在调用方传入 `onResetDevice` 时出现。 |
| `AppToast` | `AppToast.show(context, msg)` / `showAction(...)`。内部 `ScaffoldMessenger.maybeOf` + `mounted` 检查，视觉走 `snackBarTheme`。 |
| `AppIcons` | 语义图标集。**全库唯一**允许写裸 `Icons.*` 的地方；统一 `_rounded`；社区入口固定 `Icons.chat_bubble`（`Icons.forum*` 在 MaterialIcons 里无字形）。 |
| `AppPullRefresh` | 品牌下拉刷新（`ui/`）。API 仿 RefreshIndicator：child 是 `CustomScrollView` 走 sliver 路线（并入 `CupertinoSliverRefreshControl`，硬前提 Bouncing 物理——Android 手感由 clamp 变弹性），否则降级品牌色 `RefreshIndicator`（全库唯一出现处）。armed=拉距水滴（`dropletPath` 越拉越鼓）/ refreshing=**`AppLoading.inline()`**（NEVER DO #7）/ done=150ms 回吸淡出经 `reduceMotionOf`。触发距离 70pt。 |
| `JellyProgressBar` | 全站统一进度条（`jelly/`）。`value==null` 不确定态 = `GroundDashes` 90px/s 左移（reduceMotion 停帧）；确定态 = 胶囊轨道（surface3）+ 品牌橙填充 + 前端水滴帽（`dropletPath`），150ms easeOut 经 `reduceMotionOf`。Semantics：进度 N% / 加载中。**字节/百分比进度必须确定态**（语义错配打回）；高 6，勿再包 ClipRRect（自带胶囊裁切，外包会裁掉水滴帽溢出）。 |

### 交互状态规范（所有可点击元素）

| 状态 | 视觉 |
|---|---|
| Default | `surface1` 底 + `hairline` 描边 |
| Hover | `surface2` 底 + `brand`@40% 描边，150ms |
| Pressed | `surface3` 底 + 缩放 0.985 |
| Focus | 2px `focusRing` 环，外扩 2 |
| Disabled | `Opacity(0.5)` + `basic` 光标 |
| Selected | `surface2` 底 + `brand`@40% 描边（与 hover 同视觉语言，靠持久性区分） |

---

## 9. 无障碍

- 正文对比度 ≥ 4.5:1，大字（≥18px 粗体 / ≥24px）≥ 3:1，UI 组件边界 ≥ 3:1。
- `textTertiary` 只用于 ≥12px 的辅助信息，且该信息不得是**唯一**的信息载体。
- 所有焦点可到达的元素必须有可见焦点环；不得移除焦点视觉而不给替代。
- 纯图标按钮必须有 `tooltip`（同时作为屏幕阅读器标签）。
- 状态不得只用颜色表达（配图标或文案）。
- 动画必须 respect `MediaQuery.disableAnimations`。

---

## 10. 文案

- 主文案动词开头、陈述结果：「继续观看」「已缓存 3 集」，不用「点击这里」。
- 空态 = 现状 + 下一步：标题说明「还没有缓存的剧集」，说明给一句怎么做。
- 错误文案带可定位信息：未映射错误码必须带 `code`（`出了点小问题（TRANSPORT），请稍后再试`）。
- 数字与单位之间不加空格（`12 集`→`12集`），时长用 `1:23:45` 而非中文。

---

## 11. NEVER DO

1. 在 widget / screen 里写 `Color(0x...)`、`Colors.white`、`Colors.black`。
2. 写裸 `fontSize:` / `TextStyle(` 而不从 `context.app.*` 取。
3. 用刻度外的间距或圆角值。
4. 在 §7 白名单之外使用渐变 / 彩色投影。
5. 直接写 `Duration(milliseconds: …)` 作为动画时长（必须经 `reduceMotionOf`）。
6. 给 `SeriesCard` 加渐变遮罩，或更换它的 `Icons.local_fire_department` / `Icons.play_arrow`（有测试硬断言）。
7. 新增第三种加载规格，或恢复骨架屏（11-06 已统一为转圈）。
8. 用 `Icons.forum_outlined`（无字形，渲染成豆腐块）。
9. 用 `Image.network` 加载封面（必须走 `CoverImage`）。
10. 在页面里写第二个滚动视口（网格一律用 `SliverSeriesGrid`）。
11. 把 `hairline` 当文字色用（浅色 `#E6DFD9` 对白底只有 1.2:1，肉眼几乎看不见）。`colorScheme.outline` 已被映射到可读的 `outline` Token，淡文字请用它或 `onSurfaceVariant`。

---

## 11b. 半流体交互层（果冻）与液态玻璃的分工

> 批次①b/①c/③ 落地后的权威分工表。技术细节（物理内核、参数、踩坑）见
> `spec/frontend/component-guidelines.md` 的「半流体与玻璃」小节。

**三层材质，各管一件事：**

| 层 | 材质 | 用在哪 | 为什么 |
|---|---|---|---|
| 交互层 | **实心果冻**（`JellySurface` / `JellyPress` / `JellySwitch`） | 按钮、chip、Tab 选中态、开关、卡片按压、手势 HUD | 它能形变——物理性质（体积守恒 + 回弹）就是「全新概念」的载体；果冻体有色、有厚度、高光明显（暖橙主色很好发挥） |
| 悬浮层 | **真折射玻璃**（`AppGlass` 三档：nav / overlay / immersive） | 导航 Rail/Bar、弹层、Toast、播放器 OSD | 形状本来就固定，折射收益最大；shader 绑定超椭圆距离场，**不能**套软体路径（会错位） |
| 内容层 | 实体表面（`canvas / surface1..3`） | 一切列表、卡片、设置行 | 玻璃背后必须有内容，否则和实体面板没区别（Rail 第一版实测过） |

**手感三档**（`lib/theme/jelly_tokens.dart`，六参数之外不加参）：

| 档 | 观感 | 用在哪 |
|---|---|---|
| `jellySnap` | 弹、脆（3–4 次余摆） | 按钮 / chip / Tab / 开关 |
| `jellyFlow` | 软、慢 | 卡片 hover / 面板展开 |
| `jellyMelt` | 流动感 | 播放器手势 HUD / Toast 形变 |

**按压果冻的钉死参数**（被 `test/widgets/jelly_press_test.dart` 固化）：
`JellyPress` k=460 / c=8（ζ≈0.187，松手必须反向鼓起 + crossing ≥ 3）、
压缩 8.5%、倾斜 2.2°。想调手感的对照表：

| 你的感觉 | 改什么 |
|---|---|
| 不够弹、想再 duang 几下 | c 降到 6（ζ≈0.14，能弹 5–6 下） |
| 压扁幅度不够、想更「胖」 | strength 提到 0.10–0.12 |
| 想更歪、更有重量 | tilt 提到 3.5° |
| 弹得太久有点晕 | c 提到 11（ζ≈0.26，2 下收住） |

**加载与进度件口径**（11-15 批次）：加载只有 `AppLoading` 两规格（页面级 / 行内级，NEVER DO #7 不变）；`AppPullRefresh` 与 `JellyProgressBar` 是**进度 / 手势组件**，不构成第三种加载规格——它们的加载中 / 不确定内容一律渲染 `AppLoading` 家族。视觉归属**交互层果冻实心语言**（水滴帽、虚线左移、落步压缩），不糊玻璃（背后无内容，见下条）。

**模糊玻璃判定规则**：只在「背后确实有图/文」的地方开（`JellySurface.backdropBlur`
或真折射档位）；背后是纯色就别糊——白付一次全屏 filter 开销。

---

## 12. 代码入口速查

| 文件 | 内容 |
|---|---|
| `lib/theme/app_color.dart` | L1 色板 + L2 `AppColors`（深浅两套 + `lerpFrom`） |
| `lib/theme/app_typography.dart` | 字体族、回落链、10 级字阶、`tabularFigures`、`textTheme()` |
| `lib/theme/app_metrics.dart` | 间距 / 圆角 / 描边 / 动效 / 光晕三件套 / `reduceMotionOf` |
| `lib/theme/app_tokens.dart` | `AppTokens`（`ThemeExtension`）+ `context.app` + 兜底实例 |
| `lib/theme/app_theme.dart` | `ThemeData` 组装（20 类组件主题、深浅对称） |
| `lib/theme/glass_tokens.dart` | 玻璃三档（nav / overlay / immersive）8 参数 |
| `lib/theme/jelly_tokens.dart` | 果冻三档手感（snap / flow / melt） |
| `lib/theme/player_overlay_theme.dart` | 播放器 OSD 专用 Token（scrim/文字/控件尺寸） |
| `lib/widgets/ui/` | §8 的九个基础组件 |
| `lib/widgets/glass/` | 玻璃适配层（`AppGlass` 门面 / 导航 / 浮层 / 沉浸带） |
| `lib/widgets/jelly/` | 果冻组件（Surface / Button / Press / Switch / 进度水滴 / HUD / Toast 形变） |
| `lib/core/soft_body/soft_ring.dart` | 软体物理内核（Verlet + 面积守恒 + 回位系绳） |
| `scripts/ui_style_audit.py` | 硬编码审计：`--json` / `--compare` / `--write-baseline` |
| `scripts/frame_probe.dart` | 帧率探针：连 VM Service 订阅 `Flutter.Frame` 测 fps |
| `assets/fonts/inter/` | Inter 四字重 + `OFL.txt` |

---

## 13. 变更流程

1. 改设计 → 先改本文表格。
2. 改 L1 色值 → 只动 `app_color.dart`。
3. 改字阶 / 度量 → 只动 `app_typography.dart` / `app_metrics.dart`。
4. 组件契约变化 → 同步 §8 与 `lib/widgets/ui/`，并检查 `spec/frontend/component-guidelines.md` 是否需要更新。
5. 收尾跑 `python scripts/ui_style_audit.py --compare scripts/ui_style_baseline.json`，任何一项计数增加都要先解释清楚。

---

## 14. 待补（后续批次）

| 项 | 归属 | 说明 |
|---|---|---|
| `brandSubtle` / `brandBorder` 语义 Token | 批次② | 对应 orange50/100/200/700，届时删除 `app_color.dart` 里的 `unused_element` ignore |
| 滚动条粗细 Token | 批次⑤ | 目前 `HorizontalScrollStrip` 的 3px 是它自己的契约 |
| 卡片密度扩展 | 批次⑤ | 若出现第四种卡片形态，先加 `AppCardDensity` 枚举，不要新写平行组件 |
| 面板内普通 ListTile 行 → `AppCard.row` | 批次⑤ 尾 | mine 面板内约 20 行仍是 M3 ListTile（开关行已换共享 `SettingsSwitchTile`+`JellySwitch`）；逐行重写量大，按面板分批推进 |
| 裸 `Icons.*` 长尾 | 批次⑤ 尾 | 高频图标已归一（~200 处）；长尾（skip/pause 变体等）后续见到即换 `AppIcons` |
| 头像 rim light 真描边 | 加载动画后续小任务 | alpha 膨胀描边缓存图（`ui.Image` 一次预处理），仅页面级，frame_probe 单帧增量 <0.3ms 才启用；R1.4 现由双波次光扫 + 落步压缩兑现（选项 A，11-15 定案） |
| 11-15 批次真机复验 | 11-15 批次尾 | Android 12+ 冷启动动效图标 / 夜间深橙 / <31 回归 / Windows 冷启动不闪白 / discover 页 Android 弹动手感（B2 sliver 路线硬前提）/ 四页下拉与播放器缓冲角标、下载进度条 |
| UI 审计门禁粒度升级 | 后续治理项 | baseline 停在 f2183df，`--compare` 逐规则总量比对 slack 过大（colors -160），对新增少量违例已无探测力——考虑重写 baseline 或改逐文件粒度（11-15 质检 P2-1；涉及并行会话治理口径，先立项再动） |
| 播放器 JellyProgressBar 白轨道 | 真机复验后定 | `_DelayedProgressBar` 深色 scrim 面板上 surface3 轨道浅色主题下近白（原实现无轨道）；缓冲角标 `AppLoading.inline()` 未传白色同属既有遗留——真机目测不好看再给深色上下文加 color/track 适配（11-15 质检 P2-2） |
| GroundDashes.shouldRepaint 忽略 color | 长尾 | reduceMotion 停帧下主题深浅切换虚线不重绘（11-15 质检 P2-3，既有非回归）；与 P2-2 一起顺手修最省 |
