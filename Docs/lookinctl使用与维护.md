# lookinctl 使用与维护

`lookinctl` 是面向已集成 LookinServer 的 iOS App 的独立 CLI。它直接连接 LookinServer，不依赖 `Lookin.app`，命令风格尽量贴近 adb，适合在本地调试、自动化脚本、CI 诊断和 Agent 工具链中使用。

## 目标

- 一个命令安装后即可使用，适合通过 npm registry 分发。
- 不依赖 macOS GUI App，不要求启动 `Lookin.app`。
- 覆盖 LookinServer 现有协议能力，不只做层级树或截图的子集。
- 对不可执行的能力给出明确错误，而不是静默失败。
- 保留源码和构建脚本，方便后续继续扩展协议、命令和发布流程。

## 快速命令

```sh
lookinctl help
lookinctl devices
lookinctl -s <target> shell screencap -p -o screen.png
lookinctl -s <target> shell lookin current-vc
lookinctl -s <target> shell uiautomator dump -o hierarchy.json
lookinctl -s <target> shell input hit-test 585 933
lookinctl -s <target> shell input tap 585 933 --dry-run
```

`<target>` 可以是：

- `usb:<deviceID>:<port>`
- `simulator:<port>`
- bundle id，例如 `com.example.app`
- App 名称
- `devices` 输出里的 index

## 典型使用场景

### 1. 无 GUI 采集 App 现场

要解决的问题：线上或本地复现问题时，排查者需要当前页面截图、层级树和页面归因，但不想打开 `Lookin.app`，也不希望依赖人工操作 macOS GUI。

使用能力：

```sh
lookinctl -s <target> shell screencap -p -o screen.png
lookinctl -s <target> shell uiautomator dump -o hierarchy.json
lookinctl -s <target> shell lookin current-vc -o current-vc.json
```

产物价值：

- `screen.png` 说明用户看到的真实页面。
- `hierarchy.json` 说明页面由哪些 View/Layer 组成，以及每个节点的位置、类名、事件和宿主 VC。
- `current-vc.json` 说明当前最可能的业务 View Controller，方便定位归属模块。

适合场景：QA 提 bug、开发远程排查、Agent 自动抓现场、CI 失败后自动保存现场。

### 2. 自动化点击失败定位

要解决的问题：自动化日志只知道某次点击没有生效，但不知道是坐标错、控件被遮挡、点到了容器，还是目标控件本身不支持语义触发。

使用能力：

```sh
lookinctl -s <target> shell input hit-test 585 933 -o hit.json
lookinctl -s <target> shell input tap 585 933 --dry-run -o tap-plan.json
lookinctl -s <target> shell uiautomator dump --max-depth 6 -o hierarchy.json
```

产物价值：

- `hit.json` 给出坐标命中的 top view、候选 view 和命中路径。
- `tap-plan.json` 说明如果执行语义点击会尝试哪个控件，以及不可点击时的 `code`、`reason`、`suggestion`。
- `hierarchy.json` 用来判断是否有全屏浮层、水印、调试面板或透明容器挡住真实控件。

适合场景：UI 自动化 flaky、Agent 需要决定下一步点击哪里、坐标脚本从截图换算后需要验证。

### 3. 判断当前业务页面

要解决的问题：脚本需要知道当前处在哪个页面，但截图 OCR 不稳定，页面标题也可能缺失或被复用。

使用能力：

```sh
lookinctl -s <target> shell lookin current-vc -o current-vc.json
```

产物价值：

- `current` 给出最可能的业务 VC。
- `businessCandidates` 保留其他非 overlay 候选。
- `overlays` 单独列出键盘、调试面板、监控浮层等非业务窗口。

适合场景：自动化断言当前页面、路由跳转验证、异常页面归因、跨团队 bug 分派。

### 4. 排查 UI 展示异常

要解决的问题：页面看起来不对，但无法判断是 frame、hidden、alpha、图片、约束、手势还是自定义属性导致。

使用能力：

```sh
lookinctl -s <target> shell lookin attrs <layer-oid> -o attrs.json
lookinctl -s <target> shell lookin details <oid> --attrs need --basis --subitems -o detail.json
lookinctl -s <target> shell lookin image <image-view-oid> -o image.png
lookinctl -s <target> shell lookin object <oid> -o object.json
```

