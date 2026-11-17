# Athos · Apple Watch 静音门控录音

一个只在「有人说话」时才写盘的手表录音器。核心不是录音，是**用门控把无效音频挡在磁盘和云之外**。

---

## 当前状态（请先读这段）

| 项目 | 状态 |
|---|---|
| 静音门控算法（dBFS、自适应噪声底、迟滞、驻留、过零率过滤） | **已实现，并已在本机用合成信号验证通过** |
| 功耗模型（占空比 → 每小时耗电 → 可用时长） | **已实现，可运行** |
| watchOS 采集、分段写盘、中断处理 | **已编译并运行**（Xcode 27.2 / watchOS 27.2 模拟器） |
| 门控 → 切段 → AAC 写盘 全链路 | **已在模拟器用合成信号端到端验证**，产出可解码的 m4a |
| SwiftUI 界面 | **已编译并运行**，46mm 屏无溢出；一个圆球 + 状态 + 已录总时长 |
| 录音列表与就地试听 | **已实现**，手表上可看时长/大小并播放、左滑删除 |
| 时长格式化 | **已实现并有单元断言**（`make gate` 里 13 组边界用例） |
| 电脑端导出脚本 | **已提供**（`tools/pull-recordings.sh`），未接真机验证 |
| 转写、上传、iCloud 同步、Live Activity | **未实现**，见「下一步」 |

端到端验证的实测结果（`-synthetic` 启动，12 秒合成信号：2s 静音 → 3s 人声 → 4s 静音 → 3s 人声）：

```
gate opened → gate closed → gate opened
seg-…-184315-834.m4a   6.22s   15655 B   （1.5s 预录 + 4.72s 人声）
seg-…-184325-329.m4a   4.22s    6990 B   （1.5s 预录 + 2.72s 人声）
解码回 PCM：peak -21.7 dBFS，与合成信号幅度一致
```

即：文件能生成、能解码、内容对得上，不是「有文件但播不出来」。

---

## 快速开始

需要 **Xcode 16 或更新版本**。想看界面用模拟器就够（`make sim`）；想验证真实拾音和功耗必须真机——模拟器没有麦克风输入。

最省事的一条命令：

```bash
cd AthosWatch
make sim      # 生成工程 → 构建 → 装进模拟器 → 启动 → 截图
```

想知道每个 make 目标干什么：`make help`。想手工操作继续看下面。

### 方式一：XcodeGen（推荐）

```bash
brew install xcodegen
cd AthosWatch
xcodegen generate
open AthosWatch.xcodeproj
```

### 方式二：手动建工程

1. Xcode → New Project → **App** → Platform 选 **Apple Watch** → Interface **SwiftUI** → Language **Swift**。
2. 删掉自动生成的 `ContentView.swift` 和 `<Name>App.swift`。
3. 把本目录 `Sources/` 下所有 `.swift` 拖进工程（勾选 Copy items if needed，Target 选 Watch App）。
4. 用本目录 `Support/Info.plist` 覆盖工程自带的 Info.plist，或在 Target → Info 中手动加入：
   - `NSMicrophoneUsageDescription`
   - `UIBackgroundModes` → `audio`
5. Signing & Capabilities 里选好 Team，Bundle Identifier 改成你自己的。

### 运行

表上打开 Athos，点中央那个圆球开始监听，授权麦克风，然后正常说话即可。

整个界面只有一个可操作的控件，状态全靠颜色表达：

| 样子 | 含义 |
|---|---|
| 灰色圆球、点状细环、字是「待机」 | 没在录 |
| 青色圆球、环上短棒缓慢起伏、字是「在听」 | 麦克风在工作，但没人在说话，**不写盘** |
| 绿色圆球、短棒随音量跳动、字是「记录中」 | 判定有人声，**正在写盘** |

球下面那行数字是**已录总时长**，格式 `分:秒`，满一小时变 `时:分:秒`。它的口径和「录音」列表头那行完全一样——盘上所有分段之和，加上正在录、还没落盘的那一段。所以录的时候它会一秒一秒往上走，停止后停住，重开 App 也还是那个数。

颜色跟着状态走：记录中是绿色（在涨），在听是青色（不动），待机是灰色（更暗）。

录音时中心按钮外那圈细弧会一点点走满（每 120 秒走一圈，走满就换下一个文件），这是本段的进度，和下面那行总时长是两个不同的量。

