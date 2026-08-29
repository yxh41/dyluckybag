# 抖音福袋助手 (DYLuckyBag)

iOS 越狱插件，自动检测并参与抖音直播间福袋。

## 设计要点：不 hook 任何抖音类

几乎所有抖音 tweak 都因为 hook 了某个类，而抖音每 2-3 周改一次 UI 导致失效。
本插件**完全不 hook 抖音的任何类**，改为：

1. **截屏** — `drawViewHierarchyInRect:` 抓取当前画面
2. **OCR** — Vision 框架识别屏幕文字（"福袋" / "参与" / "口令" / "恭喜"）
3. **命中测试** — 用 OCR 得到的坐标 `hitTest:` 找到对应控件
4. **点击** — 优先走公开的 `sendActionsForControlEvents:`，失败才降级到合成 UITouch

好处：抖音改版只影响 OCR 关键词（中文文案很稳定），不会导致整个插件失效。

## 功能

- 总开关
- 巡逻模式三档：仅检测 / 自动参与 / 全自动巡逻
- 超级福袋 · 自动参与
- 普通福袋 · 自动参与
- 评论口令自动发送
- 直播间自动巡逻
- 中奖横幅提醒
- 统计：今日参与 / 今日中奖 / 巡逻房间（跨天自动重置）
- 悬浮面板（可拖动，点击"福"按钮展开）

## 安装

1. 越狱设备（roothide / rootless / Dopamine，iOS 15+）
2. 安装 `DYLuckyBag.deb`（release）或 `DYLuckyBag-debug.deb`（带日志，用于排查）
3. 打开抖音，进入任意直播间
4. 屏幕右侧出现"福"悬浮按钮，点击展开面板

## 日志（仅 debug 包）

release 包把所有日志编译掉了（零开销）。
debug 包日志写入以下位置（按顺序尝试第一个可写的）：

- `/var/mobile/dyluckybag.log`
- `~/Documents/dyluckybag.log`
- `NSTemporaryDirectory()/dyluckybag.log`

## 状态说明（面板/日志里会看到）

| 状态 | 含义 |
|---|---|
| `当前直播间没有福袋` | OCR 没在屏幕上找到"福袋"字样 |
| `检测到福袋，未找到参与按钮` | 有福袋但没识别出"参与"（可能文案变化） |
| `[仅检测] 发现参与按钮 'xxx'` | 仅检测模式，识别成功但故意不点 |
| `已点击参与` | 成功派发点击，今日参与 +1 |
| `已参与，等待开奖` | 屏幕上出现"已参与" |
| `中奖：...` | 检测到"恭喜"/"中奖" |

## 当前版本限制 (v0.1)

- **口令自动发送**：已能识别并提取口令，但**还没实现真正发评论**（需要可靠定位直播间输入框），v0.2 补上
- **直播间自动巡逻**（切下一个房间）：尚未实现（需要上滑手势模拟），v0.2 补上
- **超级/普通福袋区分**：OCR 层面尚未区分，两者都按"福袋"处理

## 构建

本地需要 Theos（Linux/macOS/WSL）：

```bash
make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=rootless   # release
make package DEBUG=1 THEOS_PACKAGE_SCHEME=rootless          # debug（带日志）
```

或推送到 `main` 分支，GitHub Actions（macos-14）会自动构建并发布
release + debug 两个包到 `ci-artifacts` 分支。

## 免责声明

仅供个人学习研究。请遵守抖音平台服务条款，勿用于大规模商业薅羊毛或账号批量操作。
