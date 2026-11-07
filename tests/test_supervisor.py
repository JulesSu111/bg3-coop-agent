import logging
from types import SimpleNamespace

from bg3coop import supervisor


def test_repeated_crashes_stop_instead_of_restart_forever(tmp_path, monkeypatch, caplog):
    (tmp_path / "enabled").touch()
    launched = []
    delays = []
    def launch(args, **kw):
        launched.append(args)
        return SimpleNamespace(pid=123, wait=lambda: 1)
    monkeypatch.setattr(supervisor.subprocess, "Popen", launch)
    monkeypatch.setattr(supervisor.time, "sleep", delays.append)
    monkeypatch.setattr(supervisor.time, "monotonic", lambda: 1000)
    with caplog.at_level(logging.ERROR):
        result = supervisor.supervise(tmp_path, tmp_path / "config.json", "python.exe", {}, logging.getLogger("test"))
    assert result == 0 and len(launched) == 5 and delays == [5] * 4
    assert any("five failures" in r.message for r in caplog.records)


def test_normal_exit_and_occupied_bridge_do_not_restart(tmp_path, monkeypatch):
    (tmp_path / "enabled").touch()
    for code in (0, 2):
        calls = []
        def launch(*args, **kw):
            calls.append(args)
            return SimpleNamespace(pid=123, wait=lambda: code)
        monkeypatch.setattr(supervisor.subprocess, "Popen", launch)
        assert supervisor.supervise(tmp_path, tmp_path / "config.json", "python.exe", {}, logging.getLogger("test")) == 0
        assert len(calls) == 1


def test_no_enabled_marker_means_no_child_process(tmp_path, monkeypatch):
    def forbidden(*args, **kw):
        raise AssertionError("disabled supervisor must not launch a child")
    monkeypatch.setattr(supervisor.subprocess, "Popen", forbidden)
    assert supervisor.supervise(tmp_path, tmp_path / "config.json", "python.exe", {}, logging.getLogger("test")) == 0
