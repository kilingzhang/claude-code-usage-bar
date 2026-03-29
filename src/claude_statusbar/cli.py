#!/usr/bin/env python3
"""CLI entry point for claude-statusbar"""

import sys
import os
import argparse
import json
import shutil
from pathlib import Path
from . import __version__
from .core import main as statusbar_main


def main():
    """Main CLI entry point"""
    parser = argparse.ArgumentParser(
        description="Claude Status Bar Monitor - Lightweight token usage monitor",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  claude-statusbar          # Show current usage
  cstatus                   # Short alias
  cs                        # Shortest alias
  
  claude-statusbar --json-output
  claude-statusbar --plan zai-pro
  claude-statusbar --reset-hour 14
  
Integration:
  tmux:     set -g status-right '#(claude-statusbar)'
  zsh:      RPROMPT='$(claude-statusbar)'
  i3:       status_command echo "$(claude-statusbar)"
        """,
    )

    parser.add_argument(
        "--version", action="version", version=f"%(prog)s {__version__}"
    )

    parser.add_argument(
        "--install-deps",
        action="store_true",
        help="Install claude-monitor dependency for full functionality",
    )
    parser.add_argument(
        "--json-output",
        action="store_true",
        help="Emit machine-readable JSON instead of colored status line",
    )
    parser.add_argument(
        "--plan",
        type=str,
        help="Plan override (e.g., pro, max5, max20, zai-lite, zai-pro, zai-max)",
    )
    parser.add_argument(
        "--reset-hour",
        type=int,
        help="Reset hour (0-23) if your quota resets at a fixed local time",
    )
    parser.add_argument(
        "--no-color",
        action="store_true",
        help="Disable ANSI color codes in output",
    )
    parser.add_argument(
        "--detail",
        action="store_true",
        help="Show detailed breakdown of usage data and limits",
    )
    parser.add_argument(
        "--no-auto-update",
        action="store_true",
        help="Disable automatic update checks (or set CLAUDE_STATUSBAR_NO_UPDATE=1)",
    )
    parser.add_argument(
        "--uninstall",
        action="store_true",
        help="Remove all claude-statusbar residual files (cache, config, aliases)",
    )

    args = parser.parse_args()

    if sys.version_info < (3, 9):
        print(
            "claude-statusbar requires Python 3.9+; please upgrade your interpreter.",
            file=sys.stderr,
        )
        return 1

    def env_bool(name: str) -> bool:
        val = os.environ.get(name)
        return val is not None and val.lower() in ("1", "true", "yes", "y", "on")

    # Prefer CLI, fall back to env
    plan = args.plan or os.environ.get("CLAUDE_PLAN")
    json_output = args.json_output or env_bool("CLAUDE_STATUSBAR_JSON")
    reset_hour = args.reset_hour
    if reset_hour is None:
        env_reset = os.environ.get("CLAUDE_RESET_HOUR")
        if env_reset:
            try:
                reset_hour = int(env_reset)
            except ValueError:
                print(
                    "Ignoring invalid CLAUDE_RESET_HOUR (must be integer 0-23).",
                    file=sys.stderr,
                )
                reset_hour = None
    if reset_hour is not None and not (0 <= reset_hour <= 23):
        print("Reset hour must be between 0 and 23.", file=sys.stderr)
        return 1

    if args.uninstall:
        return _run_uninstall()

    if args.install_deps:
        print("Installing claude-monitor for full functionality...")
        print("Run one of these commands:")
        print("  uv tool install claude-monitor    # Recommended")
        print("  pip install claude-monitor")
        print("  pipx install claude-monitor")
        return 0

    if args.no_auto_update:
        os.environ['CLAUDE_STATUSBAR_NO_UPDATE'] = '1'

    # Run the status bar
    use_color = not (args.no_color or env_bool("NO_COLOR"))
    try:
        statusbar_main(json_output=json_output, plan=plan, reset_hour=reset_hour,
                        use_color=use_color, detail=args.detail)
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1


def _run_uninstall() -> int:
    """Remove all claude-statusbar residual files and configurations."""
    from .paths import (
        STATUSBAR_CACHE_DIR,
        discover_all_claude_homes,
        get_all_residual_paths,
    )

    print("claude-statusbar uninstall")
    print("=" * 40)

    removed = []

    # 1. Residual files (cache dir, legacy check file)
    print("\n[1] Residual files")
    for p in get_all_residual_paths():
        try:
            if p.is_dir():
                shutil.rmtree(p)
            else:
                p.unlink()
            print(f"  removed: {p}")
            removed.append(str(p))
        except OSError as e:
            print(f"  failed:  {p} ({e})", file=sys.stderr)

    if not get_all_residual_paths():
        print("  (none found)")

    # 2. statusLine in Claude settings.json
    print("\n[2] Claude settings.json statusLine config")
    claude_homes = discover_all_claude_homes()
    if not claude_homes:
        print("  (no Claude home directories found)")
    for claude_home in claude_homes:
        settings_path = claude_home / "settings.json"
        if not settings_path.is_file():
            continue
        try:
            data = json.loads(settings_path.read_text(encoding="utf-8"))
            sl = data.get("statusLine", {})
            cmd = sl.get("command", "") if isinstance(sl, dict) else ""
            if "claude-statusbar" in cmd or "cstatus" in cmd or "statusbar" in cmd:
                del data["statusLine"]
                settings_path.write_text(
                    json.dumps(data, indent=2, ensure_ascii=False) + "\n",
                    encoding="utf-8",
                )
                print(f"  removed statusLine from: {settings_path}")
                removed.append(str(settings_path))
            else:
                print(f"  no statusbar config in: {settings_path}")
        except (json.JSONDecodeError, OSError) as e:
            print(f"  failed:  {settings_path} ({e})", file=sys.stderr)

    # 3. Summary
    print("\n" + "=" * 40)
    if removed:
        print(f"Cleaned {len(removed)} item(s).")
    else:
        print("Nothing to clean — already tidy.")

    print("\nTo fully uninstall the package itself, run:")
    print("  uv tool uninstall claude-statusbar")
    print("  # or: pipx uninstall claude-statusbar")
    print("  # or: pip uninstall claude-statusbar")

    return 0


if __name__ == "__main__":
    sys.exit(main())
