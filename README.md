# MacPulse

一个面向开发者的 macOS 菜单栏系统监视器：看清资源被谁占用、按内存压力判断是否真的吃紧，并安全地清理开发端口、缓存与构建产物。

A lightweight macOS menu bar monitor for developers — CPU / memory pressure, per-app resource usage, dev-port cleanup and safe cache cleanup. UI is in Simplified Chinese.

## 功能

**资源**
- 菜单栏显示 CPU 占用；内存压力偏高 / 紧张时图标变为橙 / 红色。
- 内存卡片按活动监视器口径显示「已使用内存」，颜色跟随**内存压力**（与活动监视器底部曲线同源），并按 App / 内核 / 压缩 / 文件缓存分段，悬停查看明细。
- CPU 与内存历史曲线可切换，显示峰值。
- 进程按应用和服务归组（如 `前端开发 · my-app`、`Gunicorn · backend`），区分「可结束 / 需确认 / 系统保护」，系统进程不可结束。
- 内存压力升到「紧张」时发送系统通知，列出占用最多的应用；每次升级只提醒一次。

**端口**
- 列出所有监听端口及对应进程，识别开发服务（Vite、webpack、Gunicorn 等）。
- 一键关闭无活跃连接的开发服务；可选自动关闭闲置超过 30 分钟的开发端口。数据库、Docker、代理与系统服务始终保护。

**清理**
- AI 工具缓存（Claude、Codex 等）：应用运行中自动跳过，只删可重建的缓存。
- 磁盘清理：扫描你指定的工作区目录中 30 天未改动项目的 `node_modules`、`.build`、`DerivedData` 等，移到废纸篓。
- 软件卸载：应用及所选关联数据移到废纸篓，可还原。

## 系统要求

- macOS 14 或更高版本
- 从源码构建需要 Swift 6 工具链（Xcode 16 或 Command Line Tools）

## 构建与运行

```bash
git clone https://github.com/0xYubo/MacPulse.git
cd MacPulse
./scripts/package.sh          # 产出 dist/MacPulse.app（ad-hoc 签名）
open dist/MacPulse.app
```

运行测试：

```bash
swift test
```

> 应用为 ad-hoc 签名，首次打开若被 Gatekeeper 拦截，可在访达中右键 → 打开。

### 开机自启动（可选）

在「系统设置 → 通用 → 登录项」中添加 `MacPulse.app` 即可。

## 安全设计

- 结束进程只发送正常退出信号，受保护进程（系统服务、MacPulse 自身等）拒绝处理。
- 文件清理一律移到废纸篓（AI 缓存除外，缓存会由应用自动重建），并拒绝符号链接与白名单外的路径。
- 不联网、不收集任何数据。

## 许可证

[MIT](LICENSE)
