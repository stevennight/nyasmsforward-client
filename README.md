# NyaSmsForward Client

NyaSmsForward 的客户端（Flutter，Windows + Android）：不用打开 Web 页面，就能看短信、收新短信 / 验证码提醒、一键复制验证码，并且可以**回复**和**新发**短信。

- **Android 版**：装在你平时用的主力手机上。前台服务保持连接，新验证码通知里可以直接「复制验证码」，也能在通知里直接回复。
- **Windows 版**：托盘常驻，新验证码弹浮窗，主窗口里回复 / 新发。提供安装包和便携 zip。

注意：这不是放 SIM 卡收短信的那个 App。接收端是 `nyasmsforward-client-node`。

## 仓库关系

NyaSmsForward 由三个独立仓库组成，互不依赖代码，只通过服务端仓库的 `docs/协议.md` 对接：

- `nyasmsforward-server`：服务端 + Web 管理台
- `nyasmsforward-client-node`：接收端（Android，放 SIM 卡的手机）
- `nyasmsforward-client`（本仓库）：Windows + Android 客户端

## 当前状态

**M2（查看）和 M3（回复 + 新发）已完成**，用真实服务端的端到端测试验证过协议层（`test/e2e/`）。**平台相关的部分（Windows 托盘 / Toast、Android 前台服务 / 通知 / 扫码）已编译通过、逻辑有单元测试，但没有在真机 / 真实桌面会话里验证过**，见下面“未验证”。

- **连接**：配对码（兼容 `483 920`）、管理员账号登录（只用一次换令牌，不保存密码）、粘贴 / 扫描配对链接 `nyasmsforward://pair?…`（Android 扫码）。令牌存系统安全存储，长期有效；只有 `401` + `token_revoked / token_invalid / token_expired` 才回到连接页（保留地址和设备名），断网 / 5xx / 反代裸 401 一律保留令牌、退避重连。
- **实时**：`GET /api/v1/events`（SSE，`Authorization` 头，`http` 流式手写解析）。重连带 `Last-Event-ID` 补发，连上就重新拉取列表，70 秒没有任何数据（服务端每 20 秒一条 keep-alive）视为断线。
- **浏览**：会话列表 / 搜索 / 未读过滤，宽窗口左右分栏、手机上逐页；验证码识别卡片一键复制；发出的短信区分“手机上发出 / 经平台发出”。
- **回复、新发与回收**：回复框（Enter 发送、Shift+Enter 换行、输入法组字时的 Enter 不发送）、快捷回复（点一下填入，仍需确认发送，可在设置里改）、发送任务状态条（排队 → 已下发 → 已发送 → 已送达 / 失败原因，排队中可取消）、新短信对话框（选手机、SIM、号码）；可多选短信移到回收站，回收站是独立页面并按 100 条游标分页，30 天内可恢复；权限 / 策略不足时说明是哪一层不允许。
- **通知**：Windows Toast、Android 通知，验证码在标题里，按钮「复制验证码」和内联回复；已读 / 删除后撤销。
- **Windows**：托盘图标（未读数在提示里）、关闭窗口留在托盘、可选开机自启（`--background` 隐藏启动）。
- **Android**：前台服务（`specialUse`）在后台保持连接并弹通知，App 在前台时由 App 自己持有连接（同一时间只有一条连接、不重复提醒）；设置里可单独打开“前台也弹出通知”；电池优化白名单入口。
- **应用更新**：设置页可检查本仓库 GitHub Release，下载前校验 SHA-256；Windows 启动安装器，Android 调起系统 APK 安装确认。

### 未验证（需要真机 / 真实桌面）

- Windows：托盘图标与菜单、Toast 是否弹出以及按钮 / 输入框回调（未打包 App 的 AUMID 注册由插件写注册表，未实测）、开机自启后的隐藏启动。
- Android：前台服务保活（尤其国产 ROM）、从最近任务划掉后是否继续、通知里的内联回复（后台 isolate 处理函数）、前台通知悬浮效果、「复制验证码」按钮在各 ROM 上能否写剪贴板、二维码扫描。
- 已做：Windows 单实例（再次启动只会把已运行的窗口带到前面，已实测 3 次启动只有 1 个进程）。
- 未做：本地缓存（离线时看不到历史）、发送前的系统认证（生物识别 / Windows Hello）。

