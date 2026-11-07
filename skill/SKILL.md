---
name: reaper-mcp
description: 在 REAPER（DAW）上做实际混音/母带/MIDI/渲染/测量操作。需要读或改用户的 REAPER 工程、加 FX 与调参、写 MIDI、做侧链与总线、导出音频、测 LUFS/真峰值/频谱/立体声时加载。能力来自本地 TwelveTake REAPER MCP（187 个工具），经文件桥接驱动，REAPER 侧的桥脚本已装成开机自启。
---

# REAPER 控制（TwelveTake REAPER MCP）

工具全局安装在这里，**与工作目录无关**，任何会话/工作区都直接可用：

    C:\Users\Luke_lu\.dsh\tools\reaper-mcp\

调用模板（bash / pwsh 都行）：

```bash
RM="C:/Users/Luke_lu/.dsh/tools/reaper-mcp"
"$RM/.venv/Scripts/python.exe" "$RM/rmcp.py" <tool_name> '<json args>'
```

## 先摸清再动手

```bash
"$RM/.venv/Scripts/python.exe" "$RM/rmcp.py" --list                    # 187 个工具
"$RM/.venv/Scripts/python.exe" "$RM/rmcp.py" --schema get_track_items  # 看参数名
"$RM/.venv/Scripts/python.exe" "$RM/rmcp.py" get_project_summary       # 一次拿全工程
```

**参数名不完全统一**（例如 `get_track_items` 要 `track_index` 而不是 `track`），先 `--schema` 再调，比试错快。

## 硬约定

- 轨道索引 0 基；master 用 `-1`
- `item_index` / `take_index` / `fx_index` 都是各自父级内的序号
- 每次写操作在 REAPER 里对应**一个** `MCP: <tool>` 撤销步，Ctrl+Z 一次退一步
- 返回 `{"ok": false, "error": ...}` 时看 error；`ret` 是 REAPER 原始返回值
- 慢操作（`render_project` / `measure_loudness` / `measure_spectrum`）用 `REAPER_RENDER_TIMEOUT`（默认 600s），普通调用用 `REAPER_FILE_TIMEOUT`（默认 5s）

## 前提与排障

| 环节 | 位置 |
|---|---|
| 桥脚本（REAPER 内 Lua） | `%APPDATA%\REAPER\Scripts\reaper_mcp_bridge.lua` |
| 开机自启 | `%APPDATA%\REAPER\Scripts\__startup.lua` 里的 `<<< DSH reaper-mcp bridge autostart >>>` 块 |
| 邮筒（请求/响应 JSON） | `%APPDATA%\REAPER\Scripts\mcp_bridge_data` |
| 测量用 JSFX | `%APPDATA%\REAPER\Effects\TwelveTake\twelvetake_mcp_analyzer.jsfx` |

- 报 `timed out`：① REAPER 在不在运行；② 在 Actions 里搜 `mcp bridge` 手动 Run；③ 核对报错里的 `bridge_dir` 与桥启动时打印的目录是否一致
- 桥支持热重载：`ReloadBridge` 让它重新 `loadfile` 自己，改完 lua 不用重启 REAPER
- 邮筒目录可用 `REAPER_BRIDGE_DIR`（桥和服务端都认）或 `rmcp.py --bridge-dir` 覆盖

## 安全

改用户工程前先 `get_project_summary` 看清状态；批量/破坏性操作前跟用户确认；别在用户的正式工程上做试写。
