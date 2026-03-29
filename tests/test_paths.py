from pathlib import Path

from claude_statusbar.paths import (
    _prefer_claude_home,
    _cache_key_for_claude_home,
    _detect_from_process_env,
    _iter_ancestor_pids,
)


def test_prefer_claude_home_prefers_specific_variant():
    paths = [
        Path("/Users/dev/.claude"),
        Path("/Users/dev/.claude-max"),
        Path("/Users/dev/.claude-pro"),
    ]
    assert _prefer_claude_home(paths) == Path("/Users/dev/.claude-max")


def test_cache_key_uses_default_for_plain_claude():
    assert _cache_key_for_claude_home(Path("/Users/dev/.claude")) == "default"


def test_cache_key_names_variant():
    key = _cache_key_for_claude_home(Path("/Users/dev/.claude-max"))
    assert key.startswith("claude-max-")


def test_iter_ancestor_pids_walks_parent_chain(monkeypatch):
    parents = {200: 150, 150: 100, 100: 1}

    def fake_get_parent_pid(pid: int) -> int:
        return parents.get(pid, 0)

    monkeypatch.setattr("claude_statusbar.paths._get_parent_pid", fake_get_parent_pid)
    assert _iter_ancestor_pids(200) == [200, 150, 100]


def test_detect_from_process_env_uses_claude_config_dir(monkeypatch):
    monkeypatch.setattr(
        "claude_statusbar.paths._read_process_env_var",
        lambda pid, key: "/Users/dev/.claude-max" if key == "CLAUDE_CONFIG_DIR" else None,
    )
    assert _detect_from_process_env(123) == Path("/Users/dev/.claude-max")
