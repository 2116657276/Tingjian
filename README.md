# 听笺

macOS 原生课堂录音与中文实时转写工具。使用 SwiftUI、AVFoundation、Apple SpeechAnalyzer / SpeechTranscriber，支持课后通过 Magpie 纠正文字。

## 目录

- `Sources/Tingjian`：原生界面与设置。
- `Sources/TingjianCore`：录音、转写、保存、恢复与文字纠正。
- `Sources/tingjian-check`：合成音频和故障注入验证工具。
- `scripts`：构建、图标及环境脚本。
- `docs`：使用文档、按日期归档的验证记录与原始证据。
- `dist`：当前开发测试版应用包；被 `.gitignore` 忽略。

文档入口见 [docs/README.md](docs/README.md)，当前状态和已有测试结论见 [项目状态与验证摘要](docs/项目状态与验证摘要.md)。

## 构建

在仓库根目录运行：

```sh
bash scripts/build_app.sh
```

应用输出到 `dist/听笺.app`，构建中间文件使用 `/tmp`。需要本机 Swift、macOS SDK、codesign、iconutil 和 trash，无需完整 Xcode。支持传入自定义应用输出路径作为脚本第一个参数。

使用说明见 [docs/听笺_使用说明.md](docs/听笺_使用说明.md)，课堂验收见 [docs/听笺_课堂验收清单.md](docs/听笺_课堂验收清单.md)。历史验证材料从 [验证归档](docs/verification/README.md) 进入。真实课堂准确率、睡眠/拔插设备与 iCloud 云同步仍待人工验证。

## 版本位置

- 日常使用版位于 `/Applications/听笺.app`，为经过针对性验收的 2026-11-19 修复构建。
- 测试版位于本项目的 `dist/听笺.app`。当前与日常使用版为同一构建，两者均显示版本 1.0.1（构建 2）。
- 构建脚本只更新项目内测试包。验收通过后再将可用版本放入“应用程序”。

近期测试结果与未完成事项见 [项目状态与验证摘要](docs/项目状态与验证摘要.md)。

## 迁移记录

源码及三份文档于 2026-11-13 从 Codex 工作区 outputs 迁至此仓库。历史交付材料已按项目文档索引归档。本次仅初始化 Git，未创建提交，未配置远程仓库。运行时的录音、恢复数据和用户设置没有迁移或修改。
