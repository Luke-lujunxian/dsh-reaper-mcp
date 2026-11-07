# dsh-reaper-mcp

在 [DeepSeek Harness](https://github.com/deepseek-ai)（DSH）里驱动 REAPER 的集成层。

上游是 [TwelveTake-Studios/reaper-mcp](https://github.com/TwelveTake-Studios/reaper-mcp)：一个
提供 187 个工具的 REAPER 控制服务（混音、母带、MIDI、路由、自动化、渲染、LUFS/频谱测量），
通过 REAPER 内的 Lua 桥脚本 + 文件邮筒通信，不需要任何网络端口。

**这个仓库不包含上游代码。** 它只装"让这套东西在 DSH 里好用"的那一层：

| 问题 | 本仓库的解法 |
|---|---|
| DSH 没有通用 MCP 客户端插件，stdio MCP server 接不进来 | `rmcp.py` 直接 import 上游的 `reaper_mcp_server.py`，把**工具函数当普通函数调**——同一份代码、同一个邮筒协议，只是省掉 MCP 传输层 |
| 上游桥脚本硬编码邮筒目录，只认 `GetResourcePath()`；而服务端文档却说便携安装用 `REAPER_BRIDGE_DIR` 覆盖，两半不一致 | `apply_bridge_patch.py` 给桥加 4 行，让**两半都认**这个环境变量（不设时行为与上游完全一致） |
| 每次开 REAPER 要手动 Run 一次桥脚本 | 往 `Scripts/__startup.lua` 追加带标记的自启块 |
| 服务端每次都得手动进目录、激活 venv | `install.ps1` / `install.sh` 一次装好，绝对路径调用，**与工作目录无关** |
| 新会话不知道自己有这套能力 | 安装 `~/.dsh/skills/reaper-mcp/SKILL.md`，DSH 的技能目录会自动收录 |

## 架构

```
DSH 会话 ── bash ──► rmcp.py ──import──► reaper_mcp_server.py（上游）
                                            │  写 request_N.json
                                            ▼
                     %APPDATA%\REAPER\Scripts\mcp_bridge_data\
                                            │  REAPER 内 Lua 轮询
                                            ▼
                                      REAPER 工程
```

## 要求

- REAPER（任意较新版本；上游在 7.79 上跑通全量测试）
- Python 3.10+
- git
- Windows（`install.ps1`）或 Git Bash / macOS / Linux（`install.sh`）

## 安装

Windows：

```powershell
git clone https://github.com/<you>/dsh-reaper-mcp.git
cd dsh-reaper-mcp
./install.ps1
```

macOS / Linux / Git Bash：

```bash
git clone https://github.com/<you>/dsh-reaper-mcp.git
cd dsh-reaper-mcp
./install.sh
```

安装脚本做四件事：拉上游 → 打补丁 → 建 venv 装 `mcp` SDK → 部署桥脚本 / JSFX / 自启块 / 技能。
**幂等**，升级直接重跑即可。

常用参数：`-InstallDir` / `$INSTALL_DIR`（默认 `~/.dsh/tools/reaper-mcp`）、`-Ref` / `$REF`（上游分支或 tag）、
`-IndexUrl` / `$INDEX_URL`（默认阿里云镜像）、`-SkipReaper` / `SKIP_REAPER=1`（只装 Python 侧）。

## 验证

REAPER 启动后（首次需要手动加载一次 `Scripts/reaper_mcp_bridge.lua`，之后自启）：

```bash
RM="$HOME/.dsh/tools/reaper-mcp"
"$RM/.venv/Scripts/python.exe" "$RM/rmcp.py" get_project_summary    # Windows
"$RM/.venv/bin/python"         "$RM/rmcp.py" get_project_summary    # macOS / Linux
```

读到你工程的轨道数、BPM、FX 列表就是通了。

## 用法

```bash
PY="$RM/.venv/Scripts/python.exe"      # 或 $RM/.venv/bin/python
"$PY" "$RM/rmcp.py" --list                        # 187 个工具
"$PY" "$RM/rmcp.py" --schema get_track_items      # 看参数（参数名不统一，先查再调）
"$PY" "$RM/rmcp.py" get_track_count
"$PY" "$RM/rmcp.py" insert_track '{"index":0,"name":"Vocals"}'
"$PY" "$RM/rmcp.py" render_project '{"path":"D:/out/mix.wav"}'
```

约定（上游的，照抄不误）：

- 轨道索引 **0 基**，master 用 `-1`
- 每次写操作 = REAPER 里一个 `MCP: <tool>` 撤销步
- 返回 `{"ok": false, "error": ...}` 时看 `error`；`ret` 是 REAPER 原始返回值
- 慢操作（渲染、测量）用 `REAPER_RENDER_TIMEOUT`（默认 600s），普通调用用 `REAPER_FILE_TIMEOUT`（默认 5s）

## 排障

| 现象 | 处理 |
|---|---|
| `CountTracks timed out` | ① REAPER 在跑吗；② Actions 里搜 `mcp bridge` 手动 Run；③ 核对报错里的 `bridge_dir` 与桥启动打印的目录是否一致 |
| 桥报 "another copy is already running" | 上一次的桥还在（REAPER 不重启就一直活着），关掉 REAPER 再开即可 |
| 测量类工具报缺 analyzer | `Scripts/../Effects/TwelveTake/twelvetake_mcp_analyzer.jsfx` 没装到位，重跑安装脚本 |
| 改了桥脚本要生效 | 桥支持热重载：`rmcp.py` 调不到 `ReloadBridge` 时用 `dispatch("ReloadBridge", [])`，或直接重启 REAPER |
| 想换邮筒目录 | 设 `REAPER_BRIDGE_DIR`（REAPER 与服务端都要能看到这个变量），或 `rmcp.py --bridge-dir` |

## 升级

```bash
./install.ps1 -Ref v1.11.0     # 或 ./install.sh（REF=v1.11.0）
```

若上游改动了桥脚本里那行锚点，`apply_bridge_patch.py` 会**明确报错**而不是静默产出坏文件；
看一眼 `patches/bridge-env.patch` 就明白要改哪里。

## 目录

```
rmcp.py                  DSH 侧驱动（唯一真正的"新代码"）
apply_bridge_patch.py    给上游桥脚本加 REAPER_BRIDGE_DIR 支持（幂等）
patches/bridge-env.patch 同一改动的可读 diff，供上游提 issue / PR
install.ps1 / install.sh 一键安装与部署
skill/SKILL.md           装进 ~/.dsh/skills/reaper-mcp 的技能说明
```

## 许可

本仓库的胶水代码：MIT（见 `LICENSE`）。
上游 `reaper-mcp`（server / bridge / JSFX）：MIT，TwelveTake Studios LLC，安装时获取，不在此仓库内。