产物价值：

- `attrs.json` 适合查看 Lookin 属性组和可修改属性。
- `detail.json` 适合查看基础视觉信息、子节点和截图详情。
- `image.png` 可以单独确认 `UIImageView` 当前图片资源。
- `object.json` 适合确认对象类名、地址、ivar trace 和特殊 trace。

适合场景：图片错位、控件不可见、点击区域不对、Debug 属性展示、怀疑对象不是预期类型。

### 5. 快速验证运行时修改假设

要解决的问题：开发想快速验证“隐藏这个 View 是否恢复正常”“关闭某个手势是否解决冲突”“改 alpha 是否能定位遮挡源”，但不想改代码重编。

使用能力：

```sh
lookinctl -s <target> shell lookin set-builtin <oid> setHidden: bool true
lookinctl -s <target> shell lookin set-builtin <oid> setAlpha: float 0.5
lookinctl -s <target> shell lookin recognizer <recognizer-oid> disable
lookinctl -s <target> shell lookin patch <oid> --screenshot group -o patch.json
```

产物价值：

- 直接在 Debug App 运行时修改属性或手势状态。
- `patch.json` 可拉回修改后的截图或节点详情，确认修改是否生效。
- 能把“猜测”快速变成可验证结论。

适合场景：遮挡排查、手势冲突排查、动态样式验证、Lookin 自定义属性调试。

### 6. CI 或 Agent 的 UI 诊断工具

要解决的问题：CI、脚本或 AI Agent 需要稳定读取 App UI 状态，不能依赖肉眼看 `Lookin.app`。

使用能力：

```sh
lookinctl devices --json
lookinctl -s <target> shell lookin app -o app.json
lookinctl -s <target> shell lookin current-vc -o current-vc.json
lookinctl -s <target> shell uiautomator dump -o hierarchy.json
lookinctl -s <target> shell screencap -p -o screen.png
```

产物价值：

- 输出主要是 JSON 和 PNG，方便归档、diff、上传和二次分析。
- 命令形态接近 adb，降低自动化工具接入成本。
- `help` 不需要连接 App，脚本可以先探测能力再执行真实命令。

适合场景：失败自动留档、Agent 观察页面、自动化平台采集 Debug App 状态、无 GUI 机器上的诊断流程。

### 7. 判断是否需要 WDA/XCTest 或 LookinServer 扩展

要解决的问题：团队想用 `lookinctl` 做点击，但需要知道它什么时候足够、什么时候必须引入真正输入注入。

使用能力：

```sh
lookinctl -s <target> shell input hit-test 585 933 -o hit.json
lookinctl -s <target> shell input tap 585 933 --dry-run -o tap-plan.json
lookinctl -s <target> shell input tap 585 933 -o tap-result.json
```

判断方式：

- 如果目标是 `UIControl` 或实现了 `accessibilityActivate`，语义点击通常够用。
- 如果返回 `NO_ACTIONABLE_TARGET`，说明命中了 View 但没有可语义激活目标。
- 如果返回 `ACTION_FAILED`，说明已经尝试触发但目标未成功响应。
- 如果需要完整触摸生命周期、滑动、拖拽、多指手势，应接入 WDA/XCTest 或扩展 LookinServer。

适合场景：评估自动化技术路线、给不可点击失败提供明确原因、决定是否修改 LookinServer。

## 实用 Skills

### 查找命令帮助

`help` 是一级命令，不需要连接 App：

```sh
lookinctl help
lookinctl help devices
lookinctl help shell
lookinctl help shell input
lookinctl help shell lookin
lookinctl help screencap
lookinctl help dump
```

命令级 `--help` 也可用：

```sh
lookinctl devices --help
lookinctl -s <target> shell input --help
```

脚本或 Agent 可以先通过 `help` 探测命令形态，再执行真实连接命令。

### 发现可连接 App

```sh
lookinctl devices
lookinctl devices --json
```

这是所有自动化流程的第一步。脚本应优先使用 `--json`，再按 bundle id 或 appName 匹配目标。

