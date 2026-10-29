# 安装器过了 `git clone` 之后，还会撞上什么

[English](TROUBLESHOOTING.md) | **简体中文**

[README](README.zh-CN.md) 讲的是「连不上 GitHub」。这一份讲的是**连上之后**的三道坎：
Python 被系统安全策略拦、Electron 二进制下不来、打包工具链下不来。

全部来自 2026-10-29 一台真实机器（Windows 11 25H2 / Build 26200.9711 / 家庭中文版 / AMD64），
每个结论都有日志或命令输出兜着，没有一条是推测。

---

## 症状速查

先按这张表定位，再往下跳。

| 你看到的 | 真凶 | 跳到 |
|---|---|---|
| `bootstrap Python lookup failed` / `exit code: 0xc0e90002` | 智能应用控制（SAC）拦了 `python.exe` | [坑 1](#坑-1智能应用控制拦了-python) |
| `ImportError: DLL load failed while importing unicodedata: 应用程序控制策略已阻止此文件。` | 同上，同一个根因 | [坑 1](#坑-1智能应用控制拦了-python) |
| `electron-runtime: preparing locked Electron 44.9.3 ... TypeError: fetch failed` | Electron 二进制从 GitHub 下不来 | [坑 2](#坑-2electron-二进制下不来) |
| `✗ Packaging the desktop app failed` + `TypeError: fetch failed` | electron-builder 的工具链从 GitHub 下不来 | [坑 3](#坑-3打包工具链下不来而且它不理-electron_mirror) |
| 环境变量配了但没生效 | 安装器进程没重启 | [坑 4](#坑-4环境变量对已经开着的安装器无效) |
| 日志里有 `✓ Install complete!` 但界面显示失败 | 后面还有 publication 阶段 | [坑 5](#坑-5日志会骗你install-complete-之后还有一步) |

---

## 坑 1：智能应用控制拦了 Python

### 症状

`venv` 阶段：

```
-> Downloading Python 3.14
Installed Python 3.14.9 in 6.60s
error: Failed to inspect Python interpreter from managed installations at
  ...\uv\python\cpython-3.14-windows-x86_64-none\python.exe
  cause: Querying Python ... failed with exit status exit code: 0xc0e90002
[X] bootstrap Python lookup failed
```

`python-deps` 阶段（重试一次之后，问题往后挪了一格）：

```
ImportError: DLL load failed while importing unicodedata: 应用程序控制策略已阻止此文件。
```

### 这两条是同一个根因

`0xc0e90002` **不是 Python 的报错**，是进程启动就被代码完整性策略打断。
第一眼看它像「刚解压的 exe 被杀软实时扫描占用」的瞬时故障——我当时就是这么判断的，
还让用户直接点 Retry，**那是错的**。重试只能让症状换个阶段冒出来。

### 确诊（三条命令）

```powershell
# 1. SAC 状态：0=关 1=强制 2=评估
Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -Name VerifiedAndReputablePolicyState

# 2. 谁在拦：看拦截事件里的 Policy ID
Get-WinEvent -LogName "Microsoft-Windows-CodeIntegrity/Operational" -MaxEvents 50 |
  Where-Object { $_.Message -match "Policy ID" } |
  ForEach-Object { [regex]::Match($_.Message, "Policy ID:\{[0-9a-fA-F\-]+\}").Value } |
  Group-Object | Sort-Object Count -Descending

# 3. 活动策略文件
ls "C:\Windows\System32\CodeIntegrity\CiPolicies\Active\"
```

实测结果：

```
VerifiedAndReputablePolicyState = 1        （强制模式）
Policy ID = {0283ac0f-fff1-49ae-ada1-8a933130cad6}  x 35 条事件
C:\Windows\System32\CodeIntegrity\CiPolicies\Active\{0283AC0F-...}.cip  存在
```

`{0283ac0f-...}` 就是 **Smart App Control（智能应用控制）** 的策略 ID。

### 关键事实：它按构建的新旧判定，不是全盘封杀

这是整件事里最反直觉的一点。同一台机器上 6 个 Python 全测了一遍：

| 解释器 | 被拦的模块 |
|---|---|
| workbuddy 3.13.12 | 仅 `_zstd` |
| 系统 3.11.9 | 仅 `_zstd` |
| 系统 3.12.4 | 仅 `_zstd` |
| uv 托管 3.14.9+20261021 | 仅 `_zstd` |
| uv 托管 3.11.15 | 仅 `_zstd` |
| **hermes 工具链 3.14.9+20261021** | **`unicodedata`、`_bz2`、`_zstd`** |

再对比同版本、不同构建日期的两份：

| Python 构建 | 发布日期 | 结果 |
|---|---|---|
| **3.14.7+20260901** | 2026-09-01（两个月前） | **21 个模块全通，零失败**（连 `_zstd` 都过） |
| 3.14.9+20261021 | 2026-10-21（**8 天前**） | `unicodedata` / `_bz2` / `_zstd` 被拦 |

SAC 按**文件哈希 + 云端信誉**判定，没有排除列表、没有白名单。
新构建的 `.pyd` 还没攒够信誉，就被拦。老构建已经被放行了。

> 顺带一个长期问题：`_zstd` 在这台机器**所有** Python 里都被拦，
> 意味着 `compression.zstd`（3.14 新模块）全机不可用。平时没人碰所以没暴露。

### 为什么 Hermes 偏偏中招

Hermes 在 `2026-10-22` 那次提交（`e31fa4cab9`，*fix(deps): update python to 3.14.9*）
把 pin 从 `3.14.7+20260901` 升到了 `3.14.9+20261021`——**就在安装失败前 7 天**。
`v0.22.5` 包含这个提交。

而 `uv.lock` 的约束是 `requires-python = ">=3.11, <3.15"`，
所以 **3.14.7 完全合法，没有被钉死**。

### 两条走不通的路（别重复踩）

**1. 把能加载的 DLL 覆盖过去。** uv 那份 `unicodedata.pyd` 能加载、hermes 那份不能
（同版本、同大小 744960 字节，SHA256 不同）。覆盖后 `import unicodedata` 确实通了，
**但** `hermes\tools\facts.json` 给每个工具链记了树摘要 `digest`，改动被校验出来，
pm 判定 python 需要重装，覆盖当场失效。

**2. 让 Hermes 换个 Python。** `pm/environment.py` 里把
`UV_PYTHON=<自己的工具链>` + `UV_PYTHON_DOWNLOADS="never"` 写死了，
`_base_environment()` 还会主动剥掉所有 `PYTHON*` / `UV_*` 变量。没有官方覆盖开关。

### 能走通的路：换工具链的 Python 树，并重算摘要

关键是搞清楚 pm 怎么校验——不然又会像上面那样白改：

- `pm.store.tree_digest(entry)` 算出整棵树的摘要
- `pm.lock.Facts.installed()` **只校验 `version` / `target` / `artifacts`(sha256) 三项**
- `digest` 是**自记录值**，单独和 `tree_digest` 比对

所以：**只改 `digest` 一个字段就够**，`version` / `target` / `artifacts` 保持不动，
身份校验不会失败。这也解释了为什么只换两个 DLL 会失败、换整棵树 + 重算摘要能过。

一键脚本：[`scripts/fix-sac-python.py`](scripts/fix-sac-python.py)

```powershell
# 必须用 uv 那个被放行的解释器跑（工具链里的可能正被拦着）
& "$env:APPDATA\uv\python\cpython-3.14.7-windows-x86_64-none\python.exe" `
  .\scripts\fix-sac-python.py
```

脚本做的事：备份原树 → 复制 3.14.7 进去 → 用 pm 自己的 `tree_digest()` 重算 →
回写 `facts.json`。**不动 SAC 设置、不动 Hermes 源码、不动 `lock.json`。**

> 源解释器没有的话先装：`uv python install 3.14.7`

### 代价

**`hermes update` 会把 Python 升回 3.14.9，然后一切照旧坏掉。** 脚本是幂等的，重跑一次即可。

长期解法只有两条：等新构建攒够信誉（时间不确定），或者装进 WSL2（Linux 侧没有 SAC）。

### 关于「干脆关掉 SAC」

这台机器的设置页把话说得很死：`评估` 档是灰的（已经自动从评估升级成强制），
`关闭` 下面写着 **「如果智能应用控制已关闭，则在不重新安装 Windows 的情况下无法打开它。」**

微软支持页确实写过「近期更新允许重新开启」，但这台
（26200.9711 + 已装 KB5127648）没吃到那个改动。
**先去设置页确认「开 / 评估 / 关」三个选项点不点得动**——点不动就别关，关了回不来。

---

## 坑 2：Electron 二进制下不来

### 症状

```
electron-runtime: preparing locked Electron 44.9.3 (win32-x64)...
TypeError: fetch failed
```

然后安装器降级成「不带桌面端」继续跑：TUI ✓、Web UI ✓、58 个内置 skill 同步 ✓，
`hermes.exe` 也发布成功了，但 `products` 阶段仍返回 exit 1，界面显示失败。

Electron 运行时 100+ MB，从 GitHub 拉，国内基本拉不动。

### 解法

`scripts/build/electron-runtime.mjs` 会把 `process.env` 原样传给 `install.js`
（只排除 6 个特定键），所以 `ELECTRON_MIRROR` 生效。

```powershell
[Environment]::SetEnvironmentVariable(
  "ELECTRON_MIRROR", "https://npmmirror.com/mirrors/electron/", "User")
```

验证镜像上有货（顺便拿校验值）：

```bash
curl -sIL "https://npmmirror.com/mirrors/electron/44.9.3/electron-v44.9.3-win32-x64.zip" \
  -o /dev/null -w "%{http_code}\n"          # 期望 200
curl -sL "https://npmmirror.com/mirrors/electron/44.9.3/SHASUMS256.txt" | grep win32-x64.zip
```

### 顺带：怎么判断它到底要不要重新下

`prepared()` 只看三样，齐了就直接跳过下载：

- `node_modules/electron/path.txt` 内容等于 `electron.exe`
- `node_modules/electron/dist/version` 内容等于目标版本
- `node_modules/electron/dist/electron.exe` 存在

---

## 坑 3：打包工具链下不来，而且它不理 `ELECTRON_MIRROR`

这是最阴的一个。配好 `ELECTRON_MIRROR` 之后 Electron 本体过了，失败点往后挪了一格：

```
→ Building desktop packaged app…      ✓
→ Packaging the desktop app…
✗ Packaging the desktop app failed
  TypeError: fetch failed
```

### 根因：electron-builder 故意忽略 `ELECTRON_MIRROR`

`node_modules/app-builder-lib/dist/util/electronGet.js` 里有一行注释把话说死了：

```js
// Use resolveAssetURL so @electron/get's ELECTRON_MIRROR env var check cannot override
// the builder-binaries URL we've already resolved (see getArtifactRemoteURL in @electron/get).
const mirrorOptions = { resolveAssetURL: async () => Promise.resolve(fullUrl) };
```

它自己有一套镜像变量，按 `baseUrl + releaseName + "/" + filename` 拼 URL：

```js
export function getBinariesMirrorUrl(githubOrgRepo) {
    for (const envVar of [
        "NPM_CONFIG_ELECTRON_BUILDER_BINARIES_MIRROR",
        "npm_config_electron_builder_binaries_mirror",
        "npm_package_config_electron_builder_binaries_mirror",
        "ELECTRON_BUILDER_BINARIES_MIRROR",
    ]) { /* ... */ }
    return `https://github.com/${githubOrgRepo}/releases/download/`;
}
```

**默认走 GitHub，`ELECTRON_MIRROR` 对它无效。**

### 它要下什么

`app-builder-lib 27.0.0-alpha.6` 在 Windows 上打包需要（配置里没覆盖，走默认 pin）：

| 文件 | 用途 |
|---|---|
| `7zip@1.0.0/7zip-win-x64.tar.gz` | 解压归档 |
| `icons@1.2.1/icons-bundle.tar.gz` | 图标转换 |
| `win-codesign@1.3.0/win-codesign-windows-x64.zip` | 签名工具 |
| `win-codesign@1.3.0/windows-kits-bundle-10_0_26100_0.zip` | `makeappx.exe` / `signtool.exe` |
| `win-codesign@1.3.0/ats-bundle-1_0_95.zip` | ATS 签名 dlib |
| `win-codesign@1.3.0/dotnet-runtime-win-x64-8_0_28.zip` | 配套 .NET 运行时 |
| `win-codesign@1.3.0/rcedit-windows-2_0_0.zip` | 改 PE 资源 |

全部来自 GitHub `electron-userland/electron-builder-binaries` 的 releases。

### 解法

```powershell
[Environment]::SetEnvironmentVariable(
  "ELECTRON_BUILDER_BINARIES_MIRROR",
  "https://npmmirror.com/mirrors/electron-builder-binaries/",
  "User")
```

一键脚本：[`scripts/set-electron-mirror.ps1`](scripts/set-electron-mirror.ps1)（两个变量一起设）。

### 校验值必须对得上，否则白下

electron-builder 源码里硬编码了每个归档的 sha256（`unsafelyDisableChecksums` 在
提供 checksums 时不生效）。所以镜像文件必须**逐位一致**，不是同名就行。

实测两个：

```
icons-bundle.tar.gz   193241afc7c81ab165fa0af15ef0af88f796eb69e8e5bb4249a49310d8be242a  ✓ 一致
7zip-win-x64.tar.gz   be071f15bd6da2f78fe81c6ddef2009b0c4d8a51f36b780cb806c7e6df95e1b3  ✓ 一致
```

自己核验：

```bash
M=https://npmmirror.com/mirrors/electron-builder-binaries
curl -sL "$M/7zip@1.0.0/7zip-win-x64.tar.gz" -o /tmp/a.tgz && sha256sum /tmp/a.tgz
grep -A9 'const checksums' node_modules/app-builder-lib/dist/toolsets/7zip.js
```

### 缓存位置（想手工预热就放这儿）

```
<repo>/.cache/desktop-inputs/packager/
├── builder/          # = ELECTRON_BUILDER_CACHE
│   ├── 7zip@1.0.0/7zip-win-x64.tar.gz
│   ├── icons@1.2.1/icons-bundle.tar.gz
│   └── win-codesign@1.3.0/*.zip
└── electron/         # Electron 归档
```

归档文件放在 `<releaseName>/<filename>`，存在就直接命中、不联网。
所以预热之后，重试这一步**完全不需要网络**。

---

## 坑 4：环境变量对已经开着的安装器无效

这条坑很蠢，但会让人白试好几轮。

`Retry install` 是在**同一个进程**里重跑阶段，环境变量是进程启动时快照的，
**点 Retry 读不到新设的变量**。

必须：**完全关掉安装器窗口 → 重新双击 `Hermes-Setup.exe` → 再点 Retry install。**

判断是否真的重启过：看日志开头的 bootstrap 起始时间，
和 `[bootstrap] downloading install.ps1 ...` 这一行是不是新出现的。

---

## 坑 5：日志会骗你，`Install complete!` 之后还有一步

`products` 阶段失败时，日志里可能已经有：

```
✓ Install complete! [detached @ bf0203a794]
```

因为 `products` 阶段里包含「构建产物」和「发布命令」两件事，
前者成功了就会打这行。**后面还有 publication，它失败时整阶段仍返回 exit 1。**

所以别看到 `Install complete!` 就以为装好了，也别看到 `exit 1` 就以为全废——
先确认 `hermes.exe` 到底发布出来没有：

```powershell
ls "$env:LOCALAPPDATA\hermes\bin\"
Get-Command hermes
```

实测这种情况下 `hermes.exe` / `hermes-acp.exe` 是好的，缺的只是 `apps/desktop/dist`。

### 读日志的正确姿势

日志：`%LOCALAPPDATA%\hermes\logs\bootstrap-installer.log`

```bash
# 只看最后一次运行
awk '/bootstrap starting/{n=NR} {a[NR]=$0} END{for(i=n;i<=NR;i++) print a[i]}' \
  "$LOCALAPPDATA/hermes/logs/bootstrap-installer.log" | tail -80

# 每个阶段的耗时与结果
grep "stage transition" "$LOCALAPPDATA/hermes/logs/bootstrap-installer.log" | tail -20
```

第二条最有价值——它直接告诉你哪个阶段耗时多少、成没成，比翻几百行进度条快。

---

## 排错顺序（省时间版）

1. 看 `stage transition` 那几行，确定死在哪个阶段
2. `repository` → 网络问题，回 [README](README.zh-CN.md)
3. `venv` / `python-deps` → 大概率是 [坑 1](#坑-1智能应用控制拦了-python)，先查 SAC 状态
4. `products` → 先看是不是 `fetch failed`，再看失败在 **electron 本体** 还是 **打包工具链**
   （后者日志里会有 `Packaging the desktop app failed`）
5. 改完环境变量 → **关掉安装器重开**，不是点 Retry

---

## 回滚

```powershell
# 撤销 Python 工具链替换
Move-Item "$env:LOCALAPPDATA\hermes\backup-python-before-sac-fix" `
          "$env:LOCALAPPDATA\hermes\tools\<原 python 目录名>" -Force

# 撤销镜像变量
[Environment]::SetEnvironmentVariable("ELECTRON_MIRROR", $null, "User")
[Environment]::SetEnvironmentVariable("ELECTRON_BUILDER_BINARIES_MIRROR", $null, "User")
```

`facts.json` 的备份是 `facts.json.bak-sac`，换回去再重跑一次 `hermes update` 也能回到官方状态。

---

## 声明

同 [README](README.zh-CN.md)：与 Nous Research 无隶属关系。
以上都是针对特定系统策略和网络环境的绕过方案，不是官方支持的做法。
Hermes Agent 本体是 MIT 协议，问题请以
[`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent) 为准。
