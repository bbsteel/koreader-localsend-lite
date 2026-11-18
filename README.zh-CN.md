# LocalSend Lite for KOReader

[English](README.md)

通过 [LocalSend v2.2](https://github.com/localsend/protocol) 在局域网内收发电子书和其他文件。

**v0.1.0 安装包仅约 24 KB。** 插件在 KOReader 内运行，复用其自带的 Lua 运行环境和网络库，收发文件时才启动网络服务。

## 安装

1. 从 [GitHub Releases](https://github.com/bbsteel/koreader-localsend-lite/releases/latest) 下载 ZIP。
2. 解压并把整个 `localsend-lite.koplugin` 目录复制到 KOReader 的 `plugins/` 目录。Kindle 的 USB 存储中应能看到 `koreader/plugins/localsend-lite.koplugin/main.lua`。
3. 安全弹出 Kindle，重启 KOReader，打开 **工具 → LocalSend Lite**。默认位于工具菜单首页第一项。

如果你装过本项目更名前的开发版，先把它的 `localsend.koplugin` 移出 `plugins/`。Lite 使用独立设置，首次启动会生成自己的设备身份。两个插件都使用默认端口时，每次只启动一个接收服务。

## 收发文件

- **Send files（发送文件）** 打开 KOReader 文件选择器。长按文件名并确认，再点自动发现的设备。批量发送时，可先在书库的选择模式里选好文件，再打开 **Send files**。
- **Receive files（接收文件）** 显示本机昵称和保存目录。保持页面打开，在发送方选中该昵称，然后在阅读器上确认。接收默认使用当前书库目录，遇到同名文件会给新文件加编号。
- **Stop（停止）** 关闭接收服务。Kindle 版在传输界面打开期间临时放行 Wi‑Fi 上的 LocalSend 端口，并在停止时撤销规则。

昵称跟随 KOReader 界面语言，同一设备身份在同一语言下使用固定昵称。插件内置 22 套昵称词库，其他语言使用英文。文件按 32 KiB 分块读写，每批最多 128 个文件，单个小于 4 GiB。普通 `.txt` 附件可正常传输。发现使用 IPv4 组播 `224.0.0.167:53317`，默认接收端口为 HTTPS TCP `53317`。

## 验证

测试基于 Linux 上的 KOReader v2026.07.1。脚本默认使用已安装的 Flatpak 版 KOReader，也可传入含 `luajit` 和 `setupkoenv.lua` 的目录。临时文件写到 `~/tmp`，结束后自动清理。

| 命令 | 验证内容 |
| --- | --- |
| `bash tests/run-koreader-ui.sh` | 插件加载、工具菜单位置、接收服务生命周期、多语言昵称 |
| `bash tests/run-loopback.sh` | 自动发现、文件收发、TLS 指纹、校验失败处理、取消与 Kindle 防火墙清理模拟 |
| `bash tests/run-official-cli.sh` | 官方 LocalSend CLI 1.18.2 按中文昵称发现插件，并逐字节核对双向 HTTPS 文件传输 |

更名前的开发版已装到一台 Kindle Paperwhite 2。手机热点上的真机发现需单独验证。
