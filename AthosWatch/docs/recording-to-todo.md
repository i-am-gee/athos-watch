# 录音 → 待办事项：哪些路走不通，哪些能走

这份文档只回答一件事：**在没有 iPhone App 的前提下，手表录到的内容如何变成待办**。

先说结论：**纯手表闭环不成立**，不是实现难度问题，是系统层面禁止。要走通，必须有一个「外部执行者」——服务端，或者一个极小的 iPhone 端程序。

---

## 两条被系统否掉的直觉方案

### 1. 手表自己把语音转成文字 ✗

watchOS SDK 里**没有 Speech.framework**：

```bash
ls $(xcrun --sdk watchos --show-sdk-path)/System/Library/Frameworks | grep Speech
# 无输出
```

写 `import Speech` 直接编译失败：`Unable to resolve module dependency: 'Speech'`。

### 2. 手表自己写进「提醒事项」 ✗

EventKit 框架在，但**所有写操作都被禁**。查头文件：

```bash
grep WATCHOS_PROHIBITED \
  $(xcrun --sdk watchos --show-sdk-path)/System/Library/Frameworks/EventKit.framework/Headers/EKEventStore.h
```

```
saveCalendar:commit:    __WATCHOS_PROHIBITED
removeCalendar:commit:  __WATCHOS_PROHIBITED
saveEvent:span:         __WATCHOS_PROHIBITED
removeEvent:span:       __WATCHOS_PROHIBITED
saveReminder:commit:    __WATCHOS_PROHIBITED
removeReminder:commit:  __WATCHOS_PROHIBITED
commit:                 __WATCHOS_PROHIBITED
```

手表上的 EventKit **只能读**。苹果的设计意图很清楚：手表不直接改日历数据库，交给 iPhone。

所以「靠 iCloud 同步，手表建待办、iPhone 自动出现」这个想法不成立。

---

## 三条可行路径

| | A. 服务端 + 推送 | B. 极简 iPhone 伴侣 App | C. 服务端写第三方待办 |
|---|---|---|---|
| 手表需要做什么 | 联网上传音频 | 传给 iPhone（同网络或 WCSession） | 联网上传音频 |
| 需要写 iOS 代码 | 不需要 | 需要（约 50~100 行，无 UI 也行） | 不需要 |
| 待办最终落在 | 企业微信 / 邮件 / 飞书 | **系统「提醒事项」**，iCloud 全端同步 | 滴答清单 / Todoist 等 |
| 断网时 | 完全不可用（GPS 版离开 iPhone 就断） | 不受影响（本来就靠 iPhone） | 完全不可用 |
| 上手成本 | 一个服务 + 一个机器人 | 一个 Xcode target | 一个服务 + 一个第三方账号 |

### 关键约束：网络

非蜂窝版手表离开 iPhone 就没有网络，上传无从谈起。而「手表离开 iPhone」和「需要上传」往往同时发生（比如去开会）。**方案 B 在这点上最稳**：它依赖的正是「iPhone 就在附近」。

### 推荐组合

- 想快速看到效果、不想写 iOS 代码 → **A**，把待办推到企业微信群或个人微信/邮件，你看到后顺手记一笔
- 想要真正的系统待办、要能勾选完成、要全端同步 → **B**，这是唯一能落进「提醒事项」的路
- 已经在用滴答清单/Todoist → **C**，服务端调它们的开放 API 最省事

---

## 手表端已就绪的部分

`Sources/Audio/Transcriber.swift` 里的 `RemoteTranscriber` 已经把「上传 + 取回结构化待办」封装好了，与后端实现无关：

```swift
RemoteTranscriber.endpoint = URL(string: "http://192.168.1.8:8787/asr")   // 你的服务
let result = try await RemoteTranscriber.transcribe(url: segmentURL)
result.text            // 全文
result.todos           // [(title: "给张伟回电话", due: 明天 15:00)]
```

服务端只要满足这个契约：

**请求**

```
POST /asr
Content-Type: audio/mp4
X-Audio-Name: seg-20261116-193459-258.m4a
<二进制音频，16kHz 单声道 AAC>
```

**响应**

```json
{
  "text": "明天下午三点提醒我给张伟回电话",
  "todos": [
    { "title": "给张伟回电话", "due": "2026-11-17T15:00:00+08:00" }
  ]
}
```

`todos` 可以为空数组（这段录音里没有待办）。`due` 可以为 null（没有明确时间）。

转写可以用任何东西做，手表不关心：云端 ASR（阿里云/讯飞/腾讯）、Whisper API、或者本机跑 whisper.cpp。**不要用系统的 Speech 框架做这个服务端**——它同样有每设备每日配额和 1 分钟上限。

## 还缺的部分

1. 服务端（转写 + 抽取待办）。抽取建议直接给 LLM，规则匹配「提醒我」「之前」「周五」这类中文时间表达准确率不够
2. 上传触发时机：建议「充电 + Wi-Fi 时批量上传」，避免边录边传抢电量与带宽
3. 上传成功后删除本地音频（或保留 N 天），否则手表 64GB 也会被吃满
4. 如果选方案 B，还要把工程从 `WKWatchOnly` 改成有 iPhone 伴侣的结构，并加 `WCSession`

## 一个必须承认的产品事实

做到方案 A，待办最终是**一条聊天消息**，不是可勾选的清单。要变成真正「能打勾」的待办，绕不开方案 B 或 C。

如果目标是「全天候采集 → 自动沉淀可执行的任务」，那 iPhone 端那几十行代码是省不掉的，只是可以做到极简：没有界面，只在后台接收、转写、写入提醒事项。
