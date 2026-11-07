# bg3-coop-agent

[中文](README.md) | English

Play Baldur's Gate 3 together with an AI agent: you control your own main character, and the agent controls one companion (Shadowheart, say) in the background. The two of you can unchain, explore and talk to people on your own, and take turns in combat.

The agent never touches your mouse or keyboard, and does not take over your window or your view of the screen. It controls its character with scripts in the game through the Script Extender's debugger port, and it only sees what its own character can see.

## What is in it

- Lua scripts injected into the game: they perceive and act. No mod needed for them.
- An optional mod: it keeps the play records the agent needs inside your saves, so its memory does not get mixed up or lost when you load.
- An MCP server: it wraps game actions as tools an agent can call, and carries the rules for playing alongside you. Works with Claude Code, Codex and DeepSeek Harness.
- The `bg3coop` command: `setup` configures the game, `doctor` checks that everything is ready.

Tested with game 4.1.1.7631656 (DirectX 11) and Script Extender v33.

## Installing

The game and the agent run on the same Windows PC. The commands below use [uv](https://docs.astral.sh/uv/) (easiest); without uv, or to use your own Python environment (3.10 or newer), see the [install guide](docs/install-for-agents.md).

**Easiest**: tell your agent "Install BG3 Co-op following https://github.com/IgnatAi401/bg3-coop-agent/blob/main/docs/install-for-agents.md" and it walks you through it. To do it yourself:

1. Download the Script Extender ([Norbyte/bg3se](https://github.com/Norbyte/bg3se/releases)) and put `DWrite.dll` into the game's `bin` folder, for example `D:\SteamLibrary\steamapps\common\Baldurs Gate 3\bin`.
2. Close the game and run in PowerShell:

   ```powershell
   uvx --from https://github.com/IgnatAi401/bg3-coop-agent/releases/download/v0.1.1/bg3coop-0.1.1-py3-none-any.whl bg3coop setup
   ```

   `setup` finds the game through Steam, writes `ScriptExtenderSettings.json` into `bin` (turning on the Lua debugger port 9998 and keeping your other settings) and checks `DWrite.dll`. If it cannot find the game, pass the install folder with `--game-dir`.

   It also installs a small mod, "BG3 Co-op Memory": it goes into `%LOCALAPPDATA%\Larian Studios\Baldur's Gate 3\Mods` and is turned on in `modsettings.lsx` (the original is backed up as `modsettings.lsx.bg3coop-backup`). The mod only records where the party has been and the agent's story notes, inside your save. The game rewrites its mod list when it exits, so run `setup` while the game is closed.

   The mod is optional: add `--no-mod` to the end of the command to skip it. `setup` then leaves the Mods folder and `modsettings.lsx` alone, and can run while the game is open. Everything else works without the mod, but the agent's memory no longer follows your saves, so saving and loading can leave it confused; `doctor` shows a WARN about it that you can ignore. Saves made with the mod list it as required, so if you remove the mod later, the game will say it is missing when you load those saves.

3. Connect it to your agent (pick one):

   - **Claude Code**: in Claude Code, enter

     ```
     /plugin marketplace add IgnatAi401/bg3-coop-agent
     /plugin install bg3coop@bg3-coop-agent
     ```

   - **Codex**: in a terminal, run

     ```powershell
     codex plugin marketplace add IgnatAi401/bg3-coop-agent
     codex plugin add bg3coop@bg3-coop-agent
     ```

   - **DeepSeek Harness**: on dsh's Plugins page, choose "Add plugin", paste the address below, then install and enable it; or run `dsh plugin add` with that address in a terminal (add `--profile <name>` for a profile other than the default).

     ```
     https://github.com/IgnatAi401/bg3-coop-agent/releases/download/v0.1.1/dsh-bg3coop-0.1.1.tgz
     ```

   All three plugins start the MCP server with uv; without uv, ask your agent to follow the install guide another way.

<details>
<summary>Running from source (developers)</summary>

```powershell
git clone https://github.com/IgnatAi401/bg3-coop-agent
cd bg3-coop-agent
uv sync
uv run bg3coop setup
cd play
claude
```

The `.mcp.json` in `play/` makes Claude Code start the MCP server from this checkout.

</details>

## Updating

`doctor` and the agent tell you when a new release is out. The plugins and the program are released together, so updating the plugin also moves you to the new program:

- **Claude Code**: in Claude Code, enter `/plugin marketplace update bg3-coop-agent`. Or select it under Marketplaces in `/plugin` and choose Enable auto-update to get updates automatically.
- **Codex**: in a terminal, run `codex plugin marketplace upgrade bg3-coop-agent`.
- **DeepSeek Harness**: install again from the new release's address (change both version numbers in the address above); it replaces the old version.

Then restart the agent (or start a new session), close the game and run `setup` again (with the new version in the command) so the Memory mod is updated too. If you skipped the mod, add `--no-mod` again; then the game can stay open. If you did not install with a plugin, see the end of the [install guide](docs/install-for-agents.md).

## Starting a session

1. Start the game (the Script Extender downloads its runtime on the first start), load a save, and make sure the companion you want to hand to the agent is in the party. The game may warn that game files are corrupted or similar on startup; with the Script Extender and mods installed this is common and can usually be ignored.
2. Run the check (optional):

   ```powershell
   uvx --from https://github.com/IgnatAi401/bg3-coop-agent/releases/download/v0.1.1/bg3coop-0.1.1-py3-none-any.whl bg3coop doctor
   ```

   When every line says `OK` you are ready. A `FAIL` line says what to change. The game takes one connection at a time: while an agent is connected to it, `doctor` says so and skips the remaining checks.

3. Open a new agent session and say "Start playing, you control Shadowheart". The agent takes over that companion, unchains it and starts exploring.

## Playing together

> [!IMPORTANT]
> **The model matters.** Everything below works only as well as the agent understands the rules and calls the right tools. BG3 has many rules and gives you a great deal of freedom, and each decision weighs a lot of information, so a stronger model plays noticeably better. Use the most capable model you can.
>
> **Make sure the agent has read the play rules.** The rules come with the MCP server, but some clients do not pass them to the model; then the agent only sees them by calling the `rules` tool. If the agent does not play by them (clicking your dialogue, acting on your turn, not answering in the panel), tell it: "call `rules` and read the play rules first".

- **What the agent cannot do**: it can do almost everything else on its own (explore, talk and roll checks, fight and cast spells, use items, change equipment, trade, go to camp and fast-travel), but for now it cannot:
  - pick locks or disarm traps
  - pickpocket NPCs
  - create a character at the start of the game
  - level up
  - use alchemy or combine items
  - unlock powers with illithid tadpoles
  - take a short or long rest
  - enter turn-based mode
  - save or load the game
- **Dialogue**: BG3 shows one dialogue at a time, on your screen. The agent answers the dialogues its character starts; you can also click an answer for it. It does not touch yours.
- **Combat**: in turn-based combat the camera moves to the agent's character on its turn; wait until it acts and ends its turn. It waits during yours. The agent's spells use up actions, bonus actions and spell slots as usual. If your initiatives are next to each other (a shared turn), the game still shows the shared turn after the agent is done; end your part.
- **Camp and waypoints**: the agent can go to camp, leave camp, or travel to waypoints on the current map that it has unlocked. Only its character goes; you and your party stay. Not during combat or dialogue.
- **Reactions**: after taking over, the agent's character uses reactions that cost no spell slot (Warding Flare, opportunity attacks) automatically and skips those that do; you no longer get its reaction prompts on your screen. The agent can change this with `reactions`; `regroup` restores the original settings.
- **Chat panel**: once the agent is working, a "BG3 Co-op" window appears in the game; `F10` shows or hides it, and it opens by itself when the agent writes to you. After a restart or loading a save the panel comes back with the agent's next action; if it does not, tell the agent "the panel is gone".
  - The title bar shows the character the agent plays. A new message from the agent makes it blink, then it keeps saying "N new" until you move the mouse over the panel, click the input box or send something.
  - The line under the title is live: "casting Fire Bolt → Goblin · 3s" while an action runs, "Thinking · 20s · after: …" while the agent decides, and a warning that it may have stopped after two minutes without an action. In combat it also shows whether the agent has got its turn ("Shadowheart's turn · not received yet (8s)" or "Shadowheart's turn · received").
  - The Chat tab holds the conversation; the Actions tab lists what the agent did lately, newest at the bottom, failures in red.
  - Four quick buttons: Follow me, Stop, Wait for me, Free roam.
  - Type in the box and press Enter; the agent sees it with its next tool call, and its replies appear here. Typing in the box does not trigger game keys.
  - When the agent is unsure it asks; answer with the Yes / No buttons or type a reply. If you do not answer for a while it carries on.
  - While the panel is closed, a message from the agent opens it.
- **Pointing**: middle-click a character, item or spot on the ground and the agent knows what you mean (holding the middle button and dragging still rotates the camera). Then say "attack this", "go there" or "pick this up" in the panel.
- **The agent only reads messages while it keeps acting**: it checks the panel with every tool call. If it stops on its side to wait for you, it does not get messages from the game. You can set it up to keep going: Claude Code's `/loop`, dsh's goal or ralph mode; or tell it to call `wait` instead of stopping when it has nothing to do.
- **Pop-ups**: in an emergency the agent also opens a message box, at most once a minute.
- **Your character**: by default your custom main character. Selecting or switching to other characters (the agent's included) does not change that; if you want someone else, tell the agent at the start.
- **Exploration memory**: the agent prefers directions the party has not been yet. The BG3 Co-op Memory mod records where you have been inside the save, even without the agent connected; each save has its own record from when it was made. Places visited before the mod was installed do not count. The mod is optional (`setup --no-mod` skips it): without it, the agent only remembers where it has been since the last load, and its goal and story notes are wiped on each load too. Saves made with the mod list it as required.
- **The agent's notes**: the agent writes down long-term goals, promises and important places; these live in the save, so loading an older save brings back the notes from then. The persona it plays and your preferences are kept on this PC in `%LOCALAPPDATA%\bg3coop\notes`, one file per playthrough, and survive loading. If `doctor` says the mod is out of date after an update, close the game and run `setup` again (see Updating).
- **Wiki lookups**: the agent can use `wiki` to look things up on [bg3.wiki](https://bg3.wiki): how spells, items and enemies work, their resistances. It does not look up quest solutions, puzzle answers or where the story goes on its own, so nothing gets spoiled. The game PC must be able to reach the site; if it cannot, the agent plays on, just without lookups.
- Loading a save clears the Lua state in the game; the MCP server injects the scripts again and takes over the same companion.

## Tools

| Tool | What it does |
| --- | --- |
| `rules` | The rules for playing alongside the human (dsh does not pass them to the agent, so it reads them here) |
| `party` / `set_agent` / `regroup` | See the party, take over a companion, chain back |
| `status` / `look` / `spells` | Character status; people and things in view (about 22 m) and unexplored directions; actions and spells available today |
| `prepare` | Change prepared spells (out of combat, within the game's limit) |
| `reactions` | See and set reactions: use automatically, never, or ask the human |
| `move` / `use` / `talk` | Walk, use objects (doors, chests, levers), talk to people |
| `sneak` / `sight` | Sneak or stop sneaking; see which way people nearby look, their view cones, who can see it, and spots nobody watches. While sneaking, `move` keeps out of their view |
| `container` / `take` | Look into and take from containers nearby |
| `inventory` / `use_item` / `equip` / `give` | Backpack and equipment, drink potions or read scrolls, change equipment, hand items to you (or another companion) |
| `throw` | Throw things: throwables and weapons from the backpack, items on the ground, even characters |
| `trade` | Buy and sell with merchants, through the game's own trade window and prices. It first asks you in the chat panel whether it may, then whether to trade together (the window opens on your screen) or leave it to the agent (the window stays hidden and your screen stays as it is) |
| `travel` | Go to or leave camp, fast-travel to unlocked waypoints (only the agent goes) |
| `combat` / `examine` | Initiative order, everyone's HP and conditions, what happened since its last turn; an enemy's AC, resistances and traits |
| `cast` / `end_turn` | Attack or cast (upcasting too), end the turn |
| `dialogue` / `choose` / `roll` | Read and answer its own character's dialogue, roll its own checks (you see the dice) |
| `wait` / `job_status` / `stop` | Wait for game events, keep waiting on long actions, stop |
| `quests` | Open quests from the game's journal |
| `wiki` | Look things up on [bg3.wiki](https://bg3.wiki): what spells, items and enemies do. The game PC must be able to reach the site; without it the agent plays on, just without lookups |
| `notes` | The agent's own notes: goals, story, places (in the save), persona and your preferences (on this PC) |
| `say` / `ask` | Leave you a message in the chat panel (with a pop-up when urgent); ask a yes/no question and wait for the answer |

## License

MIT, see [LICENSE](LICENSE).

## Windows unattended local mode

See the [Windows setup and acceptance guide](docs/windows-local.md) for the event-driven background controller, installer, and in-game controls. Real BG3 and OAuth end-to-end operation has not yet been tested.
