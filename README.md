# boss-zhipin-auto

Boss 直聘 Android 端**多关键词傻瓜式自动打招呼**脚本 —— 纯 OCR + adb tap,不依赖任何无障碍服务,绕过 Boss 反作弊检测。

## 它做什么

按顺序遍历配置的关键词,每个关键词:

1. 点顶部 chip(`全栈工` / `JavaScript` / `Node` …;主页 chip 栏不全时自动 seed-tap + 左右横扫展开历史)
2. 切「最新」tab
3. 下拉刷新
4. **只点标题命中关键字眼的岗位**(默认:`全栈 / node / php / javascript / ai`,**大小写不敏感**,含 `Node.js / NODE.JS / AIGC / AIOps`)
5. **检查公司是否已沟通过**(读 `boss_contacted.txt`,命中跳过)
6. 点「立即沟通」(自动跳过「继续沟通」—— 已沟通过的不重发)
7. 成功发出后**追加 `[时间] | 公司名 | 岗位` 到 `boss_contacted.txt`**
8. 凑不够 N 条就自动下拉刷新继续,最多刷新 5 次

完整闭环,人类节奏(每步 5-10s 随机等待)。

## 为什么不用 AutoX.js / 无障碍

Boss 后台会枚举系统启用的无障碍服务,一旦发现 AutoX.js 即触发**自动登出**。本脚本:

| 操作 | 实现 | 是否被 Boss 检测到 |
|---|---|---|
| 截屏 | `adb exec-out screencap`(帧缓冲层) | ❌ 不可见 |
| 文字识别 | macOS Vision Framework(Swift,本地) | ❌ 在 Mac 端,手机无感 |
| 点击/滑动 | `adb shell input tap/swipe`(InputManager 系统注入) | ❌ 与手指事件无差异 |

## 前置条件

- **macOS**(用 Swift + Vision Framework 做 OCR)
- **Android 设备**通过 USB 或 WiFi adb 连接,已安装并登录 Boss 直聘
- `adb` 在 PATH 中(`brew install android-platform-tools` 或 Android Studio)
- `swift` 可用(macOS 自带)

## 配置

编辑 `boss.sh` 顶部:

```bash
# 顶部 chip 关键词(子串匹配)
KEYWORDS=("全栈工" "JavaScript" "Node")

# 设备序列号(adb devices 看)
DEVICE="${DEVICE:-Q4G6NRGYX4IZJ7QG}"

# 岗位标题必须命中下列正则才点击
# 匹配时整段先转小写,所以英文 pattern 全部写小写就是大小写不敏感
# 默认:全栈 / node(含 Node.js / NODE.JS / NodeJS)/ php / javascript / ai(含 AIGC, AIOps)
# AI 用左单词边界,避免误伤 trainee / captain / detail / email
TITLE_REGEX='全栈|node|php|javascript|(^|[^a-z])ai'

# 凑不够 PER_KW 条时最多下拉刷新次数
MAX_REFRESH=5
```

替换 `DEVICE` 为你的设备序列号。
关键词 chip 和岗位标题筛选**互相独立**:chip 决定搜什么类别,`TITLE_REGEX` 在结果里再过一遍标题。

### 自定义筛选示例

只发 Java 后端:
```bash
KEYWORDS=("Java" "后端")
TITLE_REGEX='[Jj]ava(?![Ss]cript)|后端|[Ss]pring'
```

只发 React/Vue 前端:
```bash
KEYWORDS=("前端" "React")
TITLE_REGEX='[Rr]eact|[Vv]ue|前端'
```

## 使用

```bash
# 默认每个关键词发 3 条
./boss.sh

# 每个关键词发 5 条
./boss.sh 5

# 演练(不真发,只 OCR + 打印计划)
DRY_RUN=1 ./boss.sh

# 临时换设备
DEVICE=192.168.50.120:5555 ./boss.sh
```

**运行前**手动打开 Boss 直聘到「职位」tab(主页),脚本会检测是否在主页才继续。

### 输出示例

```
════════ Boss 多关键词:全栈工 JavaScript Node,每个 3 条,DRY_RUN=0 ════════

═══ 关键词: 全栈工 ═══
  ▸ tap 关键词 chip
    ↳ tap '全栈工程师' @ (256,107)
    ⏳ 10s
  ▸ tap 最新(文字命中)
    ↳ tap '最新' (在 '推荐 附近 最新' 中) @ (247,195)
    ⏳ 8s
  ▸ 下拉刷新
    ⏳ 8s
  ─── 第 1 / 3 个岗位 ───
    ↳ tap '10-15K' @ (624,314)
    ⏳ 10s
    ↳ tap '立即沟通' @ (357,1505)
    ⏳ 6s
...
```

## 关键设计

### OCR 抽风兜底(「最新」tab 识别)

OCR 在某些屏幕状态下会把「最新」误识别为 `I 取` / `1 取`。脚本走**双路径**:

1. **主路径**:文字命中 → `tap_word()` 在合并行("附近 最新")里按词位置精确点击
2. **回退**:文字未命中 → 找「附近」(读得稳),点它右侧 50px

### 岗位选择

1. OCR 出所有薪资行(`X-YK`),作为岗位锚点
2. 对每个薪资行,看**同 y 行 ±25px** 内有没有命中 `TITLE_REGEX` 的文字
3. 命中的取最上面那条,点 → 立即沟通 → back
4. 凑不够 `PER_KW` 条时下拉刷新,从头扫一遍
5. 检测到「继续沟通」按钮(已聊过)自动跳过,避免重发

### 反检测细节

- 每步随机等待 5-10s
- 截屏在 Mac 端处理,手机无任何额外进程
- 没有任何应用安装到手机

## 已知限制

- **JavaScript chip 经常不在屏幕**:Boss 的 chip 栏会动态重排,若被滚到右边,脚本会跳过。需要横扫 chip 栏才能找到——目前未实现。
- **OCR 识别误差**:个别岗位卡片若 OCR 读错,可能跳过或点错位置。脚本写了多层兜底,但不是 100% 完美。
- **公司名记录**:`boss_contacted.txt` 是历史记录(早期版本写的),当前脚本**不再记录、不再去重**,纯傻瓜式打招呼。

## 故障排查

| 现象 | 原因 | 解决 |
|---|---|---|
| `✗ 设备 XXX 不在线` | adb 没连上 | `adb devices` 确认序列号 |
| `✗ 不在 Boss 主页` | 没打开 app 或不在职位 tab | 手动打开到职位 tab 再运行 |
| `✗ 顶部找不到 'XXX' chip` | chip 不在屏幕上 | 手动点过该关键词后会进入历史,或换关键词顺序 |
| `⚠ 「附近」和「最新」都没识别到` | OCR 完全抽风 | 重启 Boss app 后重试 |

## 文件

- `boss.sh` — 主脚本,一切都在里面(含内嵌 Swift OCR)
- `boss_contacted.txt` — 已沟通公司历史,脚本自动追加并用于去重(命中已记录公司自动跳过)
  - 格式:`[YYYY-MM-DD HH:MM:SS] | 公司名 | 岗位`
  - `#` 开头的行被忽略,可手动编辑

## 警告

- **使用风险自负**。Boss 直聘 ToS 禁止自动化操作,过度使用可能触发风控、限流、封号。
- 建议**每天 < 30 条**,与人工操作交替使用。
- 此脚本仅供学习参考。