### 当前页面截图

```sh
lookinctl -s <target> shell screencap -p -o screen.png
```

默认使用 LookinServer 图层截图能力，输出接近设备物理像素的高清图，适合做坐标定位。

低清预览图：

```sh
lookinctl -s <target> shell screencap -p --preview -o preview.png
```

### 当前 View Controller

```sh
lookinctl -s <target> shell lookin current-vc
lookinctl -s <target> shell lookin current-vc -o current-vc.json
```

输出会区分：

- `current`: 最可能的业务 View Controller。
- `businessCandidates`: 非 overlay 的候选 VC。
- `overlays`: 键盘、调试面板、监控浮层等 overlay。

这个能力适合做页面归因、异常现场定位、自动化断言。

### 视图层级导出

```sh
lookinctl -s <target> shell uiautomator dump -o hierarchy.json
lookinctl -s <target> shell lookin hierarchy --max-depth 4 -o shallow.json
```

JSON 中包含 view/layer oid、frame、bounds、class chain、事件处理器、宿主 View Controller 和子节点。

### 坐标命中分析

```sh
lookinctl -s <target> shell input hit-test 585 933
lookinctl -s <target> shell input hit-test 195 311 --points
```

`hit-test` 不会触发 UI，只解释某个坐标会命中哪些 View。它适合在点击前排查：

- 坐标是否在目标控件内。
- 是否被水印、调试浮层、全屏容器遮挡。
- 命中的控件是否有可触发事件。

### 语义点击

```sh
lookinctl -s <target> shell input tap 585 933
lookinctl -s <target> shell input tap 585 933 --dry-run
```

这是基于 LookinServer 现有协议实现的尽力而为点击，不是物理 `UITouch` 注入。

执行策略：

- 先从层级树中找到坐标下的候选 View。
- 尽量跳过不可操作的覆盖层。
- 对 `UIControl` 尝试 `sendActionsForControlEvents:UIControlEventTouchUpInside`。
- 对可访问性元素尝试 `accessibilityActivate`。

它通常适合按钮、Switch、部分 Cell 内控件和实现了 accessibility 激活的控件。不适合依赖完整触摸生命周期、自定义手势识别、拖拽、滑动、多指操作的场景。

不可点击时会返回明确 JSON，例如：

```json
{
  "ok": false,
  "code": "NO_ACTIONABLE_TARGET",
  "reason": "Matched views, but none of the candidates is an actionable UIControl and no candidate could be activated semantically.",
  "suggestion": "Run input hit-test on this coordinate, choose a different point inside a UIControl/accessibility element, or add native input support to LookinServer for this custom view."
}
```

常见错误码：

- `NO_HIT`: 坐标下没有命中任何 View。
- `NO_ACTIONABLE_TARGET`: 命中了 View，但没有可语义激活的候选。
- `ACTION_FAILED`: 已尝试触发，但目标返回失败或没有实际动作。
- `HIERARCHY_REQUEST_FAILED`: 拉取层级失败，常见原因是 App 后台、断点、主线程卡住或连接被占用。
- `UNEXPECTED_HIERARCHY_RESPONSE`: 协议响应类型不符合预期。

如果需要真正模拟点击、滑动、拖拽、多指手势，有两个方向：

- 修改 LookinServer 增加原生输入注入能力，再由 `lookinctl` 暴露 adb-like 命令。
- 集成 WDA/XCTest，由独立自动化链路处理物理输入，`lookinctl` 继续负责视图检查和运行时诊断。

### 属性和对象检查

```sh
lookinctl -s <target> shell lookin attrs 1 -o attrs.json
lookinctl -s <target> shell lookin details 1 --attrs need --basis --subitems -o detail.json
lookinctl -s <target> shell lookin object 2 -o object.json
lookinctl -s <target> shell lookin selectors UIViewController -o selectors.json
```

适合定位运行时属性、找 selector、确认 view/layer 对象状态。

### 方法调用

```sh
lookinctl -s <target> shell lookin invoke 2 description
lookinctl -s <target> shell lookin invoke 2 accessibilityActivate
```

