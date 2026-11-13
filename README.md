# MacPulse

一个面向开发者的 macOS 菜单栏系统监视器：看清资源被谁占用、按内存压力判断是否真的吃紧，并安全地清理开发端口、缓存与构建产物。

A lightweight macOS menu bar monitor for developers — CPU / memory pressure, per-app resource usage, dev-port cleanup and safe cache cleanup. UI is in Simplified Chinese.

## 功能

**概览**
- CPU 与内存双圆环；内存按活动监视器口径显示「已使用」，颜色跟随**内存压力**（与活动监视器底部曲线同源），分段条显示 App / 内核 / 压缩 / 文件缓存，悬停查看明细。
- CPU / 内存历史曲线可切换，显示峰值。
- 菜单栏可显示 CPU、内存、两者或仅图标；内存压力偏高 / 紧张时图标变橙 / 红。

**资源**
- 进程按应用和服务归组（如 `前端开发 · my-app`、`测试 · my-app`、`虚拟机（Docker 等）`），区分可结束 / 需确认 / 系统保护。
- 两类系统通知：内存压力升到「紧张」时；单个应用（同名进程合计，如 9 个 jest worker）超过阈值时（默认 6 GB，可调）。每次只提醒一次。

**端口**
- 列出所有监听端口，识别开发服务（Vite、webpack、Gunicorn 等），一键关闭无活跃连接的开发服务，可选自动关闭闲置 30 分钟的开发端口。
- MySQL、Redis 等数据库监听在所有网卡上时标红提醒。

**Docker**
- 容器合计内存、虚拟机实际占用与内存上限，每个容器的 CPU / 内存；逐个或全部启停容器，Docker 未运行时一键启动。

**清理**
- AI 工具缓存（Claude、Codex 等）：应用运行中自动跳过。
- 磁盘清理：开发缓存、应用缓存、日志，以及指定工作区中 30 天未改动项目的 `node_modules`、`.build`、`DerivedData`，移到废纸篓。
- 软件卸载：应用及所选关联数据移到废纸篓，可还原。

**诊断**
- 读取 macOS 自动写入的诊断报告，列出近 14 天的内存耗尽、关机卡住、无响应、崩溃与 CPU 超标；置顶显示「最近一次内存耗尽时谁占得最多」。

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
- 不联网、不收集任何数据；Docker 信息通过本机 `docker` 命令读取。

## 许可证

[MIT](LICENSE)
