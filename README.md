# BiliMusic

> 一款基于 **HarmonyOS** 的 B 站第三方音乐播放器，以**匿名 + buvid** 身份访问 B 站音频资源，无需登录，数据全部保存在设备本地。
>
> A third-party Bilibili music player built natively for HarmonyOS — anonymous access, no login required, all data stored locally on device.

![Platform](https://img.shields.io/badge/platform-HarmonyOS%20NEXT%207-blue)

![API](https://img.shields.io/badge/API-26-blue)

![Language](https://img.shields.io/badge/language-ArkTS%20%2F%20ArkUI-orange)

![Version](https://img.shields.io/badge/version-1.0.2-green)

---

## 简介

BiliMusic 把 B 站上的音频内容（单曲、合集、音乐中心榜单、UP 主投稿）整理成一个纯粹的「听歌」应用。  
它**不依赖登录**，用匿名身份 + buvid 拉取音源，因此没有会员、收藏夹同步等需要账号的能力，  
但也因此更轻、更私密——你的歌单、下载、播放记录都只留在你自己的手机里。

- **作者**：chai
- **转译自**：[github.com/HanversionOvO/BiliMusic](https://github.com/HanversionOvO/BiliMusic)
- **运行环境**：HarmonyOS NEXT 7（API 26）手机端

---

## 功能特性

### 🔍 搜索与发现

- 四个入口：**搜索 / 推荐 / 排行榜 / 音乐中心**
- 搜索覆盖**单曲、合集、视频、UP 主**等多种结果类型
- 音乐中心支持真分页（`web/rank` / `comprehensive`），新歌榜自动补齐首屏
- 首页推荐流支持「换一批」（`freshIdx` 刷新）

### 📃 歌单与媒体库

- 收藏单曲、把**合集一键保存为歌单**
- 本地媒体库：自建歌单、增删曲目、**删除墓碑**（软删除，可追溯）
- **最近播放**记录

### ⬇️ 下载管理

- **音质选择**：64K / 132K / 192K / 杜比 / Hi-Res，按投稿实际档位优雅降级
- **串行下载队列** + 实时速度显示（速度取 1s 窗口增量，瞬时态不落库）
- **断点续传**：基于 HTTP `Range` 续传，暂停后带 `ignoreWifiLimit` 重试
- **仅 Wi-Fi 下载**开关，非 Wi-Fi 环境提示用户后放行
- **批量操作**：全部暂停 / 全部开始、**多选删除**
- 暂停 / 恢复为会话内能力（进程重启后队列需重新触发）

### ▶️ 播放

- **沉浸取色背景** + 封面 **Swiper 双页**（封面 / Canvas 时间轴歌词）
- 唱片**旋转动画**（线性无限循环）与缓慢不规则**呼吸效果**
- **播放队列**弹层、循环模式：**顺序 / 单曲 / 列表循环 / 随机**
- **后台播放**（`KEEP_BACKGROUND_RUNNING` 长时任务保活）
- **分 P 视频**自动展开为多首曲目

### 🎨 界面

- 底栏采用 HDS（HarmonyOS Design System）`HdsTabs` **沉浸光感悬浮胶囊**：  
  系统材质 + 品牌色 `#FB7299` 光晕，播放栏与页签融合于同一胶囊
- 双粉策略（B 站粉视觉 + 深粉文字）兼顾品牌调性与可读性
- 设计了规范化的色彩 / 字阶 / 触达 / 动效体系（见 `design/`）

---

## 技术栈

| 维度      | 选型                                                      |
| ------- | ------------------------------------------------------- |
| 系统      | HarmonyOS NEXT 7（API 26）                                |
| 语言 / 框架 | ArkTS + ArkUI（声明式）                                      |
| 设计系统    | `@kit.UIDesignKit`（HDS）沉浸材质底栏                           |
| 构建      | Hvigor                                                  |
| 状态管理    | `@StorageLink` / `@State` 等 ArkUI 状态装饰器                 |
| 持久化     | `@ohos.data.preferences`（单值 8192 字节上限，快照式读写）            |
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
- **搜索 → 点单曲 / 合集**即可加入播放或下载
- **下载页**顶部可切换「选择模式」进行批量管理与删除
- **设置页**可配置：定时停止播放、仅 Wi-Fi 下载、缓存清理等
- 歌词、播放队列、循环模式均在**播放页**内操作

---

## 音质说明

音质档位与 B 站投稿实际编码绑定。当用户选择的档位不存在时，  
播放器会按既定优先级**自动降级到可获取的最高可用档**（例如选了 132K 但投稿只有 64K/192K，则退到 192K），  
界面显示的码率来自**实测带宽**而非档位标签，避免「显示 192kbps 实则 64K」的误导。

---

## 隐私与免责声明

- 本应用以**匿名 + buvid** 身份访问 B 站公开接口，**不登录、不收集、不上传任何用户数据**。
- 歌单、下载、播放记录等**全部保存在设备本地**，卸载即清除。
- 本项目为**开源学习交流**项目，**与哔哩哔哩官方无关**。
- 音频内容版权归**原作者**所有，请勿将下载内容用于商业用途。

---

## 致谢

- 项目转译自 [HanversionOvO/BiliMusic](https://github.com/HanversionOvO/BiliMusic)，感谢上游作者的基础工作。

---

## 许可证

本项目仅供学习交流使用。如需明确许可证条款，请参考上游仓库的协议约定。
