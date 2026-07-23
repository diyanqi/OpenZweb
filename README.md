# OpenZweb

> **免责声明**
>
> 本项目为非官方、社区维护的开源工具，与浙江大学、深信服科技及任何 VPN 服务提供商均无隶属或授权关系。  
> 仅供学习、科研与个人网络调试用途。请遵守学校信息技术管理规定、相关服务条款与所在地法律法规。  
> 使用本软件产生的账号风险、服务封禁、数据安全问题等，均由使用者自行承担。作者与贡献者不提供任何明示或默示担保，也不对使用后果负责。  
> **请勿用于任何违反校规、法律或服务协议的行为。**

浙江大学校园 VPN 原生 **macOS** 客户端（SwiftUI），对接深信服 **aTrust** 协议，兼容 [EZ4Connect](https://github.com/chenx-dust/EZ4Connect) / [zju-connect](https://github.com/Mythologyli/zju-connect) 生态。

学号密码登录后，通过 **SOCKS5/HTTP 代理** 或 **TUN 虚拟网卡** 访问校内网。默认服务器：`vpn.zju.edu.cn`。

---

## 功能

- aTrust / EasyConnect 协议（引擎：`zju-connect`）
- 学号密码 · 图形人机验证（应用内 WebView）· 短信 OTP
- **代理模式**（默认，无需管理员）/ **TUN 模式**（需管理员，系统级路由）
- 连接后可切换代理 / TUN；菜单栏快捷操作
- 系统代理自动管理（可关，便于与 Clash 等共存）
- 局域网共享代理（0.0.0.0 + 二维码）
- 分流：**白名单**（强制走 VPN）/ **黑名单**（PAC 直连）
- 短信二次认证：可选「跳过以后的短信验证」（见下文）
- 启动检查更新（仅提示，不自动安装；大陆镜像优先）
- 钥匙串记住密码 · 实时网速 · IP 检测 · 浙大导航入口

---

## 环境

- macOS 14+
- Xcode 15+（本地编译）
- Apple Silicon（arm64）优先；Release DMG 由 GitHub Actions 构建

---

## 快速开始

### 下载安装（推荐）

从 [Releases](https://github.com/diyanqi/OpenZweb/releases) 下载 `OpenZweb-*-macos-arm64.dmg`，拖入「应用程序」。

DMG **已内置** `zju-connect` 协议引擎，一般无需再下载。

### 从源码编译

```bash
# 可选：本地准备引擎（CI 会自动下载）
./Scripts/download-core.sh

open OpenZweb.xcodeproj   # ⌘R
```

命令行：

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcodebuild -project OpenZweb.xcodeproj -scheme OpenZweb -configuration Debug \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO build

open build/Build/Products/Debug/OpenZweb.app
```

### 连接

1. 输入学号与密码  
2. 选择 **代理** 或 **TUN**  
3. 完成人机验证与短信（如有）  
4. 代理模式默认：
   - SOCKS5：`127.0.0.1:1080`
   - HTTP：`127.0.0.1:1081`

```bash
curl -x socks5h://127.0.0.1:1080 https://www.cc98.org
```

校内论坛域名为 **`www.cc98.org`**（不是 98cc.org）。

---

## 与 Clash 等代理共存

1. 关闭 OpenZweb 的「连接后自动设置系统代理」  
2. Clash 继续管理系统代理  
3. 在 Clash 中将 `*.zju.edu.cn`、`cc98.org` 等走 OpenZweb 的 SOCKS  
4. **`vpn.zju.edu.cn` 必须直连**（勿进 Fake-IP）

---

## 分流规则

**设置 → 分流规则**

| 类型 | 作用 |
|------|------|
| 白名单 | 写入 zju-connect `custom_proxy_domain`，强制走校园 VPN |
| 黑名单 | 写入导出的 PAC，匹配域名直连 |

支持逗号或换行分隔，如 `science.org, nature.com`。

---

## 短信「跳过以后的短信验证」

对应 [EZ4Connect 实现](https://github.com/chenx-dust/EZ4Connect/commit/6728892e022adbe1e7cb24709dbfa517b433b7fc) 与 zju-connect 提示：

> Tips: Add prefix `$` to sms code to skip secondary authentication

### 原理

aTrust 登录成功后，若触发**二次增强认证**（短信），引擎会提示：

- `Please enter the SMS verification code:` → **二次短信**（可跳过后续）
- `Please enter your SMS code:` → **主短信登录**（无跳过项）

在二次短信场景下，若在验证码前加 **`$`** 再提交（例如真实验证码为 `123456`，则提交 `$123456`），会向服务端带上 `skipSecondaryAuth` 意图，请求**跳过以后的二次短信验证**。

OpenZweb 在二次短信弹窗中提供复选框「跳过以后的短信验证」；勾选后自动加 `$` 前缀。设置中可「默认勾选」。

### 注意

- 是否真正生效取决于学校 aTrust 策略与账号风控，**不保证**每次可用  
- 仅作用于二次短信提示，不会绕过首次密码 / 人机验证  
- 请勿滥用；请遵守校规与服务条款

---

## 检查更新

- 启动时可自动检查（设置中可关）  
- 设置 / 菜单栏可手动「检查更新」  
- **只检查、不自动安装**  
- API 优先走大陆可达镜像（ghfast / ghproxy 等），再回落 `api.github.com`

---

## 发布 / DMG（GitHub Actions）

推送版本标签触发构建（内置引擎）并上传 Release：

```bash
git tag v1.0.0
git push origin v1.0.0
```

也可在 Actions 页手动 `workflow_dispatch`。

本地打包：

```bash
./Scripts/download-core.sh
xcodebuild -project OpenZweb.xcodeproj -scheme OpenZweb -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=NO build
./Scripts/package-dmg.sh --app build/Build/Products/Release/OpenZweb.app --version 1.0.0
```

---

## 项目结构

```
OpenZweb/           # SwiftUI 应用
Core/               # zju-connect 二进制（本地/CI 放入，不强制进 git）
Scripts/            # download-core / package-dmg / 图标
Tools/              # 空 open 桩，抑制人机验证弹系统浏览器
.github/workflows/  # Release DMG
```

---

## 鸣谢

- [diyanqi/OpenZweb](https://github.com/diyanqi/OpenZweb) — 本项目  
- [Mythologyli/zju-connect](https://github.com/Mythologyli/zju-connect) — 协议引擎  
- [Mythologyli/ZJU-Connect-for-Windows](https://github.com/Mythologyli/ZJU-Connect-for-Windows) — Windows 客户端参考  
- [chenx-dust/EZ4Connect](https://github.com/chenx-dust/EZ4Connect) — aTrust 研究与二次短信 `$` 跳过  
- [kaixuanwang2003/zju-welcome](https://github.com/kaixuanwang2003/zju-welcome/) — 浙大导航 [zjuers.com](https://zjuers.com/)

---

## 许可证

源码以仓库内声明为准；`zju-connect` 等第三方组件遵循其各自许可证。使用本软件即表示你已阅读并同意文首免责声明。
