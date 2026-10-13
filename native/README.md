# Hero OOS macOS 客户端

SwiftUI / AppKit 原生客户端与 `oos-state` 本机 CLI。最低 macOS 15，构建需要支持 Swift 6 的 Xcode / Command Line Tools。SwiftPM 下载固定版本的 Sparkle 2.10.0；无需 Node.js 或 Python 来运行本机工作区。

## 构建、测试与使用

在此目录执行：

```sh
swift build -c release
swift test
zsh scripts/build-app.sh
```

打包结果默认位于 `~/Library/Caches/Hero OOS Build/Hero OOS.app`，可用 `HERO_OOS_BUILD_DIR` 改变输出位置。打包使用本机 ad-hoc 签名；向其他用户分发需自行配置开发者签名、公证与发布流程。

需要安装时，先退出已运行的客户端，再执行：

```sh
zsh scripts/install-app.sh
open "$HOME/Applications/Hero OOS.app"
```

安装脚本替换同名应用，并删除成功安装后的构建副本。请先保存自己的工作。此公开仓库不包含应用程序二进制文件。

首次启动自动建立空白本机工作区。默认数据目录为 `~/Library/Application Support/Hero OOS/local`；`HERO_OOS_ROOT` 可显式指定其他目录。不会搜索或迁移作者的工作区。

从仓库根目录可独立初始化并使用 CLI：

```sh
./scripts/oos-state init
./scripts/oos-state health
./scripts/oos-state meta
```

测试若使用 `--scratch-path`，请同时以 `HERO_OOS_TEST_CLI` 指定该目录中编译出的 `debug/oos-state`，用于真实多进程锁测试。

`init` 仅在状态不存在时创建空白工作区，已有状态保留。也可直接执行 `native/.build/release/oos-state init --root /path/to/workspace`。CLI 修改任务需要版本号与操作 JSON；运行 CLI 不带参数查看帮助。

## 可选自建云端

默认不配置云服务器，不会连接作者的服务。本机任务、日程、关系图、台账和拼图可独立使用。

如需组织账号与同步，先部署仓库的 `server/`，再配置自己的受信任 HTTPS 根地址：

- 从终端直接启动时设置 `HERO_OOS_CLOUD_URL`。
- 打包前在 `Resources/Info.plist` 添加字符串 `HeroOOSCloudURL`，适用于 Finder 启动。

例如 `https://oos.example.com`。客户端要求系统信任的 TLS 证书；HTTP、跨服务器跳转及带用户名密码的地址均被拒绝。账号凭据存入 macOS 钥匙串，服务地址参与凭据与缓存隔离。组织名称由用户输入；首个管理员初始化令牌按服务端文档生成，仅在本人机器上放置于 `~/Library/Application Support/Hero OOS/cloud-bootstrap-token`。不要提交令牌、凭据或工作区。

## 可选更新发布

默认没有 Sparkle 更新地址或公钥，自动检查/下载关闭。维护者可以在打包前设置自己的 `SUFeedURL`（HTTPS 目录下的 `appcast.xml`）与 `SUPublicEDKey`；需要自动更新时同时设置 `SUEnableAutomaticChecks`、`SUAutomaticallyUpdate`。更新目录依据应用内的 feed 确定，签名、大小与摘要校验保留。

`scripts/publish-release.py` 只生成本地签名发布目录，不上传文件。使用 Sparkle 官方 `generate_keys` / `sign_update` 和自己的钥匙串账户：

```sh
python3 scripts/publish-release.py \
  --app '/path/to/Hero OOS.app' \
  --release-dir '/path/to/releases' \
  --sparkle-bin '/path/to/Sparkle/bin' \
  --key-account 'your-update-signing-account' \
  --update-root 'https://updates.example.com/hero-oos/' \
  --schema 1
python3 -B scripts/test_publish_release.py
```

发布目录最多保留十个已登记版本；脚本仅删除自身索引中已校验的旧安装包。私钥留在钥匙串，不进入仓库。

## 数据边界

源代码与测试夹具不含工作区、真实任务、客户资料、原作者部署地址、登录凭据或签名身份。测试中的人物、组织与项目名称均为示例。

可选 Codex 状态功能只读取当前使用者本机 `.codex/state_5.sqlite` 中显式关联的会话状态；依赖 Codex 的本地内部格式，可能随版本变化。没有关联会话时不读取会话数据库，该数据不进入云端共享投影。

使用许可见仓库根目录 [LICENSE](../LICENSE)：mtgh 非商业软件许可，商用须另行获得书面授权。Sparkle 等第三方组件遵循其自身许可，见 [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md)。
