# 安装前资源与停用机制检查

检查日期：2026-11-07。本次**没有执行安装、注册计划任务、操作真实 BG3 或启动真实 Codex 模型**。保留 Windows 登录任务自动启动方案，优化了该任务运行的常驻程序。

## 检查结果与修复

| 场景/机制 | 原实现问题 | 当前行为 |
| --- | --- | --- |
| BG3 未启动 | 每秒创建 `tasklist` 子进程 | 每 30 秒使用原生 Toolhelp 快照；不初始化 Lua/面板、App Server 或模型 |
| 主菜单 | 检测周期过短 | 默认每 5 秒探测存档状态，模型回合为零 |
| 初次载入、等待且无消息 | 载入事件会启动一次模型 | 本地初始化，无模型回合；仅新聊天触发回应 |
| 等我 | 游戏事件仍会唤醒，确认消息也需模型 | 停当前动作/回合并关闭 App Server；确认由本地显示；战斗/对话不唤醒，新聊天可以回复 |
| 停下 | 需明确区分等待与暂停 | 取消待处理任务、中断回合、关闭 App Server、尝试停止游戏动作；暂停期间不调度新模型 |
| 自由行动 | 可无限自动接续回合 | 增加小时预算、连续自主回合、玩家空闲、高频熔断，触发后需人工继续 |
| 模型错误 | `willRetry=true` 可能在单轮内部自动重试 | 立即撤销任务权限、终止 App Server 并显示原始错误，停止自动重试 |
| 待机内存 | 常驻 PowerShell/CLR 较大 | 登录任务直接运行原生 `pythonw.exe` 监督器，首次需要工具前不导入 MCP 栈 |
| 强制停止 | 不能仅依赖 PowerShell 的 finally 清理子进程 | 监督器在启动子进程前将自身加入 kill-on-close Job Object；禁用 breakaway |
| 反复异常 | 启动器可无限重启 | 5 分钟内守护失败 5 次停止；监督器配置/Job 错误记日志后停止；任务自身失败重启最多 3 次 |
| 卸载 | `-RemoveData` 递归根目录可能删掉原有大小写等价路径下的笔记 | 改为已知运行文件白名单；保留笔记、未知文件、游戏和 Mod 文件 |

默认保护：滚动一小时 30 个 `turn/start` 尝试；连续自主/事件回合 6 个；面板无活动 300 秒暂停自主；30 秒窗口最多 4 个回合；App Server 无回合闲置 60 秒关闭。恢复和重启不清空小时/高频历史。保护计数不是 Plus 剩余额度或 token 预算。

## 本机待机测量

用临时配置及无效 Codex 路径进行 30 秒隔离测量，计入监督器**全部后代进程和 Windows Python 重定向器**，未使用任何真实模型。

| 指标 | 样本值 |
| --- | --- |
| 采样时间 | 30 秒 |
| 进程数（含重定向器） | 4 |
| 合计 CPU 时间 | 0.1094 秒 |
| 单核 CPU 比例 | 0.365% |
| 合计工作集 | 75.18 MB |
| 合计私有内存 | 40.48 MB |
| 守护日志 / 重启日志大小 | 0 / 0 字节 |

这是本机短时样本，不是所有机器或长时间运行的性能保证。工作集可能重复计入共享 DLL 页；游玩后工具栈已加载时内存可高于冷启动。未做主动工作集裁剪来美化结果。测量脚本：[profile-standby.ps1](../scripts/profile-standby.ps1)。此脚本不安装或注册服务。

## 停止、禁用、卸载的边界

- `Stop-ScheduledTask` 停当前任务实例。任务直接启动持有 Job handle 的**原生基础 Python**，避免杀到 venv redirector 却留下实际监督器；父进程退出后 Windows 负责终止整个 Job。该 Job 行为已用本机真实隔离父/子/孙进程测试。
- `Disable-ScheduledTask` 禁止后续登录触发，**不会停止当前实例**。要立即停止且禁止下次登录运行，应先 Disable 再 Stop。恢复需要 Enable，立即运行另用 Start。
- 未注册临时或生产计划任务，因此实际 `Stop-ScheduledTask`/`Disable-ScheduledTask` 调度器链路仍属待安装后实测。测试中仅模拟调度器强杀监督器的效果。
- 卸载测试 mock 了计划任务命令，验证 disable → stop → unregister 顺序；测试文件中的 `.lsv`、`DWrite.dll`、Memory `.pak`、`modsettings.lsx` 及原有笔记均保留。没有运行针对当前用户真实安装目录的卸载操作。

依据：[Microsoft Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)、[Stop-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/stop-scheduledtask)、[Disable-ScheduledTask](https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/disable-scheduledtask)、[官方 Codex App Server 错误协议](https://learn.chatgpt.com/docs/app-server)。

配置项、命令和实机验收步骤见 [Windows 使用说明](windows-local.md)。

本轮验证：完整回归 **238 passed**；最后的本地控制器、额度保护、协议、监督器与 Windows 生命周期定向回归 **36 passed**。PowerShell 语法、Python 编译检查及 `git diff --check` 通过。真实 BG3 面板、真实 Plus 错误和安装后的任务计划链路仍未实测。
