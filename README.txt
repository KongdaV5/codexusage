codexusage v1.13.0

轻量 macOS 菜单栏 Codex 额度查看器。

主要特性：
- 5h / 7d 两行紧凑显示，10 段进度，末段支持部分填充
- 中文原生 AppKit 菜单
- 额度：Codex app-server → account/rateLimits/read
- 账号 Token：Codex app-server → account/usage/read（当天 / 全部）
- 不读取 auth.json，不保存 Codex Token，不扫描本地 session 统计额度
- 5 分钟自动刷新；打开菜单超过 60 秒才后台刷新
- 无悬浮球、无 Usage Trend
- Objective-C + AppKit 原生实现

安装：双击 install.command。

本版状态栏保持 70pt 的最终宽度和原生灰色高亮区域；内部标签、10 段进度和百分比继续铺满可用宽度；绿色保持更沉稳的 #2F9B56。


底层清理：运行时不再扫描已运行 App 的重复 CLI 路径；刷新定时器只注册一次；app-server 请求结束后会关闭输入并等待子进程退出。
