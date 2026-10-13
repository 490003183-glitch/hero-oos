# Hero OOS

**mtgh 的原生 macOS 任务与协作工具。**

Hero OOS 把任务、日程、前置依赖、等待条件和图片拼图放在同一个桌面应用里。SwiftUI / AppKit 界面与命令行共用 Swift 数据核心；本地工作无需运行网页服务。可选 Python 服务端用于组织协作和私人任务同步。

本仓库公开源码，采用 [mtgh 非商业软件许可](LICENSE)：可用于非商业学习、使用、修改和免费分发；**商业用途须事先取得 mtgh 单独书面授权**。该许可限制商业使用，不是 OSI 定义的开源许可。第三方依赖保留各自许可，见 [依赖说明](THIRD_PARTY_NOTICES.md)。

## 功能

- 任务列表、看板、自定义任务页、子任务和跨页前置依赖。
- 任务关系图：缩放、拖动连线、局部整理，以及“等人、等时间、等任务”的开始条件。
- 日程、工作室台账、归档与恢复、带版本检查的修改回执。
- 图片拼图、裁剪、缩放、旋转和本机页面背景。
- AI / 命令行入口：读取状态，按版本与唯一操作标识提交修改。
- 可选自托管协作：组织任务与本人私人任务分别同步，冲突保留两端内容供处理。

## 从源码开始

桌面版需要 **macOS 15 或更高版本、Swift 6 工具链及 Xcode 命令行工具**。构建时会下载锁定版本的 Sparkle 依赖。

```sh
git clone https://github.com/490003183-glitch/hero-oos.git
cd hero-oos/native
swift build
swift test
```

构建应用包（本步不安装）：

```sh
zsh scripts/build-app.sh
```

具体输出位置、安装方式与可选更新配置见 [桌面构建说明](native/README.md)。公开版不绑定作者的云端或更新源；首次使用创建空白本地工作区。仓库不包含任务、客户资料、账号、图片库、迁移记录或签名私钥。

## 命令行与 AI

在仓库根目录运行：

```sh
./scripts/oos-state init
./scripts/oos-state meta
./scripts/oos-state attention
```

默认数据目录为 `~/Library/Application Support/Hero OOS/local`。可以用 `HERO_OOS_ROOT` 或命令末尾的 `--root` 指定独立工作区。`init` 保留已有工作区内容；其他读取命令不会自行选择某个云账号。

命令入口优先使用 `HERO_OOS_CLI` 指定的二进制，然后尝试本仓库的 release / debug 构建及已安装应用。AI 技能放在 [integrations/hero-oos](integrations/hero-oos/SKILL.md)。接入前明确选择工作区；云账号目录应由使用者自行指定，不猜测或跨账号回退。

每次写入先读最新版本。`op` 必须携带 `--expected-version` 和操作文件；相同意图重试复用 mutation ID。不要手工改运行中的 `data/state.json` 或把业务数据提交到仓库。

## 自托管协作

[服务端](server/README.md)使用 Python 3.11+、aiohttp、Argon2 与 SQLite；[部署示例](deploy/README.md)提供反向代理、服务管理与备份配置。

服务端由部署者自己配置。传输采用 HTTPS，服务器执行账号与组织访问控制；服务器管理员能够访问服务端数据，**并非端到端加密**。拼图图片与页面背景保留本机，不包含图片跨设备同步。

## 版本与参与

本次公开版基于 **1.7.10 / build 33（2026-10-13）** 整理。公开副本移除了个人机器绑定、生产部署记录和数据，并补充空工作区初始化与自托管配置。仓库不提供作者服务器账号或自动更新签名身份，也不宣称包含 Apple Developer ID 公证的安装包。

问题和改进可通过本仓库 Issue / Pull Request 提交。请只提供脱敏复现资料，参见 [贡献说明](CONTRIBUTING.md)。
