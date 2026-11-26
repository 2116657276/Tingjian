# 听笺

macOS 原生课堂录音与中文实时转写工具。使用 SwiftUI、AVFoundation、Apple SpeechAnalyzer / SpeechTranscriber，支持课后通过 DeepSeek 官方、Magpie 或自定义网关纠正文字。

## 目录

- `Sources/Tingjian`：原生界面与设置。
- `Sources/TingjianCore`：录音、转写、保存、恢复与文字纠正。
- `Sources/tingjian-check`：合成音频和故障注入验证工具。
- `scripts`：构建、图标及环境脚本。
- `docs`：使用说明、当前状态、独立评审和按日期归档的验证记录。
- `dist`：当前开发测试版应用包；被 `.gitignore` 忽略。

[文档入口](docs/README.md)提供使用与课堂验收、当前状态、代码评审和验证归档。

## 构建与版本

稳定版位于 `/Applications/听笺.app`，测试版位于项目内 `dist/听笺.app`，最多同时保留这两个可运行版本；替换时旧包用 `trash` 移入废纸篓，不保留额外副本。`dist/` 被 `.gitignore` 忽略。当前构建和已验收范围见 [当前版本与验收状态](docs/project/当前版本与验收状态.md)。

```sh
bash scripts/build_app.sh
```

脚本会加载 `scripts/env.sh`，生成图标、`Info.plist` 和 ad-hoc 签名，默认产出 `dist/听笺.app`，并执行 `codesign --verify --strict`。运行与构建需要 macOS 26.0 及以上、Swift 6.2、macOS SDK、codesign、iconutil 和 trash；AAC 编码与废纸篓检查依赖对应 macOS 服务。每次交付递增 `scripts/build_app.sh` 中的 `CFBundleVersion`；用户可见版本变化时更新 `CFBundleShortVersionString`，并同步状态文档。

安装稳定版前先完成针对性验证并退出正在运行的应用，用 `ditto` 复制到 `/Applications/`，再对安装包和 `dist/` 包分别执行 `codesign --verify --deep --strict` 校验签名。签名标识为 `com.local.tingjian`。

## 验证

命令行回归使用新的隔离目录，不读取正式资料库：

```sh
. scripts/env.sh
swift build --disable-sandbox --scratch-path /tmp/tingjian-build --product tingjian-check
TINGJIAN_CHECK_ROOT=/tmp/tingjian-check-$(date +%Y%m%d-%H%M%S) \
  /tmp/tingjian-build/debug/tingjian-check --real
```

文字纠正默认执行模拟检查，`--skip-correction` 跳过；`--real` 启用真实识别，`--real5` 以实时速度运行约 8 分钟（481 秒）合成语音长测，`--magpie` 启用真实 Magpie 网关。网关失败如实保留，不用重试掩盖。

`--weak-voice-bench` 以实时速度验证五组固定合成语音，`--weak-voice-holdout` 使用第二份合成讲稿。`TINGJIAN_CHECK_AUDIO` 可为原讲稿复用相同内容的合成音频。`TINGJIAN_BENCH_CASE=combined-weak` 单跑组合弱音，`TINGJIAN_BENCH_FAST_RESULTS`、`TINGJIAN_BENCH_GAIN_RISE`、`TINGJIAN_BENCH_GATE_HZ` 分别控制快速识别、增益上升时间（秒）和侧链高通频率（Hz），仅用于基准对照。专项开关还包括 `--audio-regressions-only`（不依赖语音模型的音频专项）、`--recording-target-only`（保存目标快照）、`--placement-only`（草稿占位交付）、`--correction-only`（连续文字纠正）、`--workspace-state-only`（工作区路径映射、高亮与标签页策略）、`--trash-smoke`（系统废纸篓冒烟）、`--long-only`（仅跑 30 分钟模拟引擎加速交付）与 `--long`（在全量回归后追加 30 分钟长测）。

桌面验收同时设置 `TINGJIAN_TEST_ROOT` 与 `TINGJIAN_TEST_AUDIO`，确认窗口显示隔离资料库后再操作；不打开真实麦克风，不写正式保存目录。真实设备、睡眠、iCloud 跨设备同步和课堂识别效果列为未验证项，交由用户验收。

有实质验证时，在 `docs/verification/YYYY-MM-DD/` 新增记录，写清范围、环境、结果和未验证项，并更新 [验证归档索引](docs/verification/README.md)。历史记录保留原结论并标明日期，不作为当前缺陷或版本说明。
