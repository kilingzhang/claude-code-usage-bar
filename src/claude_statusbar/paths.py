"""Claude home directory discovery.

Automatically detects Claude Code config directories by inspecting:
  1. CLAUDE_CONFIG_DIR environment variable (explicit override)
  2. Parent process open files (macOS lsof / Linux /proc)
  3. Standard filesystem locations (~/.claude, ~/.config/claude)

Supports multiple Claude home directories on the same device.
"""

import logging
import os
import platform
import subprocess
from pathlib import Path
from typing import List, Optional

logger = logging.getLogger(__name__)

# Well-known directory names that Claude Code uses
_CLAUDE_DIR_NAME = ".claude"
_CLAUDE_DIR_PREFIX = ".claude"  # matches .claude, .claude-max, .claude-pro, etc.
_CLAUDE_XDG_NAME = "claude"

# Cache layer ── own data lives here, independent of Claude home
STATUSBAR_CACHE_DIR = Path.home() / ".cache" / "claude-statusbar"


def _unique(paths: List[Path]) -> List[Path]:
    """Deduplicate paths while preserving order."""
    seen: set[Path] = set()
    out: list[Path] = []
    for p in paths:
        rp = p.resolve()
        if rp not in seen:
            seen.add(rp)
            out.append(p)
    return out


# ── Single "current" Claude home ────────────────────────────────


def get_claude_home() -> Path:
    """Return the Claude config directory for the *current* invocation.

    Detection order:
      1. ``CLAUDE_CONFIG_DIR`` env var
      2. Parent-process open-file detection (best-effort)
      3. ``~/.claude`` default

    The returned path may not exist yet (e.g. fresh install).
    """
    # 1. Explicit env override
    env_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if env_dir:
        p = Path(env_dir).expanduser()
        # If it already looks like a Claude dir (.claude or .claude-*), use as-is
        if _is_claude_dir(p.name):
            return p
        return p / _CLAUDE_DIR_NAME

    # 2. Try to detect from parent process
    detected = _detect_from_parent_process()
    if detected:
        return detected

    # 3. Default
    return Path.home() / _CLAUDE_DIR_NAME


def get_claude_projects_dir() -> Path:
    """Shorthand for ``get_claude_home() / 'projects'``."""
    return get_claude_home() / "projects"


def get_claude_settings_path() -> Path:
    """Shorthand for ``get_claude_home() / 'settings.json'``."""
    return get_claude_home() / "settings.json"


# ── Discover ALL Claude homes (for uninstall / scanning) ────────


def discover_all_claude_homes() -> List[Path]:
    """Find every Claude config directory on this machine.

    Checks:
      - CLAUDE_CONFIG_DIR env
      - Parent-process detection
      - ~/.claude  (current user default)
      - ~/.config/claude  (XDG)
      - All /Users/*/. claude  or /home/*/.claude  (peer users)

    Returns a deduplicated list of paths that actually exist.
    """
    candidates: list[Path] = []

    # env
    env_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if env_dir:
        p = Path(env_dir).expanduser()
        if _is_claude_dir(p.name):
            candidates.append(p)
        else:
            candidates.append(p / _CLAUDE_DIR_NAME)

    # parent process
    detected = _detect_from_parent_process()
    if detected:
        candidates.append(detected)

    # current user: ~/.claude and ~/.claude-* prefixed dirs
    home = Path.home()
    candidates.append(home / _CLAUDE_DIR_NAME)
    candidates.extend(_scan_claude_prefixed(home))
    xdg_config = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config:
        candidates.append(Path(xdg_config) / _CLAUDE_XDG_NAME)
    else:
        candidates.append(home / ".config" / _CLAUDE_XDG_NAME)

    # peer user homes (best-effort, read-only scan)
    candidates.extend(_scan_peer_homes())

    # Only return paths that exist
    return _unique([p for p in candidates if p.is_dir()])


def get_all_residual_paths() -> List[Path]:
    """Return all paths that claude-statusbar may have created.

    Used by the uninstall command to show what will be removed.
    """
    paths: list[Path] = []

    # Cache directory
    paths.append(STATUSBAR_CACHE_DIR)

    # Legacy last-check file (stored in home root)
    paths.append(Path.home() / ".claude-statusbar-last-check")

    return [p for p in paths if p.exists()]


# ── Build candidate paths for JSONL data scanning ──────────────