LookinServer 当前只支持无参数 selector 调用。有参数方法需要新增专用命令或扩展 LookinServer 协议。

### 图片和运行时修改

```sh
lookinctl -s <target> shell lookin image 1984 -o image.png
lookinctl -s <target> shell lookin set-builtin 123 setHidden: bool true
lookinctl -s <target> shell lookin set-builtin 123 setAlpha: float 0.5
lookinctl -s <target> shell lookin recognizer 456 disable
lookinctl -s <target> shell lookin patch 1 --screenshot group -o patch.json
```

这些能力适合调试图片资源、属性修改影响、手势开关和修改后的截图补丁。

## 协议覆盖

`lookinctl` 覆盖 LookinServer protocol version 7 的请求类型：

- `Ping`
- `App`
- `Hierarchy`
- `HierarchyDetails`
- `AttrModificationPatch`
- `InbuiltAttrModification`
- `CustomAttrModification`
- `InvokeMethod`
- `FetchObject`
- `FetchImageViewImage`
- `ModifyRecognizerEnable`
- `AllAttrGroups`
- `AllSelectorNames`
- `CancelHierarchyDetails`

新增命令时应优先确认它能映射到现有协议。如果现有协议不支持，应在命令输出中明确说明限制，而不是伪装成成功。

## 开发

依赖：

- macOS
- Xcode Command Line Tools
- `git`
- 打包 npm 时需要 `node` 和 `npm`
- 一个已集成 LookinServer 且正在运行的 iOS App

本地开发循环：

```sh
LookinCLI/build.sh
Build/lookinctl/lookinctl --version
Build/lookinctl/lookinctl devices
Build/lookinctl/lookinctl -s <target> shell lookin current-vc
Build/lookinctl/lookinctl -s <target> shell uiautomator dump -o hierarchy.json
```

修改命令时建议同步更新：

- `LookinCLI/README.md`
- 本文档的对应 skill 或维护说明
- `LookinCLI/npm/README.md` 中面向安装用户的说明

## 构建

当前架构：

```sh
LookinCLI/build.sh
```

Universal macOS binary：

```sh
LOOKINCTL_ARCHS="arm64 x86_64" LookinCLI/build.sh
lipo -archs Build/lookinctl/lookinctl
```

本地安装：

```sh
LOOKINCTL_INSTALL_DIR=/usr/local/bin LookinCLI/install.sh
lookinctl --version
```

签名策略：

- 默认 ad-hoc 签名，并执行 `codesign --verify --strict`。
- ad-hoc 签名不依赖证书，也不会因为证书过期失效。
- 本地调试可设置 `LOOKINCTL_CODESIGN=0` 跳过签名。
- 如发布策略需要指定签名 identity，可设置 `LOOKINCTL_CODESIGN_IDENTITY` 和 `LOOKINCTL_CODESIGN_OPTIONS`。

```sh
LOOKINCTL_ARCHS="arm64 x86_64" \
LOOKINCTL_CODESIGN_IDENTITY="<codesign-identity>" \
LOOKINCTL_CODESIGN_OPTIONS="--timestamp --options runtime" \
LookinCLI/build.sh
```

## 发布

生成 npm tarball：

```sh
LOOKINCTL_ARCHS="arm64 x86_64" \
LookinCLI/package-npm.sh --name @your-scope/lookinctl --registry https://npm.example.com
```

发布到 npm registry：

```sh
LOOKINCTL_ARCHS="arm64 x86_64" \
LookinCLI/package-npm.sh \
  --name @your-scope/lookinctl \
  --registry https://npm.example.com \
  --publish
```

推荐流程：

1. 本地构建 universal binary。
2. 用已连接 App 做 `devices`、`current-vc`、`uiautomator dump`、`screencap` 冒烟验证。
3. 生成 npm tarball。
4. 用 `tar -tf Build/lookinctl-npm/tarballs/*.tgz` 检查产物。
5. 发布到 npm registry。
6. 在干净机器上执行 `npm install -g` 验证安装和启动。

`LookinCLI/ci-publish.example.yml` 提供了 macOS CI runner 的发布模板。

### npm 产物目录

npm 模板和生成产物使用固定目录，方便 CI、上传脚本和单独的包仓库稳定消费：

