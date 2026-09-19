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

**M0 脚手架已完成**：Windows 和 Android 都能构建、测试、打包发布；界面目前只有“连接到服务器”页（校验输入，实际配对从 M2 开始）。已经落地并有测试的逻辑：

- `lib/src/api/server_url.dart`：服务器地址校验（必须 https，仅 localhost / 局域网可用 http）。
- `lib/src/api/connection.dart`：“什么情况才算令牌失效”的严格判定和重连退避（协议 §2.2）。
- `lib/src/api/protocol.dart`：下发策略、客户端权限（scopes）、错误码。
- `lib/src/pairing/`：令牌存储（Android Keystore / Windows 凭据管理器）和连接页外壳。

以上与 client-node 共用同一批测试用例，保证两个 App 的判断一致。详见 [开发计划](docs/开发计划.md)。

## 开发

需要 Flutter（版本见 `.github/workflows/ci.yml` 的 `FLUTTER_VERSION`），Windows 构建需要 Visual Studio 的 C++ 桌面开发工作负载，Android 构建需要 JDK 17 和 Android SDK。

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows        # 或 -d <android 设备>
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
