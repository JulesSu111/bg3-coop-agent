这是个人用的一个适配codex的版本，使用一个笨办法修正了游戏内agent框不会主动响应的问题，并加入了控制token用量的回合限制机制，可通过config文件夹内的json修改。
不保证兼容性，不建议使用，我确实没想到更好的方法。
## Windows 本地无人值守模式
新增登录后台启动、游戏内交互和事件驱动 Codex 控制器。安装、配置、架构及实机验收清单见 [Windows 使用说明](docs/windows-local.md)。

## 主角控制模式
目前新增一个实验性的主角控制模式，移除了原项目对操纵主角的限制并新增部分相应适配。

以下是原readme：



# bg3-coop-agent

中文 | [English](README.en.md)

和 AI agent 一起玩《博德之门3》：你在前台操控自己的主角，agent 在后台操控一名队友。支持两人解除链接，各自探索、各自对话，战斗时轮流行动。

agent 不会动你的鼠标和键盘，不占用你的前台和屏幕视野。它通过 Script Extender 的调试端口，在游戏里用脚本控制自己的角色，并且只能看到它这个角色看得见的东西。

## 组成

- 注入到游戏里的 Lua 脚本：负责感知和行动，不需要装 mod。
- 一个可选 mod：将 agent 需要的游玩记录数据一起保存进存档，防止读档时记忆错乱或丢失。
- MCP 服务器：把游戏操作包装成 agent 可以调用的工具，游玩守则也写在里面。支持 Claude Code、Codex 和 DeepSeek Harness。
- `bg3coop` 命令：`setup` 配置游戏，`doctor` 检查一切是否就绪。

测试过的版本：游戏 4.1.1.7631656（DirectX 11），Script Extender v33。

## 安装

