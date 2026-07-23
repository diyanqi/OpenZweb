# OpenZweb 完成度与验收

## 目标拆解

| 需求 | 状态 | 证据 |
|------|------|------|
| 修复 download-core `asset not found` | 代码已修 | 现代资源名 `zju-connect-darwin-arm64.zip`；`Scripts/tests/test-asset-picker.py` 通过 |
| 本机拿到 `Core/zju-connect` | **待本机网络** | Codex 沙箱无 DNS；网络提权被拒；需在终端运行 `./Scripts/download-core.sh` |
| TUN 模式 | 已实现 | `connectionMode` / `tun_mode` / 管理员启动 + FIFO 验证码 |
| App 图标 | 已实现 | `AppIcon.appiconset` 全尺寸 PNG |
| 客户端完善 | 已实现 | 代理/TUN、钥匙串、CAS 门户、PAC、关于、菜单栏、自动重连 等 |
| Xcode 构建 | 通过 | `BUILD SUCCEEDED` → `build/Build/Products/Debug/OpenZweb.app` |

## 近期修复（2026-07-23）

- 默认服务器：`rvpn.zju.edu.cn` → **`vpn.zju.edu.cn`**（含已保存旧默认的自动迁移）
- 引擎发现：从 `#filePath` / 工程树 / App Support 解析 `Core/zju-connect`，并自动拷贝到 `~/Library/Application Support/OpenZweb/`
- 连接按钮：缺引擎/缺凭据时显示明确原因；架构不匹配（如 x86_64 on arm64）给出警告但仍可尝试

## 你需要执行的一步

```bash
cd /Users/diyanqi/Developer/openZweb
./Scripts/download-core.sh
# 成功标志：
test -x Core/zju-connect && file Core/zju-connect
open build/Build/Products/Debug/OpenZweb.app
```

手动备选：
1. 打开 https://github.com/Mythologyli/zju-connect/releases
2. 下载 `zju-connect-darwin-arm64.zip`
3. 解压后将二进制放到 `Core/zju-connect` 并 `chmod +x`