停止后音频在 App 沙盒 `Documents/Segments/` 下，每段一个 `.m4a` 加一个同名 `.json` 元数据。

---

## 设备要求

**Athos 是纯手表 App（`WKWatchOnly = true`），没有 iOS 端，装不到 iPhone 上。** iPhone 只在安装时当中转站。

| 角色 | 要求 | 说明 |
|---|---|---|
| Apple Watch | **watchOS 10 或更新** | Series 4 及以后都能装（工程最低部署目标 10.0） |
| iPhone | 必须能**配对**那块手表 | 见下面这条坑，这是最容易卡住的地方 |
| Mac | macOS 26+ | Xcode 27 的系统要求 |

### 旧 iPhone 的坑（含 iPhone XS / XR）

iPhone XS、XS Max、XR 的最后一个系统是 **iOS 18.7.x**，苹果已停止支持，升不到 iOS 26。而 **watchOS 26 起要求 iPhone 11 或更新 + iOS 26** 才能配对。所以：

- 手表停在 **watchOS 10 / 11** → iPhone XS 能配对，Athos 能装能用（工程支持 watchOS 10+）
- 手表已经是 **watchOS 26 / 27** → iPhone XS **配不上那块表**，装不了 App；这不是 Athos 的限制，是系统要求

自查：手表 → 设置 → 通用 → 关于 → 看「版本」。高于 11 就是升不上去了，得换 iPhone 11 及以后的机型。

> 不要为了装 App 去升级手表系统。watchOS 一旦升到 26，就再也回不到能和旧 iPhone 配对的版本（Apple 不允许手表系统降级）。

## 安装到真机（Apple Watch）

先跑一次体检，它会告诉你现在缺什么，不用一条条对照：

```bash
make doctor
```

```
[1] Xcode            ✓ Xcode 27.2
[2] watchOS SDK      ✓ watchOS 27.2      ✓ 模拟器运行时
[3] 工程与工具链      ✓ xcodegen        ✓ Sources 下所有 .swift 都已在工程里
[4] 签名             ✓ 1 个可用的开发证书  ✓ Team ID: UAXGUNTFU8
                     ! 这是免费 Personal Team：证书 7 天过期
[5] 设备             ! 没有已连接的 Apple Watch   ✓ 模拟器已启动
结论：签名就绪，但没检测到手表。可以先 make sim 看界面。
```

结论只有三种，对应的下一步很明确：

| 结论 | 下一步 |
|---|---|
| 可以装到真机 | `⌘R`，或 `./redeploy.sh <手表UDID>` |
| 签名就绪但没检测到手表 | 接上手表重跑体检，或先 `make sim` |
| 只能跑模拟器 | 按下面第 1~3 步补签名 |

### 0. 装 Xcode