游戏和 agent 装在同一台 Windows 电脑上。下面的命令用 [uv](https://docs.astral.sh/uv/)（最省事）；没有 uv 或想用自己的 Python 环境（3.10 以上），见[安装说明](docs/install-for-agents.md)。

**最省事的办法**：对你的 agent 说「按 https://github.com/IgnatAi401/bg3-coop-agent/blob/main/docs/install-for-agents.md 帮我装好 BG3 Co-op」，它会一步步带你安装。想自己装的话：

1. 下载 Script Extender（[Norbyte/bg3se](https://github.com/Norbyte/bg3se/releases)），把 `DWrite.dll` 放进游戏的 `bin` 目录，例如 `D:\SteamLibrary\steamapps\common\Baldurs Gate 3\bin`。
2. 关掉游戏，在 PowerShell 里运行：

   ```powershell
   uvx --from https://github.com/IgnatAi401/bg3-coop-agent/releases/download/v0.1.1/bg3coop-0.1.1-py3-none-any.whl bg3coop setup
   ```

   `setup` 会从 Steam 找到游戏，在 `bin` 目录写好 `ScriptExtenderSettings.json`（打开 Lua 调试端口 9998，原有设置保留），并检查 `DWrite.dll`。找不到游戏时用 `--game-dir` 指定安装目录。

   它还会装一个小 mod「BG3 Co-op Memory」：放进 `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods`，并在 `modsettings.lsx` 里启用（原文件备份为 `modsettings.lsx.bg3coop-backup`）。这个 mod 只记录队伍走过的地方和 agent 的剧情笔记，存在存档里。游戏退出时会改写 mod 列表，所以要在游戏关着时运行 `setup`。

   这个 mod 是可选的，不想装就在命令末尾加上 `--no-mod`。这样 `setup` 不会碰 Mods 文件夹和 `modsettings.lsx`，开着游戏也能运行。不装 mod 时其他功能照常，但是记忆不再跟随存档，存档读档时可能导致 agent 记忆错乱，`doctor` 也会给一条提醒（WARN），可以忽略。装了 mod 以后存的档会把它列为所需 mod，之后再卸掉 mod，读这些档时游戏会提示缺少 mod。

3. 把它接到你的 agent 上（三选一）：

   - **Claude Code**：在 Claude Code 里输入

     ```
     /plugin marketplace add IgnatAi401/bg3-coop-agent
     /plugin install bg3coop@bg3-coop-agent
     ```

   - **Codex**：在终端运行

     ```powershell
     codex plugin marketplace add IgnatAi401/bg3-coop-agent
     codex plugin add bg3coop@bg3-coop-agent
     ```

   - **DeepSeek Harness**：在 dsh 的「插件」页点「添加插件」，填入下面的地址后安装并启用；或者在终端运行 `dsh plugin add` 加上这个地址（不是默认 profile 时加 `--profile <名字>`）。

     ```
     https://github.com/IgnatAi401/bg3-coop-agent/releases/download/v0.1.1/dsh-bg3coop-0.1.1.tgz
     ```

   三个插件都用 uv 启动 MCP 服务器；没有 uv 时让 agent 按安装说明换别的方式。

<details>
<summary>从源码运行（开发者）</summary>

```powershell
git clone https://github.com/IgnatAi401/bg3-coop-agent
cd bg3-coop-agent
uv sync
uv run bg3coop setup
cd play
claude
```

`play/` 里的 `.mcp.json` 让 Claude Code 直接用这份源码启动 MCP 服务器。

</details>

## 更新

有新版时，`doctor` 和 agent 都会提醒你。插件和程序一起发版，更新插件就会换成新版程序：

- **Claude Code**：在 Claude Code 里输入 `/plugin marketplace update bg3-coop-agent`。也可以在 `/plugin` 的 Marketplaces 里选中它，打开 Enable auto-update，以后自动更新。
- **Codex**：在终端运行 `codex plugin marketplace upgrade bg3-coop-agent`。
- **DeepSeek Harness**：用新版本的地址再装一次（把上面地址里的两处版本号换成新的），会直接覆盖旧版。

然后重启 agent（或开个新会话），关掉游戏再运行一次 `setup`（命令里的版本号也换成新的），让 Memory mod 也更新。没装 mod 的话，照样加上 `--no-mod`，开着游戏运行也行。不是用插件装的，按[安装说明](docs/install-for-agents.md)末尾更新。

## 开始一局

1. 启动游戏（Script Extender 首次启动时会自动下载），读取存档，确保想交给 agent 的队友在队伍里。启动时可能弹出「游戏文件损坏」之类的提示，这是装了 Script Extender 和 mod 后的常见现象，一般可以无视，直接继续。
2. 运行检查（可选）：

   ```powershell
   uvx --from https://github.com/IgnatAi401/bg3-coop-agent/releases/download/v0.1.1/bg3coop-0.1.1-py3-none-any.whl bg3coop doctor
   ```

   每一行都是 `OK` 就可以开始。`FAIL` 那一行会写明要怎么改。游戏一次只接受一个连接，agent 正连着游戏时 `doctor` 会提示这一点，并跳过剩下的检查。

3. 开一个新的 agent 会话，对它说「开始玩，你控制影心」。agent 会先接管并解除这名队友的链接，然后开始自己探索。

## 一起玩时要知道的

> [!IMPORTANT]
> **模型能力很关键。** 下面这些功能能否正常发挥，都取决于 agent 能否读懂规则、调对工具。BG3 规则繁多，自由度极高，每次判断都要综合大量信息，模型越强，配合越顺畅，建议使用能力更强的模型。
>
> **确认 agent 读过游玩守则。** 守则随 MCP 服务器下发，但有的客户端不会把它交给模型，这时 agent 要自己调用 `rules` 工具才能看到。如果 agent 不按规矩来（比如替你点对话、在你的回合里行动、不在面板里回话），对它说一句「先调用 `rules` 看看游玩守则」。

- **agent 做不到的事**：其他事 agent 基本都能自己做（探索、对话和检定、战斗和施法、使用物品、换装备、交易、回营地和传送等），下面这些目前无法做到：
  - 开锁、解除陷阱
  - 扒窃 NPC
  - 开局创建角色
  - 升级加点
  - 炼金和物品合成
  - 用夺心魔蝌蚪解锁能力
  - 短休和长休
  - 进入回合制模式
  - 存档、读档
- **对话**：BG3 一次只有一个对话界面，显示在你的屏幕上。agent 的角色发起的对话由 agent 选择回答，你也可以直接替它点。你的对话 agent 不会碰。
- **战斗**：回合制下轮到 agent 的角色时，镜头会切过去，等它行动完并结束回合即可。轮到你时它会等待。agent 施法会正常消耗动作、附赠动作和法术位。如果你和 agent 的先攻相邻（共享回合），它结束后游戏仍显示共享回合，你结束自己的部分即可。
- **营地和传送点**：agent 可以自己回营地、离开营地，或传送到解锁过的、当前地图上的传送点。解除链接时只有它的角色会传送，你和你的队伍留在原地。战斗中或对话中不能用。
- **反应**：接管后，agent 角色不耗法术位的反应（如守御闪光、借机攻击）会自动使用，耗法术位的默认不用，你的屏幕上不会再弹它的反应询问框。可以让 agent 用 `reactions` 调整，`regroup` 时恢复原设置。
- **聊天面板**：agent 开始工作后，游戏里会出现一个「BG3 合作」小窗，按 `F10` 显示或隐藏；agent 发来消息时面板会自动打开。重启游戏或读档后，面板要等 agent 下一次行动才会回来；如果一直没出现，对 agent 说一句「面板不见了」。
  - 标题栏显示 agent 接管的角色。agent 发来新消息时标题栏会闪几下，然后一直显示「N 条新消息」，直到你把鼠标移到面板上、点输入框或发消息。
  - 标题下面一行实时显示 agent 在做什么：「施法 火焰箭 → 地精 · 3 秒」表示动作正在进行；「思考中 · 20 秒 · 上一步：…」表示它在想下一步；两分钟没有动作会提示它可能停下了。战斗中轮到 agent 时，还会显示它有没有收到回合（「轮到影心了 · 还没收到（8 秒）」或「影心的回合 · 已收到」）。
  - 「聊天」页是对话；「动作记录」页列出 agent 最近做过的事，最新的在最下面，失败的标红。
  - 四个快捷按钮：跟上我、停下、等我、自由行动。
  - 在输入框里打字、回车发送，agent 下次调用工具时就会看到；它的回复也显示在这里。在输入框里打字不会触发游戏按键。
  - agent 拿不准时会提问，问题下面有 Yes / No 按钮，也可以直接打字回答；一段时间不回答，它会自己继续。
  - 面板关着时，agent 的留言会强制面板打开。
- **指给 agent 看**：用鼠标中键单击一个角色、物品或地面，agent 就知道你指的是什么（按住中键拖动仍是转视角，不算）。接着在面板里说「打这个」「去那里」「把这个捡起来」即可。
- **只有 agent 在持续行动时才会读到消息**：它每次调用工具都会顺带看一眼面板。如果它在 agent 那边停下来等你回话，游戏里的消息就收不到。可以设置让它一直循环：Claude Code 可以用 `/loop`，dsh 可以用 goal 或 ralph 模式；或强调没事干时调用 `wait` 而不是停下来。
- **弹窗**：遇到紧急情况，agent 会额外弹一个消息框，每分钟最多一次。
- **你的主角**：默认是你自己创建的主角。你点选、切换到其他角色（包括 agent 的角色）不会改变这一点；如果想指定别人，开局时告诉 agent。
- **探索记忆**：agent 会优先去队伍还没去过的方向。走过的地方由 BG3 Co-op Memory mod 记在存档里，没连 agent 时也照记，读哪个档就是那个档当时的记录，不同存档互不影响。装 mod 之前走过的地方不算。这个 mod 是可选的（`setup --no-mod` 不装）：没装时，agent 只记得这次读档以后走过的地方，目标和剧情笔记也会在读档时清空。装了这个 mod 后存的档会把它列为所需 mod。
- **agent 的笔记**：agent 会把长期目标、答应过的事、重要地点记成笔记，这些存在存档里，读旧档就回到那时的样子。它给自己定的角色设定和你的偏好存在本机 `%LOCALAPPDATA%\bg3coop\notes`，每个周目一个文件，读档不会忘。更新 bg3coop 后如果 `doctor` 提示 mod 版本旧了，关掉游戏再运行一次 `setup`（见上面的「更新」）。
- **查 wiki**：agent 可以用 `wiki` 查 [bg3.wiki](https://bg3.wiki)（英文），了解法术、物品、敌人的机制和抗性。任务解法、谜题答案和剧情走向不会主动查，避免剧透。电脑网络环境要能够访问这个网站，访问不了时 agent 照常游玩。
- 读档后游戏里的 Lua 状态会清空，MCP 服务器会自动重新注入脚本，并重新接管同一名队友。

## 工具一览

| 工具 | 作用 |
| --- | --- |
| `rules` | 游玩守则（dsh 不会自动把它交给 agent，agent 自己读） |
| `party` / `set_agent` / `regroup` | 查看队伍、接管队友、重新链接 |
| `status` / `look` / `spells` | 角色状态、视野内（约 22 米）的人和物和还没去过的方向、今天能用的行动和法术 |
| `prepare` | 更换准备的法术（战斗外，不超过游戏给的上限） |
| `reactions` | 查看和设置反应：自动使用、不用、询问人类 |
| `move` / `use` / `talk` | 走动、使用物体（门、箱子、拉杆）、对话 |
| `sneak` / `sight` | 潜行和停止潜行；查看附近的人朝哪看、视野锥多大、谁看得见自己，以及没人看着的位置。潜行时 `move` 会避开别人的视野锥 |
| `container` / `take` | 查看并拿取身边容器里的物品 |
| `inventory` / `use_item` / `equip` / `give` | 查看背包和装备、喝药水或读卷轴、换装备、把物品交给你（或其他队友） |
| `throw` | 扔东西：背包里的投掷物、武器，地上的物品，甚至角色 |
| `trade` | 和商人买卖（用游戏自己的交易窗口和价格）。每次先在聊天面板问你同意，再问你要一起交易（窗口在你屏幕上打开）还是让它自己在后台交易（窗口藏起来，你的屏幕照常） |
| `travel` | 回营地或离开营地、用已解锁的传送点快速旅行（只有 agent 自己过去） |
| `combat` / `examine` | 先攻顺序、各人 HP 和状态、上回合以来发生了什么；查看敌人的 AC、抗性和特性 |
| `cast` / `end_turn` | 攻击或施法（可升环）、结束回合 |
| `dialogue` / `choose` / `roll` | 读取并回答自己角色的对话，替自己的检定掷骰（你能看到骰子） |
| `wait` / `job_status` / `stop` | 等待游戏事件、继续等长动作、停下 |
| `quests` | 读游戏任务日志里进行中的任务 |
| `wiki` | 查 [bg3.wiki](https://bg3.wiki)（英文）：法术、物品、敌人的机制。需要游戏电脑能访问这个网站，网络不通时 agent 照常玩，只是查不了 |
| `notes` | agent 自己的笔记：目标、经历、地点（存进存档），角色设定和你的偏好（存在本机） |
| `say` / `ask` | 在聊天面板里给你留言，紧急时加弹窗；向你提是非题并等回答 |

## 许可证

MIT，见 [LICENSE](LICENSE)。

