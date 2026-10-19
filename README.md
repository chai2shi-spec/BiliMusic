# BiliMusic

> 一款基于 **HarmonyOS** 的 B 站第三方音乐播放器，默认以**匿名 + buvid** 身份访问 B 站音频资源，可选扫码 / 短信验证码登录解锁更高音质与云端能力，数据全部保存在设备本地。
>
> A third-party Bilibili music player built natively for HarmonyOS — anonymous access by default, optional QR-code / SMS login for higher audio quality and cloud features, all data stored locally on device.

![Platform](https://img.shields.io/badge/platform-HarmonyOS%20NEXT%207-blue)

![API](https://img.shields.io/badge/API-26-blue)

![Language](https://img.shields.io/badge/language-ArkTS%20%2F%20ArkUI-orange)

![Version](https://img.shields.io/badge/version-1.1.4-green)

---

## 简介

BiliMusic 把 B 站上的音频内容（单曲、合集、音乐中心榜单、UP 主投稿、收藏夹）整理成一个纯粹的「听歌」应用。  
它**默认无需登录**，用匿名身份 + buvid 拉取音源；也可以在设置页**扫码或短信验证码登录** B 站账号
（凭据仅存本机），解锁大会员杜比 / Hi-Res 音质档，并开启**收藏夹同步、观看历史、我的关注**等云端能力。  
歌单、下载、播放记录始终只留在你自己的手机里。

- **作者**：chai
- **转译自**：[github.com/HanversionOvO/BiliMusic](https://github.com/HanversionOvO/BiliMusic)
- **运行环境**：HarmonyOS NEXT 7（API 26）手机端，适配折叠屏展开态

---

## 功能特性

### 🔍 搜索与发现

- 四个入口：**搜索 / 推荐 / 排行榜 / 音乐中心**
- 搜索支持**「视频 / UP 主」切换**：搜 UP 命中 `bili_user`，显示头像 / 昵称 / **认证徽章** / 粉丝数，用于区分官方号与同名搬运号
- 搜索覆盖**单曲、合集、视频、UP 主**等多种结果类型
- 音乐中心支持真分页（`web/rank` / `comprehensive`），新歌榜自动补齐首屏
- 首页推荐流支持「换一批」（`freshIdx` 刷新）

### 👤 账号（可选登录）

- **扫码登录**：B 站官方 passport 二维码流程，过期自动刷新
- **短信验证码登录**：手机号 + 极验滑块 + 短信验证码三步流程
- 登录凭据（SESSDATA 等）**只保存在本机**，不上传任何第三方服务器
- 登录后 playurl 自动带登录态，**大会员可解锁杜比 / Hi-Res 音质档**
- 登录后额外能力：
  - **收藏夹同步**：B 站收藏夹 ⇄ 本地歌单**真双向镜像**（本地删曲 → 自动取消收藏，收藏夹变动 → 本地歌单跟随）
  - **观看历史与稍后再看**：拉取站内真实观看历史，条目一键播放，多 P 自动定位到上次看过的分 P
  - **我的关注**：已关注 UP 列表，直达 UP 主页
- 不登录可正常使用全部匿名功能，随时可退出登录并清除凭据

### 🎙️ UP 主生态

- **UP 主主页**：头像 / 昵称 / 粉丝数 / 签名 + 投稿列表（30 条/页，滚动自动翻页）
- **投稿订阅**：订阅后新投稿**自动进本地订阅歌单**，按发布时间排序、超限丢最旧
- 闭环体验：**搜 UP → 进主页 → 订阅 → 新歌自动进歌单**
- 曲目「⋯」菜单支持「进入 UP 主主页」

### 📃 歌单与媒体库

- 收藏单曲、把**合集一键保存为歌单**
- 本地媒体库：自建歌单、增删曲目、**删除墓碑**（软删除，可追溯）
- **最近播放**记录
- **歌单导入 / 导出**：剪贴板 JSON 方案，导出自动剥除本机路径，导入侧 id 去重、重名加后缀、畸形条目跳过

### ⬇️ 下载管理

- **音质选择**：64K / 132K / 192K / 杜比 / Hi-Res，按投稿实际档位优雅降级
- **串行下载队列**（每首间隔 350ms 防限流）+ 实时速度显示
- **断点续传**：基于 HTTP `Range` 续传，暂停后带 `ignoreWifiLimit` 重试
- **整单下载**：歌单「⋮」菜单一键批量入队，下载页按**歌单卡片归组**
- **失败重试**：失败行「↻」按钮 / 整行点击 / 多选「重试选中」三层入口
- **仅 Wi-Fi 下载**开关，非 Wi-Fi 环境提示用户后放行
- **批量操作**：全部暂停 / 全部开始、**多选删除**
- **后台下载保活**：`DATA_TRANSFER` 长时任务，退后台 / 锁屏后队列继续跑

### ▶️ 播放

- **沉浸取色背景** + 封面 **Swiper 双页**（封面 / Canvas 时间轴歌词）
- **歌词服务**：B 站标题清洗 → 候选评分 → LRC 解析 → 缓存 → 手动纠错（数据源：OIAPI QQ Music Lyric）
- 唱片**旋转动画**（线性无限循环）与缓慢不规则**呼吸效果**
- **播放队列**弹层、循环模式：**顺序 / 单曲 / 列表循环 / 随机**
- **后台播放**（`KEEP_BACKGROUND_RUNNING` 长时任务保活）
- **蓝牙断开自动暂停**（音频路由监听 + toast 提示）
- **分 P 视频**自动展开为多首曲目
- 播放页功能键：播放模式 / 下载 / 加入歌单

### 🎨 界面

- 底栏采用 HDS（HarmonyOS Design System）`HdsTabs` **沉浸光感悬浮胶囊**：  
  系统材质 + 主题色光晕，播放栏与页签**融合于同一胶囊**（miniBar 槽位，展开 / 收起两态）
- **主题色 8 色切换** + 深浅模式跟随，全站组件即时变色
- 全站顶栏统一**毛玻璃材质**（`backgroundEffect` 真高斯模糊，静止淡显、滚动增强）
- 适配**折叠屏展开 / 平板**（≥600vp 强制迷你栏展开态，断点响应式布局）
- 设计了规范化的色彩 / 字阶 / 触达 / 动效体系（见 `design/`）

---

## 技术栈

| 维度      | 选型                                                      |
| ------- | ------------------------------------------------------- |
| 系统      | HarmonyOS NEXT 7（API 26）                                |
| 语言 / 框架 | ArkTS + ArkUI（声明式）                                      |
| 设计系统    | `@kit.UIDesignKit`（HDS）沉浸材质底栏                           |
| 构建      | Hvigor                                                  |
| 状态管理    | `@StorageLink` / `@State` 等 ArkUI 状态装饰器 + AppStorage 版本号广播 |
| 持久化     | `@ohos.data.preferences`（歌单分片存储）+ `@ohos.data.relationalStore`（RDB 下载记录，幂等列迁移） |
| 后台任务    | `audioPlayback` / `dataTransfer` 长时任务（互斥切换）              |
| 权限      | `INTERNET`、`GET_NETWORK_INFO`、`KEEP_BACKGROUND_RUNNING` |

---

## 构建与运行

### 前置条件

- [DevEco Studio](https://developer.huawei.com/consumer/cn/deveco-studio/)（含 HarmonyOS SDK）
- 一台 HarmonyOS NEXT 7 手机（或模拟器）

### 用 DevEco Studio

1. `Git Clone` 本仓库并在 DevEco 中打开 `HarmonyOS-Phone` 目录
2. 等待 `oh-package` 依赖同步完成
3. `Build → Build Hap(s) / APP(s)` 生成 HAP
4. **真机安装需在 `Project Structure → Signing Configs` 配置签名**（未签名只能产出 `entry-default-unsigned.hap`）

### 命令行（Hvigor）

```bash
cd HarmonyOS-Phone
hvigorw assembleHap --mode module -p product=default --no-daemon
```

> 注：命令行产物默认未签名，真机安装仍需在 DevEco 中配置签名。

---

## 使用说明

- **首次进入**会自动获取 `buvid`（防 412 必需），无需任何账号操作
- **搜索 → 点单曲 / 合集 / UP 主**即可加入播放或下载；搜到 UP 可进主页**订阅投稿**
- **登录**（可选）：设置 → 账户，扫码或短信验证码登录后开启收藏夹同步 / 观看历史 / 我的关注
- **下载页**顶部可切换「选择模式」进行批量管理、重试与删除
- **设置页**可配置：账户、主题色（8 色）、定时停止播放、仅 Wi-Fi 下载、下载音质、缓存清理、歌单导入导出等
- 歌词、播放队列、循环模式均在**播放页**内操作

---

## 音质说明

音质档位与 B 站投稿实际编码绑定。当用户选择的档位不存在时，  
播放器会按既定优先级**自动降级到可获取的最高可用档**（例如选了 132K 但投稿只有 64K/192K，则退到 192K），  
界面显示的码率来自**实测带宽**而非档位标签，避免「显示 192kbps 实则 64K」的误导。

---

## 隐私与免责声明

- 本应用默认以**匿名 + buvid** 身份访问 B 站公开接口；扫码 / 短信登录为可选项，凭据仅保存在设备本地、**不上传到任何第三方服务器**；手机号与验证码只用于本次登录请求。
- 歌单、下载、播放记录等**全部保存在设备本地**，卸载即清除。
- 本项目为**开源学习交流**项目，**与哔哩哔哩官方无关**。
- 音频内容版权归**原作者**所有，请勿将下载内容用于商业用途。

---

## 致谢

- 项目转译自 [HanversionOvO/BiliMusic](https://github.com/HanversionOvO/BiliMusic)，感谢上游作者的基础工作。

---

## 许可证

本项目仅供学习交流使用。如需明确许可证条款，请参考上游仓库的协议约定。