只能从 App Store 装（约 15 GB 下载，装完占 40 GB 以上）。装完必须把命令行工具指向它，否则 `xcodebuild` 依然报 “requires Xcode”：

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -runFirstLaunch
xcodebuild -version    # 能打印版本号才算成功
```

### 1. 让 Xcode 认识你的 Apple ID

Xcode → **Settings → Accounts** → `+` → Apple ID → 登录（需要双重认证）。登录后账号会显示为 **Personal Team**——这就是免费签名能力。

免费账号的限制（官方口径，必须知道）：

| 项目 | 免费账号 |
|---|---|
| 证书有效期 | **7 天**，到期 App 打不开，需重新构建安装 |
| 可注册 App ID | 10 个 |
| 可注册设备 | 3 台 |
| 每台设备可装 App | 3 个 |
| TestFlight / 上架 | 不支持，需 $99/年 |

要长期戴着测功耗，建议先忍耐重装两次再决定是否付费。

### 2. 两台设备都开「开发者模式」

缺这一步会卡在 “Unable to install”。

- **iPhone**：设置 → 隐私与安全性 → 开发者模式 → 打开 → 重启 → 上滑点「启用」→ 输密码
- **Apple Watch**：设置 → 隐私与安全性 → 滚动到底 → 开发者模式 → 打开 → 重启 → 点「开启」→ 再点「信任」→ 输手表密码

手表的开发者模式**只能在手表上开**，iPhone 的 Watch App 里没有这个开关。

### 3. 配签名

```bash
cd AthosWatch
brew install xcodegen
xcodegen generate
open AthosWatch.xcodeproj
```

在 Xcode 里选中工程 → Target `AthosWatch` → **Signing & Capabilities**：

- 勾选 **Automatically manage signing**
- Team 选你的 **Personal Team**
- Bundle Identifier 改成全局唯一，例如 `com.你的名字.athos`（必须改，`com.athos.watch` 已经被占用时会报 “bundle identifier is not available”）

### 4. 部署

1. 用数据线接 iPhone，手表戴在手上并**解锁**，最好**放在充电器上**，两台设备连同一个 Wi-Fi。
2. Xcode 顶部 scheme 选 `AthosWatch`，运行目标下拉里选你的 **Apple Watch**（不是模拟器）。
3. 按 **⌘R**。首次会显示 “Preparing watch for development…”，**等几分钟不要中断**，期间两台设备都要保持解锁。
4. 首次启动若提示「未受信任的开发者」：手表上 设置 → 通用 → VPN 与设备管理 → 点你的 Apple ID → 信任。

### 5. 每周重装

7 天后 App 图标点不开。两种方式：

- Xcode 里重新 **⌘R**
- 或跑脚本（先 `chmod +x redeploy.sh`）：

```bash
xcrun devicectl list devices        # 找到手表的 UDID
./redeploy.sh <手表UDID>
```

> ⚠️ 重装前先把 `Documents/Segments/` 里的录音导出——重签重装有可能清空 App 沙盒。

签名与 Bundle ID 已经写好在 `project.yml` 里（Team `UAXGUNTFU8`、`com.kakaqiang.athos`），换电脑或换账号时改这两行即可，不必在 Xcode 图形界面里再改一遍——**图形界面里改的签名会被下一次 `xcodegen generate` 冲掉**。

### 装不上时的排查顺序

| 现象 | 原因 | 处理 |
|---|---|---|
| `xcodebuild: requires Xcode` | 命令行工具仍指向 CLT | 执行第 0 步的 `xcode-select` |
| 运行目标列表里没有手表 | 表未解锁 / 不在充电 / 未连同一 Wi-Fi | 解锁、放充电器、等 “Preparing…” 结束 |
| `Unable to install` | 开发者模式没开 | 两台设备都按第 2 步重做一遍 |
| `bundle identifier is not available` | Bundle ID 与别人重复 | 改成含你名字的唯一 ID |
| `Untrusted Developer` | 证书未信任 | 手表上 VPN 与设备管理里信任 |
| 编译报错（AVAudioFile / SwiftUI 相关） | 首次编译的 API 差异 | 把报错贴出来，逐条改 |
| `0 valid identities found` 但证书确实存在 | 缺 WWDR **G3** 中间证书，证书链断裂 | 见下方说明 |

#### 证书存在却被判为「无效身份」

症状：`security find-identity -p codesigning` 能列出证书，但 `-v`（仅有效）返回 0，`security verify-cert` 报 `CSSMERR_TP_NOT_TRUSTED`。

原因：Xcode 27 签发的开发证书由 **Apple Worldwide Developer Relations **G3**** 中间证书签发，而 macOS 系统钥匙串里通常只有更老的 G1，链在此断开。

修复（不需要联网，Xcode 自带这份证书）：

```bash
G3="/Applications/Xcode.app/Contents/SharedFrameworks/DVTFoundation.framework/Versions/A/Resources/AppleWWDRCA-2030.cer"
security import "$G3" -k ~/Library/Keychains/login.keychain-db
security find-identity -v -p codesigning    # 应出现 1 valid identities found
```

> 注意：`AppleWWDRCAG6.cer` 是 G6，`AppleWWDRCA-2030.cer` 才是 G3。两者同名不同版，别导错。

#### 查 Team ID

如果脚本自动识别失败，可以在 Xcode 偏好里直接读：

```bash
defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier
```

输出里的 `teamID` 就是需要的 10 位值。

---

## 怎么录（日常操作）

手表上打开 Athos，点**中央那个圆球**开始监听，除此之外没有别的开关。系统不允许任何 App 自行开始采集，这一步只能手动（后续可用快捷指令自动化绕开）。

屏幕上的三种状态（灰=待机、青=在听、绿=记录中）见上面「运行」一节的表。其中「在听」是最常态：麦克风在工作，但没人说话，一个字节都不写。

- 说话后 **0.3 秒**开始写，静音后 **2 秒**收尾；句子之间的短暂停顿不会把一段话切碎
- 息屏、切到表盘、放下手腕都可以继续录（`UIBackgroundModes: audio`），表盘顶部会有系统录音红点——这是给被录音者看的，不要关掉
- 来电或别的 App 抢麦克风会硬中断，App 会保留中断前的内容并提示，不会假装还在录
- 表盘常亮（AOD）时环上的动画会自动停下，只留静态图形，省电；数字照常显示，因为它是静态的

一小时大约产生 8–9 MB 音频（16 kHz 单声道 AAC）。电量开销取决于你说了多少话，见「真机功耗实测协议」。

> 主屏只保留了一个数字：录音总时长。电平、占空比、段数这些只在开发期有用，对「我现在在不在录」毫无帮助，却会占掉 46mm 屏一半面积，所以都留给别的界面了。要看这些数字：跑 `make run`（合成信号，会把每帧电平和门限写进 `athos-trace.log`），或者在电脑上 `make export` 拿到 `index.csv`。

---

## 怎么看录到的内容

两条路，按场景选。

### 1. 手表上直接看（推荐，抬手就能用）

首页底部点「**录音**」进入列表：

```
12 段 · 1′3″ · 133 KB          ← 合计（段数 / 总时长 / 占用）
最近 12 段
▶ 11-16 19:32:11
  4.2s · 7 KB                  ← 点一下就地试听（手表扬声器或已连的蓝牙耳机）
