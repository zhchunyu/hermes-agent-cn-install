# Hermes Agent 国内安装指南

[English](README.md) | **简体中文**

针对中国大陆网络环境安装 [Nous Research Hermes Agent](https://hermes-agent.nousresearch.com) 的实测方案。
核心场景：官方桌面端安装器卡在 `git clone` 阶段，报 `Failed to connect to github.com port 443`。

本仓库所有命令和镜像数据均在真实机器上执行并测量（Windows 11 25H2 / Build 26200 / AMD64，**2026-10-29**）。
不是从博客抄的。

---

## 一、问题长什么样

官方桌面端安装器启动后，先下载 `install.ps1`（这一步通常能成功，`raw.githubusercontent.com`
和 `api.github.com` 多数网络可达），紧接着执行：

```bash
git clone --filter=blob:none --branch main \
  https://github.com/NousResearch/hermes-agent.git
```

这一步需要 `github.com:443`。国内多数网络下它 DNS 能解析、TCP 连不上；而系统级 HTTP 代理
往往对 `github.com` 单独返回 `502`，其他域名却放行。

安装器重试三次后停在：

```
INSTALL DIDN'T FINISH
git clone failed; no checkout published:
fatal: unable to access 'https://github.com/NousResearch/hermes-agent.git/':
Failed to connect to github.com port 443 after 2279 ms: Could not connect to server
```

日志位置：`C:\Users\<你>\AppData\Local\hermes\logs\bootstrap-installer.log`

---

## 二、快速解决

用 git 的传输层 URL 重写，把**这一个仓库**指向可用镜像。不改 hosts、不配代理、不需要管理员权限。

```bash
git config --global \
  'url.https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git.insteadOf' \
  'https://github.com/NousResearch/hermes-agent.git'
```

然后回安装器窗口点 **Retry install**。

**为什么不用重启安装器**：重写发生在 git 传输层，而 git 是安装器拉起的子进程，
每次调用都重新读磁盘上的 `~/.gitconfig`。配置写完，点 Retry 立即生效。

### 先验证再重试

不想反复试错的话，先单独确认重写生效：

```bash
git ls-remote --heads https://github.com/NousResearch/hermes-agent.git main
```

打印出一串 SHA 就是通了。打印 `fatal: unable to access` 说明没生效。

一键脚本在 [`scripts/`](scripts/)：`setup-git-mirror.ps1`（Windows）、`setup-git-mirror.sh`（macOS / Linux / WSL）。

### 点 Retry 之后的预期

| 阶段 | 耗时 | 说明 |
|---|---|---|
| `repository`（git clone） | 3–10 分钟 | 约 400 MB 工作树，界面会像卡死，**别关** |
| `venv` + `python-deps` | 2–8 分钟 | 从 PyPI 拉依赖，见下面第 3 条 |
| `products` + `setup` | 1–2 分钟 | 需要填模型 API key |

---

## 三、镜像实测

用 `git ls-remote` 探测（最省流量的可靠探针）。**合格必须同时满足两条**：

1. `main` 的 SHA **等于** `api.github.com/repos/NousResearch/hermes-agent/commits/main` 返回的 `sha`
2. `git ls-remote --tags --refs <镜像> | wc -l` **大于 0**，且目标 tag 在列

> 第 2 条最容易漏。安装器解析稳定版 `v0.22.5` 后会执行
> `git fetch origin +refs/tags/v0.22.5:refs/tags/v0.22.5`。
> **只同步分支、不同步 tag 的镜像，会在 clone 看似成功之后才失败**，报错更难看懂。

| 镜像 | 结果 | 具体情况 |
|---|---|---|
| **`gh-proxy.com`** | ✅ **可用** | `main` SHA 与官方一致，221 个 tag 含 `v0.22.5` |
| `gitclone.com` | ⚠️ 不可用 | `main` 滞后；**tag 数为 0**，fetch tag 必失败 |
| `ghfast.top` | ❌ | HTTP 403 |
| `ghproxy.net` | ❌ | `expected flush after ref listing`（响应被截断） |
| `kkgithub.com` | ❌ | TLS `SEC_E_WRONG_PRINCIPAL`，证书域名不匹配 |
| `ghproxy.cc` | ❌ | TLS `SEC_E_CERT_EXPIRED`，证书过期 |
| `hub.gitmirror.com` | ❌ | DNS 解析失败 |
| `github.moeyy.xyz` | ❌ | DNS 解析失败 |
| `gitdl.cn` | ❌ | DNS 解析失败 |
| `gh.llkk.cc` | ❌ | 返回空 |

### IP 直连兜底

镜像全挂时，可以试直接连 GitHub 的 IP（`curl --resolve` 实测）：

| IP | 结果 |
|---|---|
| `140.82.112.3` | ✅ HTTP 200 |
| `20.205.243.166` | ✅ HTTP 200 |
| `140.82.121.4` | ❌ 超时 |
| `20.27.177.113` | ❌ 超时 |

这需要改 hosts 文件（要管理员权限），**只在最后没办法时用**，改系统文件前先确认风险。

---

## 四、这些办法为什么不行

**从 `codeload.github.com` 下 tarball。** 拿到的是源码快照，没有 `.git` 目录。
安装器要的是带历史和 tag 的 git 仓库，快照会让版本钉选和 `hermes update` 全部失效。

**设 `HERMES_REPO_URL`。** 这个环境变量确实能覆盖 clone 地址，但有副作用：
`install.ps1` 里 `Get-StableTarget` 只在 origin 匹配
`^https://github\.com/NousResearch/hermes-agent(\.git)?/?$` 时才按官方源处理。
换成任何别的 URL，它会跳过稳定版解析、直接跟随 `main`。你丢掉了钉选版本，
而且 `hermes update` 会继承这个非官方 remote。除非你就是想跟 main，否则别用。

**`git config --global http.proxy`。** 如果你的系统代理对 `github.com` 返回 `502`
（按域名白名单放行的代理都是这样），让 git 走它没有任何区别。

**去 GitHub Releases 找安装包。** 没有。`NousResearch/hermes-agent` 的 releases
**资产数为 0**，只有源码 tag。Windows 的 `Hermes-Setup.exe` 和 macOS 的 `Hermes-Setup.dmg`
只存在于 `hermes-assets.nousresearch.com`。

---

## 五、国内用户会遇到的其他问题

下面这些是 **clone 成功之后**才会暴露的，按遇到顺序排列。

### 1. Windows 安装包只有 7.9 MB

`Hermes-Setup.exe` 是引导安装器（`apps/bootstrap-installer`），不是完整程序。
运行时才下载真正的 runtime。这个下载卡住的话，安装器报错信息很含糊。
心理预期：总共要跑几百 MB 流量。

### 2. `hermes-assets.nousresearch.com` 能连但很慢

实测约 200 KB/s。这个域名能解析、能下载，只是没为国内做优化。
**不要因为慢就以为它被墙**——它是通的。

### 3. PyPI 慢或超时

`python-deps` 阶段要从 PyPI 拉整棵依赖树。重试安装器**之前**先把 pip 换成国内源，
否则 venv 阶段会磨到超时：

```bash
pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
pip config set global.trusted-host pypi.tuna.tsinghua.edu.cn
```

安装器自带独立 Python，如果它的 pip 不读你的用户配置，改用环境变量 `PIP_INDEX_URL`。

### 4. npm 慢（仅源码构建）

只有自己从源码构建 Electron 桌面端才相关。换国内 registry：

```bash
npm config set registry https://registry.npmmirror.com
```

### 5. MSIX 打包与 SmartScreen

Windows 桌面端以 MSIX 分发，要求 **Windows 11 22H2（Build 22621）及以上**，更老的系统直接装不上。
首次启动会有 SmartScreen 提示。包由 `Nous Research Inc.`（微软 ID 验证证书）签名，
点"更多信息 → 仍要运行"是安全的——但下载来源可疑时，自己验签：

```powershell
Get-AuthenticodeSignature .\Hermes-Setup.exe | Format-List Status, SignerCertificate
```

`Status` 应为 `Valid`，`Subject` 应为 `CN=Nous Research Inc.`。

### 6. 模型 API 才是真正的拦路虎

Hermes 本身不带模型。装完必须配 provider，而多数境外端点在国内容易抽风。现实选项：

- Hermes 原生支持的国内厂商：Kimi / Moonshot、z.ai GLM、MiniMax、小米 MiMo
- 或者用 OpenAI 兼容的中转服务接境外模型

**这是"技术上都装好了但用不了"的高发环节**，建议安装前就把 key 准备好。

### 7. Telegram / Discord / Slack 网关

gateway 进程直连这些平台。没有可用线路时连不上，但 CLI 和本地桌面 UI 不受影响。

### 8. `--filter=blob:none` 要求代理真的转发 git 协议

partial clone 不是普通 HTTP 文件下载。只缓存 release 附件、不做 git smart-HTTP 反向代理的
镜像，会在这里挂掉。`gh-proxy.com` 是支持的。

### 9. Windows 长路径

安装器传了 `--long-paths`，但 `core.longpaths` 也得在系统级打开，否则深层路径 checkout 失败：

```bash
git config --global core.longpaths true
```

---

## 六、回滚

这是持久的全局 git 配置，撤销命令：

```bash
git config --global --unset \
  'url.https://gh-proxy.com/https://github.com/NousResearch/hermes-agent.git.insteadOf'
```

改之前先备份 `~/.gitconfig`——`scripts/` 里的脚本会自动备份成 `~/.gitconfig.bak-<时间戳>`。

**建议留着**：下次 `hermes update` 还会撞同一堵墙。

---

## 七、自己复测镜像

镜像状态变化很快，表格只代表 2026-10-29 那一次测量。某个镜像挂了不代表方法失效，按这两条重测：

```bash
# 官方最新 main SHA
curl -s https://api.github.com/repos/NousResearch/hermes-agent/commits/main | grep '"sha"' | head -1

# 候选镜像的 main SHA 与 tag 数
git ls-remote --heads "https://<镜像>/https://github.com/NousResearch/hermes-agent.git" main
git ls-remote --tags --refs "https://<镜像>/https://github.com/NousResearch/hermes-agent.git" | wc -l
```

两条都过，才值得配 `insteadOf`。

---

## 声明

本仓库记录的是针对网络环境的绕过方案，与 Nous Research **无任何隶属、背书或支持关系**。
Hermes Agent 本身是 MIT 协议，仓库在 [`NousResearch/hermes-agent`](https://github.com/NousResearch/hermes-agent)，
软件本体、官方文档和技术支持请以那里为准。
