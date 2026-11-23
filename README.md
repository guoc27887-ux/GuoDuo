<p align="center">
  <img src="docs/brand/app-icon.png" width="128" alt="GuoDuo icon">
</p>

<h1 align="center">GuoDuo</h1>

<p align="center">原生 SwiftUI 的红果短剧客户端，适配 iPhone Duo 折叠屏、iPad 与普通 iPhone。开源免费，非官方。</p>

红果短剧官方 App 在折叠屏内屏、iPad 上不适配，所以有了它。界面和播放全部原生（SwiftUI + AVPlayer），取源核心用 JavaScriptCore 运行上游 [jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama)（GPL-3.0）。播放器手势、弹幕、折叠屏布局沿用姊妹项目 [DouDuo](https://github.com/81199000/DouDuo)。

> ⭐ **点个 Star，再关注 [@81199000](https://github.com/81199000)，避免走失。** 官网 **[oneduo.app](https://oneduo.app)** 是长期固定入口，以后仓库再搬家也能从官网找到。

## 同系列项目

- **[DouDuo](https://github.com/81199000/DouDuo)**：第三方抖音客户端，原生 SwiftUI，适配折叠屏内屏 / iPad，推荐、评论、私信、直播都能用。
- **[GuoDuo](https://github.com/81199000/GuoDuo)**（本项目）：红果短剧第三方客户端，原生播放，适配折叠屏内屏 / iPad，支持弹幕和选集。
- **[一键签 OneDuo](https://github.com/81199000/OneDuo)**：Windows / Mac 装机工具，用自己的 Apple ID 免费把上面这些 App 签名装到手机，到期自动续签、有新版自动更新。
- 官网 **[oneduo.app](https://oneduo.app)**：三个项目的统一下载入口。

## 功能

**推荐**
- 打开 App 后台先备好几部，点进推荐直接放本地文件；竖滑一屏一部，每部只放第 1 集
- 看过的会记住，下次不再推荐同一集；第 1 集都看完了改从第 2 集推荐
- 喜欢就点「全集」进这部剧的详情页

**发现 / 搜索**
- 红果 / 西饭 / 河马片源，热播榜、真人剧、漫剧、AI 剧分类，题材筛选
- 粘贴红果分享链接直达

**播放**
- 竖滑切集、横滑快进快退（带预览）、长按加速、倍速、画中画
- 弹幕、本集热评（前 5 集）、极简模式、听书模式（退出后继续出声，默认关）

**折叠屏 / iPad**
- 桌面半折：上视频、下半屏操作台（滑动快进 / 上下切换、弹幕、环境光投影）
- 书本半折：左视频、右侧常驻选集
- 横屏：右侧液态玻璃标签栏，评论从右侧滑出

**我的**
- 继续观看、收藏：外面一排，点「全部」看完整列表
- 扫码登录红果账号同步云端观看记录、储存空间管理
- 检查更新：启动时自动检查新版本（oneduo.app）并显示更新内容

每个版本的改动见 [更新说明](docs/releases/) 或 [GitHub Releases](https://github.com/81199000/GuoDuo/releases)。

## 下载安装

支持 iOS / iPadOS **18.4 及以上**。GuoDuo 未上架 App Store，安装包是**未签名 IPA**，需要签名后安装。两种方式：

| | 方式一：一键签（推荐） | 方式二：全能签 + 软件源 |
| --- | --- | --- |
| 花钱吗 | 免费（用自己的 Apple ID） | 要买证书 |
| 要电脑吗 | 要（Windows / Mac） | 不要，全程在手机上 |
| 有效期 | 7 天，**自动续签** | 跟证书走，一般 1 年 |
| 更新新版 | 自动装上 | 软件源里点一下，签名安装 |

### 方式一：一键签（免费，自动续签）

1. 到官网 **[oneduo.app](https://oneduo.app)** 下载 [一键签](https://oneduo.app/#download)（Windows / Mac）
2. 数据线连手机，在一键签里选 **GuoDuo**，点 **一键安装**
3. 手机上 **设置 → 通用 → VPN 与设备管理** 信任你的 Apple ID

详细步骤见 [一键签使用教程](https://github.com/81199000/OneDuo#使用教程)。

> 更新也在一键签里完成：有新版会自动装上，观看记录和收藏会保留。

### 方式二：全能签 + GuoDuo 软件源（手机上安装和更新）

[全能签](https://sign.drnrt8.cn/sign/)是手机上的签名工具：导入证书后，在 App 里就能下载、签名、安装，**不用电脑**。

> **全能签本身免费，但必须有证书才能用。** 顺序是「先有证书 → 再装全能签」。

#### 1. 买证书

两种渠道：**全能签官网买兑换码**（证书和全能签一起装好，适合新手），或 **淘宝 / 闲鱼买证书**（便宜些，拿到 `.p12` + `.mobileprovision` + 密码）。

买之前先拿到手机的 **UDID**：用 **Safari** 打开 [全能签官网](https://sign.drnrt8.cn/sign/) 点「获取 UDID」，按提示安装描述文件。

![全能签官网获取 UDID：设置里安装描述文件](docs/install/qnq/01-udid-profile.png)

<sub>图片来自[全能签官网](https://sign.drnrt8.cn/sign/)安装页教程。</sub>

#### 2. 安装全能签

- **兑换码**：在 [全能签官网](https://sign.drnrt8.cn/sign/) 输入兑换码 →「立即安装」。
- **自己的证书**：在官网点「我有证书 ｜ 自助安装」，上传 `.p12` 和 `.mobileprovision`，填密码 →「签名安装」。

装好后在 **设置 → 通用 → VPN 与设备管理** 信任证书；再打开 **设置 → 隐私与安全性 → 开发者模式**，按提示重启。

![打开开发者模式](docs/install/qnq/02-developer-mode.png)

<sub>图片来自[全能签官网](https://sign.drnrt8.cn/sign/)安装页教程。</sub>

#### 3. 把证书导入全能签

全能签 → **设置 → 导入文件**，选 `.p12` 和 `.mobileprovision`（或证书 zip 包），输入密码。在 **证书** 页看到状态有效即可。

#### 4. 添加软件源，签名安装

全能签 → **资源 → 软件源** → 右上角添加：

| 软件源 | 地址 |
| --- | --- |
| 官方源（推荐，国内可用） | `https://dl.oneduo.app/guoduo/guoduo.json` |
| GitHub | `https://raw.githubusercontent.com/81199000/GuoDuo/main/docs/source/guoduo-github.json` |

在源里点 GuoDuo → 下载 → **资源 → App** 里点它 → **签名** → **安装**。以后有新版，在源里下拉刷新再装一次，会覆盖旧版，观看记录和收藏保留。

> ⚠️ 买来的证书可能被苹果吊销（「掉签」），掉签后 App 打不开，只能换证书重签。买之前问清楚掉签补不补。不要用网上流传的免费 / 共享证书。

## 常见问题

- **打开就闪退**：签名过期了。一键签：点「立即全部续签」；全能签：看证书是否失效（掉签），换证书重签
- **某部剧放不了**：部分集数只有 ByteVC2 编码，iOS 不支持；或在红果需要解锁
- **推荐 / 取源全部失败**：红果接口变了，等上游修复后更新 GuoDuo
- **占用空间大**：「我的 → 储存空间 → 清理缓存」

## 构建

需要 Xcode 26 以上、Node.js 和 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
git clone https://github.com/81199000/GuoDuo.git && cd GuoDuo
brew install xcodegen
cd core && npm ci && node build.cjs && cd ..
xcodegen generate
xcodebuild -project HongGuo.xcodeproj -scheme HongGuo -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO
```

## 目录结构

- `core/upstream/`：从上游 `src/native/` 拷贝的签名 / 设备注册 / 目录 / 搜索 / 取源模块（`public.js` 来自 `android/web/`，只改了 transport 路径），上游版本见 `core/UPSTREAM_COMMIT`
- `core/shims/`：Node 内置模块在 JSC 里的替身（沿用上游安卓版的 Native 桥约定）
- `core/entry.js`：导出 `HG.browse / search / episodes / source` 给 Swift
- `HongGuo/Core/HGCore.swift`：JSContext 宿主 + Native.*（网络、AES、摘要、gzip、计时器）
- `HongGuo/Core/HGCencDecryptor.swift`：CENC AES-CTR MP4 解密，对照上游 `decryptMp4Buffer` 逐字节一致
- `HongGuo/Player`、`HongGuo/Storage`：播放器手势、弹幕、环境光、储存管理，改自 [DouDuo](https://github.com/81199000/DouDuo)（MIT）

## 同步上游

上游 jackotom/hongguo-drama 更新由脚本自动同步：

```sh
python3 scripts/upstream_sync.py --check   # 只看上游有没有更新、改了哪些我们用的文件
python3 scripts/upstream_sync.py           # 同步 → 打本地补丁 → 构建核心 → 实测取源 → 本地提交
```

- 用到的上游文件和本地改动都登记在脚本里的 `FILES` / `PATCHES`。改了上游文件的本地写法，**必须同步登记到 `PATCHES`**，否则下次同步会被上游原文覆盖。
- 补丁打不上（上游改到同一处）或实测取源成功率低于 80%，脚本自动还原、不提交，交给人看。
- `scripts/upstream_watch.sh --release` 由定时任务每小时跑一次：上游有更新就同步 → 实测 → 实测通过直接发版（补丁版本号 +1、自动写更新说明、跑 release.sh），结果通知维护者；冲突或实测不过就停下报人，不发版。

## 发版（维护者）

1. 升 `project.yml` 的 `MARKETING_VERSION`
2. 写 `docs/releases/v<版本>.md`（App 内更新弹窗直接显示它的内容）
3. 提交并推送后运行 `./release.sh`：编译未签名 IPA，发布 GitHub Release，并同步 oneduo.app 软件源

## 致谢与许可

- 取源核心：[jackotom/hongguo-drama](https://github.com/jackotom/hongguo-drama)（GPL-3.0）及其上游 woshishiq1/drpys、N3urda/hongguoTV、tsukiyo-zero/hongguoTV、charlie901208/HGTV 等贡献者，详见 [NOTICE](NOTICE) 与各文件头部
- 播放器与折叠屏布局：[DouDuo](https://github.com/81199000/DouDuo)（MIT）
- 本项目以 [GPL-3.0](LICENSE) 协议开源；你可以自由使用、修改和再分发，但衍生作品同样须以 GPL-3.0 开源

## 免责声明

> 本声明说明项目意图与边界，**不构成法律意见，也不能免除法律责任**。

GuoDuo 是非官方客户端，与红果短剧 / 字节跳动、西饭、河马及任何内容方**没有任何隶属、合作或授权关系**，不存储、不提供任何视频内容，片源均来自各平台接口。接口未公开，随时可能失效；不支持 ByteVC2 编码的集数。仅供个人学习研究使用，请勿用于商业用途或传播，所有商标归各自权利人所有。

仓库和软件源只提供**未签名 IPA**，由使用者用 [一键签](https://oneduo.app)（自己的 Apple ID）或自备证书签名安装。本项目**不出售、不提供任何证书**，与全能签及各证书卖家无合作关系；证书来源、掉签等风险由使用者自行判断。请勿分发已签名安装包。