```text
LookinCLI/npm/                       npm package 源码模板，提交进仓库。
Build/lookinctl-npm/package/         每次打包生成的 package staging 目录。
Build/lookinctl-npm/tarballs/        每次打包生成的可安装 .tgz。
Build/lookinctl-npm/manifest.json    给 CI/上传脚本读取的产物元信息。
```

`package-npm.sh` 每次运行都会清理并重建 `Build/lookinctl-npm/package/` 和 `Build/lookinctl-npm/tarballs/`，因此这两个目录只表示最近一次打包结果。

`manifest.json` 示例：

```json
{
  "packageName": "@your-scope/lookinctl",
  "packageVersion": "0.2.0",
  "archs": ["x86_64", "arm64"],
  "prebuildDir": "darwin-universal",
  "packageDir": "/path/to/Lookin/Build/lookinctl-npm/package",
  "tarball": "/path/to/Lookin/Build/lookinctl-npm/tarballs/your-scope-lookinctl-0.2.0.tgz",
  "nativeBinary": "/path/to/Lookin/Build/lookinctl/lookinctl",
  "registry": "https://npm.example.com"
}
```

产物消费约定：

- 发布 npm 时读取 `Build/lookinctl-npm/tarballs/*.tgz` 或 `manifest.json` 的 `tarball` 字段。
- 如果要把 npm 包源码单独推到包仓库，应该推 `LookinCLI/npm/` 模板和相关构建脚本，而不是推 `Build/` 产物。
- 如果要归档某次发布的安装包，只归档 `Build/lookinctl-npm/tarballs/` 和 `manifest.json`。

## 目录结构设计

```text
LookinCLI/
  README.md                  CLI 使用、开发、构建和发布入口。
  main.m                     独立 CLI 主实现。
  build.sh                   原生构建脚本。
  install.sh                 本地或源码安装脚本。
  package-npm.sh             npm 打包和发布脚本。
  ci-publish.example.yml     CI 发布模板。
  npm/
    package.json             npm package 模板。
    README.md                npm 包内 README。
    .npmrc.example           registry 配置示例。
    bin/lookinctl.js         Node 包装器，负责找到并执行原生 binary。
    scripts/postinstall.js   安装后 chmod、清理 quarantine、校验签名。
```

生成目录：

```text
Build/lookinctl/                    原生构建产物和临时依赖源码。
Build/lookinctl-npm/package/        npm package staging 目录。
Build/lookinctl-npm/tarballs/       npm tarball 目录。
Build/lookinctl-npm/manifest.json   npm 产物元信息。
```

职责边界：

- `main.m`: 命令解析、连接选择、协议请求、响应格式化、adb-like 命令和语义点击策略。
- `build.sh`: 依赖发现、LookinServer 源码拉取、架构构建、链接、签名验证。
- `package-npm.sh`: 构建 binary、准备 npm staging、生成 tarball、可选发布。
- `npm/bin/lookinctl.js`: 保持轻量，只负责选择 binary、处理执行权限、清理 quarantine、透传参数。
- `Docs/`: 放长期设计和维护文档，避免 README 变成过长的实现说明。

## 适用和不适用场景

适用：

- 本地快速定位当前页面和视图层级。
- 自动化失败后抓现场信息。
- Agent 或脚本需要获取 App UI 状态。
- 调试工具需要无需 GUI 的 Lookin 能力。
- 需要通过 npm 分发一个统一命令。

不适用：

- Release/App Store 包集成 LookinServer。
- 对物理触摸事件完整性有要求的自动化。
- 需要滑动、拖拽、多指手势、系统级事件注入的场景。
- App 卡死、后台或 LookinServer 未启动时的实时检查。

## 维护约定

- 新增能力时优先保持 adb-like 命令形态。
- 命令输出需要同时照顾人读和机器读，复杂结果优先支持 `--json` 或 `-o`。
- 不支持的能力必须返回明确 code、reason 和 suggestion。
- 不把 `Build/` 产物提交进源码仓库。
- npm 包可以包含构建产物，但源码仓库必须保留可修改的 CLI 源码和脚本。