已经落地并有测试的逻辑：

- `lib/src/api/`：`ApiClient`（REST）、`EventStreamRunner`（SSE）、模型、地址校验、令牌失效判定和退避（与 client-node 共用同一批判断用例）。
- `lib/src/session/`：`AppController`（连接、列表、实时事件、回复 / 新发、改地址先验证）、设置存储。
- `lib/src/notifications/`、`lib/src/background/`、`lib/src/desktop/`：通知内容与按钮分发（纯 Dart，有测试）、Android 后台服务、Windows 托盘和开机自启（含对真实注册表的测试）。

详见 [开发计划](docs/开发计划.md)。

## 开发

需要 Flutter（版本见 `.github/workflows/ci.yml` 的 `FLUTTER_VERSION`），Windows 构建需要 Visual Studio 的 C++ 桌面开发工作负载，Android 构建需要 JDK 17 和 Android SDK。

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows        # 或 -d <android 设备>

# 对着真实服务端跑端到端测试（服务端用全新的空数据目录启动）
$env:NYASMS_E2E_URL = "http://127.0.0.1:18080"; flutter test test/e2e
```

- 版本号只在 `VERSION`（`MAJOR.MINOR.PATCH`）。`pubspec.yaml` 必须写成 `version: <VERSION>+<构建号>`，构建号 = `major*1000000 + minor*1000 + patch`（例如 0.1.0 → `+1000`）。`dart run tool/check_version.dart` 会检查这一点，CI 和构建脚本都会调用它。
- Android 包名 `app.nya.smsforward.client`，Windows 程序名 `NyaSmsForward.exe`。

## 打包

```powershell
./scripts/build-release.ps1                 # Windows 安装包 + zip + Android APK，输出到 build/releases
./scripts/build-release.ps1 -SkipAndroid    # 只做 Windows
./scripts/build-release.ps1 -SkipWindows    # 只做 Android
```

Windows 安装包用 [NSIS](https://nsis.sourceforge.io/)（`choco install nsis`），脚本 `installer/nyasmsforward-client.nsi` 必须保持 **UTF-8 带 BOM**（`.editorconfig` 已约束），否则中文字符串会编译失败。

本地不设置签名环境变量时，APK 用 debug 密钥签名，**只能自己试用，不要发布**。

## 发布

推送与 `VERSION` 匹配的标签（如 `v0.1.0`）后，`release` 工作流会校验版本、跑 analyze 和测试，分别构建 Windows（安装包 + 便携 zip）和 Android（已签名 APK），核验后发布到 GitHub Release，每个文件附 `.sha256`。需要配置的仓库 secrets：

```text
ANDROID_KEYSTORE_BASE64    keystore 文件的 base64
ANDROID_KEYSTORE_PASSWORD
ANDROID_KEY_ALIAS
ANDROID_KEY_PASSWORD
```

生成 keystore（**妥善备份**，丢失后无法用同一签名升级已安装的 App；建议与 client-node 使用不同的 keystore）：

```powershell
keytool -genkeypair -v -keystore nyasmsforward-client.keystore -alias nyasmsforward -keyalg RSA -keysize 4096 -validity 10000
[Convert]::ToBase64String([IO.File]::ReadAllBytes("nyasmsforward-client.keystore")) | Set-Clipboard
```

本地签名：设置 `ANDROID_KEYSTORE_FILE`、`ANDROID_KEYSTORE_PASSWORD`、`ANDROID_KEY_ALIAS`、`ANDROID_KEY_PASSWORD`，再运行 `./scripts/build-release.ps1 -SkipWindows -RequireSigned`。

**关于 Windows 签名**：安装包和 exe 目前没有代码签名，Windows SmartScreen 会提示“未知发布者”，选择“更多信息 → 仍要运行”即可。
