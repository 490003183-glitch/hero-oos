# Third-party dependencies

Hero OOS 的自定义非商业许可不覆盖第三方组件，也不改变这些组件自身授予的权利。构建及安装依赖时应保留其版权与许可文件。

本仓库不内置第三方源码或二进制；以下许可副本来自本次锁定版本的本地依赖包。Sparkle 由 SwiftPM 获取，Python 依赖由 pip 根据 `server/requirements.lock` 安装。

| 组件 | 版本 | 上游许可 | 许可副本 |
| --- | --- | --- | --- |
| Sparkle | 2.10.0 | MIT，以及随附外部组件许可 | [Sparkle](LICENSES/Sparkle.txt) |
| aiohappyeyeballs | 2.7.1 | PSF-2.0 | [aiohappyeyeballs.txt](LICENSES/aiohappyeyeballs.txt) |
| aiohttp | 3.14.5 | Apache-2.0 AND MIT | [aiohttp.txt](LICENSES/aiohttp.txt) / [aiohttp-2.txt](LICENSES/aiohttp-2.txt) |
| aiosignal | 1.4.0 | Apache 2.0 | [aiosignal.txt](LICENSES/aiosignal.txt) |
| argon2-cffi | 25.1.0 | MIT | [argon2-cffi.txt](LICENSES/argon2-cffi.txt) |
| argon2-cffi-bindings | 26.1.0 | MIT | [argon2-cffi-bindings.txt](LICENSES/argon2-cffi-bindings.txt) |
| attrs | 26.1.0 | MIT | [attrs.txt](LICENSES/attrs.txt) |
| cffi | 2.1.1 | MIT-0 | [cffi.txt](LICENSES/cffi.txt) |
| frozenlist | 1.8.0 | Apache-2.0 | [frozenlist.txt](LICENSES/frozenlist.txt) |
| idna | 3.20 | BSD-3-Clause | [idna.txt](LICENSES/idna.txt) |
| multidict | 6.9.1 | Apache License 2.0 | [multidict.txt](LICENSES/multidict.txt) |
| propcache | 0.5.4 | Apache-2.0 | [propcache.txt](LICENSES/propcache.txt) / [propcache-2.txt](LICENSES/propcache-2.txt) |
| pycparser | 3.11 | BSD-3-Clause | [pycparser.txt](LICENSES/pycparser.txt) |
| yarl | 1.25.1 | Apache-2.0 | [yarl.txt](LICENSES/yarl.txt) / [yarl-2.txt](LICENSES/yarl-2.txt) |

Sparkle 的许可证副本含其随附 bsdiff、sais-lite、Ed25519 等组件声明。aiohttp 另附 llhttp 声明。Apple 系统框架、Swift 工具链和系统 SQLite 由运行平台提供，不随本仓库分发。

具体第三方权利以对应完整许可证及实际安装版本为准。