def build_data_candidate_paths() -> List[Path]:
    """Collect plausible Claude data directories in priority order.

    Used by ``direct_data_analysis()`` as a fallback when claude-monitor
    is unavailable.
    """
    paths: list[Path] = []

    # Respect Claude Code env override
    env_dir = os.environ.get("CLAUDE_CONFIG_DIR")
    if env_dir:
        env_path = Path(env_dir).expanduser()
        if _is_claude_dir(env_path.name):
            paths.append(env_path)
            paths.append(env_path / "projects")
        else:
            paths.append(env_path / _CLAUDE_DIR_NAME)
            paths.append(env_path / _CLAUDE_DIR_NAME / "projects")

    # Running from inside a .claude dir
    cwd = Path.cwd()
    if _is_claude_dir(cwd.name):
        paths.append(cwd)
        paths.append(cwd / "projects")

    # Auto-detected home
    claude_home = get_claude_home()
    paths.append(claude_home / "projects")
    paths.append(claude_home)

    # Standard locations + .claude-* prefixed dirs
    home = Path.home()
    paths.append(home / _CLAUDE_DIR_NAME / "projects")
    for d in _scan_claude_prefixed(home):
        paths.append(d / "projects")
        paths.append(d)
    xdg_config = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config:
        paths.append(Path(xdg_config) / _CLAUDE_XDG_NAME / "projects")
    else:
        paths.append(home / ".config" / _CLAUDE_XDG_NAME / "projects")
    paths.append(home / _CLAUDE_DIR_NAME)

    return _unique(paths)


# ── Internal helpers ────────────────────────────────────────────


def _detect_from_parent_process() -> Optional[Path]:
    """Try to find the Claude home dir from the parent process.

    On macOS: uses ``lsof -p <ppid>`` to find open files under .claude/
    On Linux: reads ``/proc/<ppid>/fd/`` symlinks
    """
    try:
        ppid = os.getppid()
        if ppid <= 1:
            return None

        system = platform.system()

        if system == "Linux":
            return _detect_linux(ppid)
        elif system == "Darwin":
            return _detect_macos(ppid)
    except Exception:
        pass
    return None


def _find_claude_dir_in_parts(parts: tuple[str, ...]) -> Optional[Path]:
    """Find the first .claude-prefixed component in path parts and return up to it."""
    for i, part in enumerate(parts):
        if _is_claude_dir(part):
            return Path(*parts[: i + 1])
    return None


def _detect_linux(ppid: int) -> Optional[Path]:
    """Read /proc/<ppid>/fd/ symlinks looking for .claude paths."""
    proc_fd = Path(f"/proc/{ppid}/fd")
    if not proc_fd.is_dir():
        return None

    try:
        for fd in proc_fd.iterdir():
            try:
                target = fd.resolve()
                found = _find_claude_dir_in_parts(target.parts)
                if found:
                    return found
            except (OSError, ValueError):
                continue
    except PermissionError:
        pass
    return None


def _detect_macos(ppid: int) -> Optional[Path]:
    """Use lsof to find .claude paths opened by the parent process."""
    try:
        result = subprocess.run(
            ["lsof", "-p", str(ppid), "-Fn"],
            capture_output=True, text=True, timeout=3,
        )
        if result.returncode != 0:
            return None

        for line in result.stdout.splitlines():
            # lsof -Fn outputs lines like "n/path/to/file"
            if not line.startswith("n/"):
                continue
            path_str = line[1:]  # strip leading 'n'
            found = _find_claude_dir_in_parts(Path(path_str).parts)
            if found:
                return found
    except (subprocess.TimeoutExpired, FileNotFoundError):
        pass
    return None


def _is_claude_dir(name: str) -> bool:
    """Check if a directory name looks like a Claude config dir.

    Matches: .claude, .claude-max, .claude-pro, .claude_custom
    Rejects: .claudebar, .claude.json, .claude.json.backup
    """
    if name == _CLAUDE_DIR_NAME:
        return True
    if not name.startswith(_CLAUDE_DIR_PREFIX):
        return False
    # Must have a separator after ".claude" (dash or underscore)
    sep = name[len(_CLAUDE_DIR_PREFIX)]
    return sep in ("-", "_")


def _scan_claude_prefixed(home: Path) -> List[Path]:
    """Scan a home directory for .claude-* prefixed subdirectories.

    Finds dirs like ~/.claude-max, ~/.claude-pro, ~/.claude_custom.
    Skips files and non-matching entries.
    """
    results: list[Path] = []
    try:
        for entry in home.iterdir():
            if entry.is_dir() and _is_claude_dir(entry.name):
                results.append(entry)
    except PermissionError:
        pass
    return results


def _scan_peer_homes() -> List[Path]:
    """Scan sibling user home directories for .claude folders.

    Best-effort, read-only. Skips dirs we cannot access.
    """
    results: list[Path] = []
    home = Path.home()

    # Determine the parent of the current home dir (e.g., /Users or /home)
    home_parent = home.parent
    if not home_parent.is_dir():
        return results

    try:
        for entry in home_parent.iterdir():
            if not entry.is_dir():
                continue
            # Scan each user home for .claude and .claude-* dirs
            results.extend(_scan_claude_prefixed(entry))
            candidate = entry / _CLAUDE_DIR_NAME
            try:
                if candidate.is_dir():
                    results.append(candidate)
            except PermissionError:
                continue
    except PermissionError:
        pass

    return results
