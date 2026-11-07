"""Real Windows process-tree cleanup, without registering or running a scheduled task."""
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import subprocess
import sys
import time

import pytest

pytestmark = pytest.mark.skipif(os.name != "nt", reason="Windows job objects")


def ps_literal(path):
    return "'" + str(path).replace("'", "''") + "'"


def test_launcher_death_kills_child_and_grandchild(tmp_path):
    source = Path(__file__).resolve().parents[1]
    child_script = tmp_path / "child.py"
    result_path = tmp_path / "pids.json"
    child_script.write_text(
        "import json,os,subprocess,sys,time\n"
        "p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(120)'], creationflags=0x08000000)\n"
        "with open(sys.argv[1],'w') as f: json.dump([os.getpid(),p.pid],f)\n"
        "time.sleep(120)\n", encoding="utf-8")
    launcher = tmp_path / "launcher.py"
    launcher.write_text(
        "from bg3coop.windows_lifecycle import LauncherLifetime\n"
        "from pathlib import Path\nimport subprocess,sys\n"
        f"lifetime=LauncherLifetime(Path({str(tmp_path)!r}))\n"
        f"p=subprocess.Popen([sys.executable,{str(child_script)!r},{str(result_path)!r}],creationflags=0x08000000)\n"
        "p.wait()\n", encoding="utf-8")
    api = ctypes.WinDLL("kernel32", use_last_error=True)
    api.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    api.OpenProcess.restype = wintypes.HANDLE
    api.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    api.TerminateProcess.argtypes = [wintypes.HANDLE, wintypes.UINT]
    api.CloseHandle.argtypes = [wintypes.HANDLE]
    launcher.write_text("import sys\nsys.path.insert(0," + repr(str(source / "src")) + ")\n" + launcher.read_text(), encoding="utf-8")
    proc = subprocess.Popen([sys._base_executable, str(launcher)],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, creationflags=0x08000000)
    handles = []
    try:
        deadline = time.monotonic() + 20
        while not result_path.exists() and proc.poll() is None and time.monotonic() < deadline:
            time.sleep(0.05)
        assert result_path.exists(), proc.communicate(timeout=5)
        pids = json.loads(result_path.read_text())
        for pid in pids:
            handle = api.OpenProcess(0x100001, False, pid)  # synchronize + terminate our test children
            assert handle
            handles.append(handle)
        proc.kill()  # simulate task scheduler terminating the launcher; never stop a real user task
        proc.wait(timeout=5)
        assert all(api.WaitForSingleObject(h, 5000) == 0 for h in handles)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.wait(timeout=5)
        for handle in handles:
            if api.WaitForSingleObject(handle, 0) != 0:
                api.TerminateProcess(handle, 1)
            api.CloseHandle(handle)


def test_native_process_watch_runs_without_spawning_a_shell(monkeypatch):
    from bg3coop.process_watch import game_running
    def forbidden(*args, **kw):
        raise AssertionError("process watch must not spawn tasklist / PowerShell")
    monkeypatch.setattr(subprocess, "Popen", forbidden)
    assert isinstance(game_running(), bool)


@pytest.mark.parametrize("remove_data", [False, True])
def test_uninstall_only_removes_owned_data_and_disables_before_stop(tmp_path, remove_data):
    source = Path(__file__).resolve().parents[1]
    local = tmp_path / "LocalAppData"
    runtime = local / "BG3Coop"
    notes = runtime / "notes" / "persona.json"
    notes.parent.mkdir(parents=True)
    notes.write_text("original notes")
    game = tmp_path / "game"
    game.mkdir()
    originals = [game / "save.lsv", game / "DWrite.dll", game / "BG3CoopMemory.pak", game / "modsettings.lsx"]
    for path in originals:
        path.write_text("original " + path.name)
    for name in ("enabled", "bridge.json", "tasks.sqlite3", "process-job.ps1"):
        (runtime / name).write_text("runtime")
    trace = tmp_path / "trace.json"
    harness = tmp_path / "uninstall-test.ps1"
    harness.write_text(
        "$ErrorActionPreference='Stop'\n"
        f"$env:LOCALAPPDATA={ps_literal(local)}\n"
        "$global:calls = New-Object 'System.Collections.Generic.List[string]'\n"
        "function Get-ScheduledTask { param($TaskName) return @{TaskName=$TaskName} }\n"
        "function Disable-ScheduledTask { param($TaskName) $global:calls.Add('disable') }\n"
        "function Stop-ScheduledTask { param($TaskName) $global:calls.Add('stop') }\n"
        "function Unregister-ScheduledTask { param($TaskName,[switch]$Confirm) $global:calls.Add('unregister') }\n"
        "function Get-CimInstance { param($ClassName) return @() }\n"
        f"& {ps_literal(source / 'uninstall.ps1')} {'-RemoveData' if remove_data else ''}\n"
        f"ConvertTo-Json -InputObject @($global:calls.ToArray()) | Set-Content -LiteralPath {ps_literal(trace)} -Encoding UTF8\n",
        encoding="utf-8-sig")
    subprocess.run(["powershell.exe", "-NoProfile", "-NonInteractive", "-File", str(harness)],
                   check=True, timeout=20, capture_output=True, creationflags=0x08000000)
    assert json.loads(trace.read_text(encoding="utf-8-sig")) == ["disable", "stop", "unregister"]
    assert not (runtime / "enabled").exists() and not (runtime / "bridge.json").exists()
    assert (runtime / "tasks.sqlite3").exists() is not remove_data
    assert notes.read_text() == "original notes"
    assert all(path.read_text() == "original " + path.name for path in originals)