▶ 11-16 19:32:03
  2.7s · 4 KB
```

- 点某一段即播放，再点一次停止，播完自动停
- 段落**左滑**可删除（音频与 sidecar 一起删，不会留下孤儿文件）
- 最多列最近 60 段，更早的用电脑导出

### 2. 电脑上导出（要批量处理、听全量时用）

```bash
cd AthosWatch
chmod +x tools/pull-recordings.sh

./tools/pull-recordings.sh ./export          # 自动：有真机走真机，没有就走已启动的模拟器
./tools/pull-recordings.sh ./export --sim    # 强制走模拟器
```

脚本做的事：

1. 找设备（真机优先，`devicectl list devices` 里的模拟器会被排除）
2. 把 `Documents/Segments` 整个拷到 `./export`
3. 生成 `index.csv`：文件名、开始时间、时长（秒）、字节，供后续转写/统计直接读

```
→ 目标设备：模拟器 6D308C7E-…
✓ 8 段 · 共 37.5 秒 · 110 KB
  清单：./export/index.csv
  最早：2026-11-16 19:36:18  最新：2026-11-16 19:36:31
```

```bash
afplay export/*.m4a                                            # 挨个听
for f in export/*.m4a; do afinfo "$f" | grep duration; done     # 只看时长
open export/index.csv                                          # 清单
```

真机路径**未在本机验证过**（手上没有真机）：`devicectl device copy from --domain-type appDataContainer --domain-identifier com.kakaqiang.athos --source Documents/Segments`。第一次跑如果报 `Transfer Files is not supported`，说明连的是模拟器；如果报超时，多半是手表锁屏或没在充电。

连不上手表时的兜底：**Xcode → Window → Devices and Simulators → 选中手表 → 选中 Athos → 齿轮菜单 → Download Container…**，得到的 `.xcappdata` 右键「显示包内容」，进 `AppData/Documents/Segments`。

> sidecar 里存的是**文件名**而不是绝对路径。这条改动是被重装逼出来的：早期版本存绝对路径，App 一重装容器 UUID 就变，列表显示「12 段」却一段都打不开。旧格式的 sidecar 仍可读（自动降级取文件名）。

#### 导出目录里出现「未完成」的分段，是什么

MP4 的 `moov`（索引）只在文件**关闭**时才写。App 被系统杀掉、手表没电、或你拔线重装时正在写的那一段，会留下一个几十 KB 但打不开的文件——`afinfo` 报 `AudioFileOpenURL failed`。

处理方式：

- 手表上「录音」页会把这类段**置顶**，橙色警告图标 + `未完成 · 28 KB · 左滑删除`
- 电脑上 `index.csv` 里对应行的 `duration_s` 为 `0`，可以直接过滤

这是物理限制，不是 bug；能做的是把损失压小：单段上限已从 300 秒降到 **120 秒**，也就是强杀最多丢 2 分钟。

### 3. 还没做的：转写与待办

现在音频只是落盘，**没有转写、没有上传、没有文字**。

想走「录音 → 待办」这条路，先读 [docs/recording-to-todo.md](docs/recording-to-todo.md)。核心结论：watchOS **既没有 Speech 框架**（不能自己转文字），**EventKit 写操作也全部被禁**（不能自己建提醒事项），所以纯手表闭环不成立，必须有服务端或一个极简 iPhone 端参与。文档里给了三条可行路径对比和已经定好的服务端契约。

---

## 目录结构

```
AthosWatch/
├── project.yml                      XcodeGen 工程定义
├── Support/Info.plist               麦克风权限与后台音频声明
├── Sources/
│   ├── App/
│   │   ├── AthosWatchApp.swift      入口
│   │   └── RootView.swift           主界面：一个圆球 + 三字状态 + 总时长
│   ├── Audio/
│   │   ├── SonicGate.swift          ★ 门控状态机（纯逻辑，可单测）
│   │   ├── PowerLedger.swift        ★ 功耗账本（纯逻辑，可单测）
│   │   ├── ClockText.swift          ★ 时长格式化（纯函数，可单测）
│   │   ├── AudioCaptureEngine.swift 采集、转换、预录、写盘调度
│   │   ├── SegmentWriter.swift      AAC 分段写盘（0.5s 攒批 + 关闭时压缩）
│   │   ├── MP4Compactor.swift       摘掉 AVAudioFile 预留的 23KB free 原子
│   │   └── SegmentStore.swift       读取 sidecar、试听、删除
│   ├── Session/
│   │   └── RecordingController.swift 权限、中断、状态广播
│   └── UI/
│       ├── SonicOrbView.swift       主视觉：环形声波 + 光晕 + 分段进度弧
│       └── SegmentsView.swift       录音列表 + 就地试听
├── Tests/
│   └── main.swift                   门控、功耗模型、时长格式的命令行验证
├── tools/
│   ├── doctor.sh                    环境体检（能不能装真机、卡在哪步）
│   ├── pull-recordings.sh           把真机上的录音导到本机
│   ├── run-synthetic.sh             模拟器上跑全链路（合成信号）
│   ├── preview.sh                   模拟器一键预览
│   ├── set-team.sh                  写入 Team ID
│   └── setup-xcode.sh               装完 Xcode 的收尾配置
├── Makefile                         常用命令入口（make help 看全部）
└── docs/                            界面截图
```

## Swift 文件怎么用

`.swift` 是**源码**，不是可执行文件，双击打不开。要有宿主才能跑，这个项目有两条有用的路：

### 方式一：做成手表 App（绝大多数文件属于这条）

```bash
cd AthosWatch
make sim          # 生成工程 → 构建 → 装进模拟器 → 启动 → 截图
```

或者手动：

```bash
xcodegen generate            # 由 project.yml 生成 .xcodeproj
open AthosWatch.xcodeproj    # 在 Xcode 里按 ⌘R
```

⚠️ **新增或删除 `.swift` 文件后必须重新 `xcodegen generate`**。工程文件里的源文件列表是生成出来的产物，不重新生成的话，新文件只是躺在目录里，编译时根本不会被包含——表现是"我明明写了这个类，怎么报找不到"。

装到真机走 `⌘R`，或 `make device` 只验编译（不安装），再或 `./redeploy.sh <手表UDID>` 一键重装。

### 方式二：编译成命令行工具（只有纯逻辑文件可以）

`SonicGate.swift` 和 `PowerLedger.swift` 刻意不 import AVFoundation，就是为了能脱离 Xcode 单独跑：

```bash
make gate
```

等价于：

```bash
swiftc -O Sources/Audio/SonicGate.swift \
          Sources/Audio/PowerLedger.swift \
          Tests/main.swift -o build-tools/gatecheck
./build-tools/gatecheck
```

改阈值不用改代码，用环境变量：

```bash
GATE_OPEN=8 GATE_TAIL=1.0 make gate     # 开场 +8dB，收场驻留 1.0 秒
```

输出会直接告诉你每次开关门的时刻：

```
阈值配置：开场 +8 dB / 收场 -6 dB / 开场驻留 0.30s / 收场驻留 1.0s
2.28s  OPEN   电平 -27.7 / 底 -73.0 / 门限 -55.0
6.00s  CLOSE  电平 -72.5 / 底 -73.0 / 门限 -63.0
```

（注意这个例子：把开场阈值调到 +8 dB 后开门时刻没变，因为 `absoluteGateDBFS = -55` 才是实际瓶颈。这类结论只能靠跑出来，靠推理容易想当然。）

**不能**这样跑的文件：`AudioCaptureEngine.swift`、`SegmentWriter.swift`、`SegmentStore.swift` 依赖 AVFoundation，`RootView.swift` 依赖 SwiftUI，`AthosWatchApp.swift` 是 `@main` 入口——它们必须在 App 环境里运行。

也别指望 `swift Sources/Audio/SonicGate.swift` 能出东西：那只是把文件当脚本执行，没有 `main`，什么也不打印。

### 方式三：在 Xcode 里交互调试（验算用）

想看每一步的中间值（每帧电平、噪声底、过零率），新建一个 Playground，把 `SonicGate.swift`、`PowerLedger.swift` 拖进它的 `Sources/` 目录，就能在右侧边栏逐行看到结果。这条路径没有在本机验证过（Playground 依赖 Xcode 图形界面），只作为备选。

### 速查

| 我想做 | 命令 |
|---|---|
| 看现在缺什么才能装真机 | `make doctor` |
| 改完算法快速验算 | `make gate` |
| 调阈值看效果 | `GATE_OPEN=8 make gate` |
| 看界面 | `make sim` |
| 验证门控+写盘整条链路 | `make run` |
| 把录音拿到电脑 | `make export` |
| 确认真机能编过 | `make device` |
| 新增文件后 | `make gen` |
| 全部清掉 | `make clean` |

### 在模拟器上跑「门控 → 切段 → 写盘」全链路

模拟器没有麦克风输入，但可以灌合成信号，把除真实采集外的整条链路跑通：

```bash
xcrun simctl launch <DEVICE_UDID> com.kakaqiang.athos -synthetic
# 12 秒后读取：
C=$(xcrun simctl get_app_container <DEVICE_UDID> com.kakaqiang.athos data)
ls -l "$C/Documents/Segments"        # 两个 .m4a + 两个 .json
cat "$C/Documents/athos-trace.log"   # 每次开关门的读数
```

`synthetic` 通路**故意不启动音频引擎**——模拟器的 tap 会持续吐全零缓冲，-140 dBFS 被判定为静音，会把门控的 `aboveSeconds` 每 20ms 清零一次，导致合成语音永远攒不满 0.3s 驻留。这个坑踩过一次，注释留在代码里。

---

## 端到端跑通时抓到的四个真实缺陷

这四个都不是「写错语法」，只有真的跑起来才会暴露：

**1. 录音态漏写盘（致命）**
`process` 里 `.level` 分支原本是 `break`，意味着只有「开门那一帧」被写盘，之后每帧都丢。
文件确实存在、`afinfo` 也能读出时长，但内容只有 20ms。表面全绿，实际全是垃圾。
修复：`.level` 且 `gate.state == .recording` 时照常入队，并加了分段时长断言。

**2. AAC 小批写导致码率翻三倍**
每 20ms 调一次 `AVAudioFile.write`，每个包都带固定开销，配置 24 kbps 实际写出 60–80 kbps。
修复：`SegmentWriter` 内部攒满 0.5 秒再交给编码器，实测回落到 ~20 kbps。

**3. 每个文件白占 23.4 KB（隐蔽）**
`AVAudioFile` 会在 moov 后预留一个 `free` 原子，用于采样表后续增长。
一段 4.7 秒的录音：音频 10 KB，文件 35 KB。短句场景下这层开销能占到存储的 60%–80%。
修复：`MP4Compactor` 在关闭文件时摘掉 `free` 并把 `stco/co64` 偏移整体左移，同时校验解析、任一处越界就放弃压缩。

| 指标 | 修复前 | 修复后 |
|---|---|---|
| 4.72s 分段文件体积 | 35 130 B（59.5 kbps） | 11 751 B（19.9 kbps） |
| 2.72s 分段文件体积 | 27 076 B（79.6 kbps） | 3 551 B（10.4 kbps） |
| 每小时存储（假设 5s/段） | ~30 MB | ~9 MB |
| 解码校验 | 通过 | 通过（帧数一致） |

压缩逻辑可以脱离 Xcode 单独验证：`swiftc -O Sources/Audio/MP4Compactor.swift <你的测试>.swift`，用 `AVAudioFile` 前后各读一次，帧数必须相同。

**4. 根视图拿不到高度提议，Spacer 一点都分不到**

把 `ZStack` 直接放在 `body` 根上时，watchOS 给它的是「未指定」高度提议，于是 ZStack 缩成内容高度、整体被根视图居中。后果是里面所有 `Spacer` 展开为 0：底部「录音」入口永远紧贴上一行，永远到不了底边。

这个 bug 上一版就在，但被误判成「屏幕太挤」。当时的处理是把状态环从 78pt 一路缩到 64pt、电平条 22→18，靠压字号硬塞进 242pt——看起来「解决了」，其实根因没动。加时长时间距一变，它立刻原形毕露：数字和「录音」入口叠在一起。

修复：用 `GeometryReader` 拿真实尺寸，再显式 `.frame(width:height:)` 下发给 VStack。实测「录音」入口从 y≈187pt 落到底边 ≈232pt，主体组在剩余空间里自然居中。

教训是：**watchOS 上不要假设根视图会给你全屏提议**。凡是依赖 `Spacer` 分空间的布局，先用 `GeometryReader` 把尺寸钉死。

---

## 门控怎么工作

```
每 20ms 一帧 → 算 RMS 得 dBFS + 算过零率
              ↓
     噪声底跟踪（仅静音态，上行极慢、下行快，疑似语音帧不参与）
              ↓
   开门条件：电平 ≥ max(底噪+12dB, -55dBFS) 且 过零率落在语音区间
              ↓ 连续满足 0.30s
         状态 = recording → 回吐 1.5s 预录 → 开始写盘
              ↓ 电平 < 底噪+6dB 连续 2.0s
         状态 = idle → 关闭文件
```

四个防误触设计，缺一个就会在真实环境里翻车：

1. **相对阈值而非绝对阈值**。手表麦克风没有标定过的声压参考，不同佩戴方式下 -40 dBFS 可能是一个人的正常说话，也可能是空调声。用「噪声底 + 偏移」才稳定。
2. **迟滞**。开门 12dB、关门 6dB。如果两个阈值相同，说话人音量轻微下降就会反复开关，产生大量碎片文件。
3. **驻留时间**。0.3 秒开门驻留滤掉关门声和咳嗽；2 秒收场驻留避免把一句话从中间切断。这两个参数直接决定碎片率。
4. **过零率过滤**。宽带瞬态（关门、餐具、桌面敲击）的过零率显著高于语音，不做 FFT 就能挡掉大部分。代价是会漏掉纯摩擦音，但驻留时间内相邻元音会把状态维持住。

---

## 一个必须知道的结论：VAD 省的不是电

我用功耗模型算了不同占空比下的结果：

| 占空比 | 估算耗电 | 满电可用 | 比连续录音省 |
|---|---|---|---|
| 100% | 5.10 %/h | 19.6 h | — |
| 50% | 4.30 %/h | 23.3 h | 16% |
| 25% | 3.90 %/h | 25.6 h | 24% |
| 15% | 3.74 %/h | 26.7 h | 27% |

**省电幅度只有 16–28%，不是一半。** 原因是音频引擎必须常开才能感知声音，这部分固定开销约 1.1 %/h，门控关不掉它。VAD 关掉的是编码、写盘和后续处理。

那它真正省在哪里：

- **云端转写费省 80%+**。4 小时音频压到 40 分钟，按 ¥1.2/小时算，单用户每月从 ¥144 降到 ¥29。这是订阅制能不能成立的关键。
- **存储与流量省 80%**。每天 110 MB 变成 22 MB。
- **蒸馏质量提升**。喂给模型的都是有人声的片段，而不是大段静音和空调噪声，同一条 prompt 的输出质量明显不同。

所以这个 App 的价值主张应该写成「**让每一分钟的采集都值得被理解**」，而不是「省电」。省电是副产品。

> 表中系数（基线 2.4、引擎 1.1、写盘增量 1.6 %/h）是工程估算，必须用下面的协议在真机上校准。校准前不要对外引用这些数字。

---

## 真机功耗实测协议

跑完这四步，你会得到一组只属于你这台表、这个佩戴习惯的真实系数。

1. **基线**：满电 → 关闭常亮显示 → 飞行模式 → 静置 2 小时 → 记录耗电百分比 B（%/h）。
2. **空载引擎**：启动监听，但在安静房间待 2 小时（门控几乎不写盘）→ 记录 E（%/h）。`引擎开销 = E − B`。
3. **满占空比**：启动监听，连续播放有声书 2 小时（门控几乎全程写盘）→ 记录 F（%/h）。`写盘增量 = F − E`。
4. **真实场景**：正常上班戴一天，记录当日占空比 D 与总耗电 → 与模型预测比对，误差超过 30% 就回头调系数。

把三个数填回 `PowerLedger.swift` 里 `PowerModel` 的三个 `PctPerHour` 字段。这一步不做，`make gate` 算出来的时长就只是装饰。

---

## 阈值调参起点

界面上没有阈值入口了（屏幕留给状态表达），改参数走启动参数：

```bash
xcrun simctl launch <UDID> com.kakaqiang.athos -synthetic -sensitivity 8 -closeDwell 1.5
```

| 参数 | 默认 | 含义 |
|---|---|---|
| `-sensitivity <dB>` | 12 | 开场阈值 = 噪声底 + 该值。调小更灵敏，但更容易把噪声当人声 |
| `-closeDwell <秒>` | 2.0 | 静音多久收场。句子间停顿短于该值不会切段 |

取值会被夹在合理区间内（`-sensitivity` 3–40，`-closeDwell` 0.5–10）。带这两个参数启动时，`athos-trace.log` 里会写一行 `launch overrides: ...` 记下实际生效值——参数写错或没被解析，看这一行就知道。

| 场景 | 建议偏移 | 说明 |
|---|---|---|
| 安静办公室 / 家中 | 10–12 dB | 默认值，灵敏度与误触发平衡点 |
| 会议室（多人、空调） | 15–18 dB | 环境底噪高且波动大，需要更高门槛 |
| 街道 / 咖啡厅 | 20–24 dB | 底噪本身接近人声能量，只能牺牲灵敏度 |
| 车内 / 地铁 | 不建议 | 低频噪声过强，相对阈值失效，应改用绝对门限 + 高通滤波 |

两个容易踩的点：

- **绝对门限会盖过偏移**。开场阈值取 `max(噪声底 + 偏移, -55 dBFS)`。房间极安静时噪声底可能到 -73，此时 `-73 + 6 = -67` 依然低于 -55，改偏移根本不生效——天花板是那个绝对门限。合成信号测试里就是这个情况（实测 `floor=-73.1 open=-55.0`，`-sensitivity 6` 前后 `open` 都是 -55.0）。要动这种场景，得改 `SonicGateConfig.absoluteGateDBFS`。
- **`-closeDwell` 的效果是可观测的**。同一段 3 秒人声 + 后续静音，`-closeDwell 0.8` 让分段时长从 6.22s 掉到 5.02s，差值 1.20s 正好等于驻留差值。用这个指标判断参数有没有真的传进去，比看阈值可靠。

---

## 已知限制

- **不能自行开始监听**。iOS/watchOS 都不允许 App 在后台自动启动录音，必须由人点击。后续可用快捷指令自动化（接电源 / 连耳机时启动）绕开这一步。
- **来电会硬中断**。通话抢占麦克风，任何录音 App 都一样。当前实现会保留中断前内容并提示，不会假装还在录。
- **后台保活未验证**。`UIBackgroundModes: audio` 在 watchOS 上的实际行为需要在真机上验证（参照 Just Press Record 等同行的表现）。若息屏后引擎被挂起，需要叠加 workout session 或 `WKExtendedRuntimeSession` 保活，这部分我留了接口但没写实现。
- **模拟器无声**。Xcode 预览里门控不会因为真实说话而动，要看链路请用 `-synthetic`（合成信号），要看真实电平必须真机。
- **无转写**。音频只是落盘，转写与蒸馏是下一层的事。

---

## 下一步（按优先级）

1. **真机跑通 + 功耗校准**（P0，一切结论的前置条件）
2. **转写接入**：优先用系统端侧转写，实在不行走云端批量
3. **分段元数据的可用性**：给每段自动打上「时长 / 平均电平 / 峰值 / 占空比」，方便后续筛掉垃圾段
4. **Live Activity / 表盘复杂功能**：把「监听中」变成抬腕可见的状态，这同时是审核与伦理的要求
5. **快捷指令自动化**：接电源自动开始，解决「必须手动点」的问题
6. **上传与去重**：WiFi + 充电时批量上传，成功后删本地

## 合规提醒

戴上这个表去录别人的对话，在中国大陆属于处理他人敏感个人信息（《个人信息保护法》第 28 条），需要单独、明确的告知同意。产品层面至少要做到：采集状态可见、可一键停止、不提供音频导出分享、不宣传取证用途。这些不是可选项，是能不能上架的前提。
