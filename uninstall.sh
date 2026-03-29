#!/usr/bin/env bash
# Claude Status Bar Monitor - Uninstall Script
# Comprehensive cleanup of claude-statusbar and all residual files.

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BLUE}${BOLD}======================================${NC}"
echo -e "${BLUE}${BOLD} Claude Status Bar Monitor Uninstaller${NC}"
echo -e "${BLUE}${BOLD}======================================${NC}"
echo ""

# ── Helpers ─────────────────────────────────────────────────────

removed_something=false

info()    { echo -e "${BLUE}  [info]${NC} $1"; }
ok()      { echo -e "${GREEN}  [done]${NC} $1"; removed_something=true; }
skip()    { echo -e "${YELLOW}  [skip]${NC} $1"; }
warn()    { echo -e "${YELLOW}  [warn]${NC} $1"; }
err()     { echo -e "${RED}  [fail]${NC} $1"; }

confirm() {
    read -p "  $1 (y/N): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# ── 1. Detect and uninstall the Python package ─────────────────

uninstall_package() {
    echo -e "\n${BOLD}1. Uninstalling claude-statusbar package${NC}"

    local found=false

    # Check uv
    if command -v uv &>/dev/null && uv tool list 2>/dev/null | grep -q claude-statusbar; then
        info "Found claude-statusbar installed via uv"
        uv tool uninstall claude-statusbar && ok "Removed via uv" || err "uv uninstall failed"
        found=true
    fi

    # Check pipx
    if command -v pipx &>/dev/null && pipx list 2>/dev/null | grep -q claude-statusbar; then
        info "Found claude-statusbar installed via pipx"
        pipx uninstall claude-statusbar && ok "Removed via pipx" || err "pipx uninstall failed"
        found=true
    fi

    # Check pip (last resort — check if importable)
    if ! $found; then
        local pip_cmd=""
        if command -v pip3 &>/dev/null; then
            pip_cmd="pip3"
        elif command -v pip &>/dev/null; then
            pip_cmd="pip"
        fi

        if [ -n "$pip_cmd" ] && $pip_cmd show claude-statusbar &>/dev/null; then
            info "Found claude-statusbar installed via pip"
            $pip_cmd uninstall -y claude-statusbar && ok "Removed via pip" || err "pip uninstall failed"
            found=true
        fi
    fi

    if ! $found; then
        skip "claude-statusbar package not found in uv/pipx/pip"
    fi
}

# ── 2. Clean up cache and config files ──────────────────────────

clean_residual_files() {
    echo -e "\n${BOLD}2. Cleaning residual files${NC}"

    # Cache directory
    local cache_dir="$HOME/.cache/claude-statusbar"
    if [ -d "$cache_dir" ]; then
        rm -rf "$cache_dir"
        ok "Removed $cache_dir"
    else
        skip "$cache_dir (not found)"
    fi

    # Legacy last-check file
    local legacy_check="$HOME/.claude-statusbar-last-check"
    if [ -f "$legacy_check" ]; then
        rm -f "$legacy_check"
        ok "Removed $legacy_check"
    else
        skip "$legacy_check (not found)"
    fi
}

# ── 3. Discover all Claude homes and clean statusLine config ────

is_claude_dir() {
    # Match .claude, .claude-max, .claude-pro, .claude_custom
    # Reject .claudebar, .claude.json
    local name="$1"
    [[ "$name" == ".claude" ]] && return 0
    [[ "$name" == .claude[-_]* ]] && return 0
    return 1
}

discover_claude_homes() {
    # Returns a list of .claude directories found on this machine
    local homes=()

    # CLAUDE_CONFIG_DIR env
    if [ -n "$CLAUDE_CONFIG_DIR" ]; then
        local env_dir="$CLAUDE_CONFIG_DIR"
        if is_claude_dir "$(basename "$env_dir")"; then
            [ -d "$env_dir" ] && homes+=("$env_dir")
        else
            [ -d "$env_dir/.claude" ] && homes+=("$env_dir/.claude")
        fi
    fi

    # Current user: ~/.claude and ~/.claude-* prefixed dirs
    for candidate in "$HOME"/.claude "$HOME"/.claude[-_]*; do
        [ -d "$candidate" ] && homes+=("$candidate")
    done

    # XDG
    local xdg="${XDG_CONFIG_HOME:-$HOME/.config}/claude"
    [ -d "$xdg" ] && homes+=("$xdg")

    # Scan peer user homes (/Users/* on macOS, /home/* on Linux)
    local home_parent
    home_parent="$(dirname "$HOME")"
    if [ -d "$home_parent" ]; then
        for user_home in "$home_parent"/*/; do
            for candidate in "${user_home}".claude "${user_home}".claude[-_]*; do
                [ -d "$candidate" ] && homes+=("$candidate")
            done
        done
    fi

    # Deduplicate
    printf '%s\n' "${homes[@]}" | sort -u
}

clean_statusline_config() {
    echo -e "\n${BOLD}3. Removing statusLine config from Claude settings${NC}"

    local claude_homes=()
    while IFS= read -r line; do
        claude_homes+=("$line")
    done < <(discover_claude_homes)

    if [ ${#claude_homes[@]} -eq 0 ]; then
        skip "No Claude home directories found"
        return
    fi

    for claude_home in "${claude_homes[@]}"; do
        local settings="$claude_home/settings.json"
        if [ ! -f "$settings" ]; then
            skip "$settings (not found)"
            continue
        fi

        # Check if statusLine references claude-statusbar
        if ! grep -q "claude-statusbar\|cstatus\|statusbar" "$settings" 2>/dev/null; then
            skip "$settings (no statusbar config)"
            continue
        fi

        info "Found statusbar config in $settings"

        # Use Python to safely remove the statusLine key
        if python3 -c "
import json, sys
try:
    with open('$settings', 'r') as f:
        data = json.load(f)
    if 'statusLine' in data:
        del data['statusLine']
        with open('$settings', 'w') as f:
            json.dump(data, f, indent=2)
        print('removed')
    else:
        print('absent')
except Exception as e:
    print(f'error: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null; then
            ok "Cleaned statusLine from $settings"
        else
            warn "Could not modify $settings — remove 'statusLine' key manually"
        fi
    done
}

# ── 4. Remove shell aliases ─────────────────────────────────────

clean_shell_aliases() {
    echo -e "\n${BOLD}4. Removing shell aliases${NC}"

    local config_files=(
        "$HOME/.bashrc"
        "$HOME/.zshrc"
        "$HOME/.config/fish/config.fish"
    )

    # Match both old-style (install.sh) and new-style (web-install.sh) markers
    local markers=(
        "# Claude Status Bar Monitor aliases"
        "# Claude Status Bar Monitor"
    )

    for config_file in "${config_files[@]}"; do
        [ -f "$config_file" ] || continue

        local found_marker=false
        for marker in "${markers[@]}"; do
            if grep -q "$marker" "$config_file" 2>/dev/null; then
                found_marker=true

                # Create backup
                cp "$config_file" "$config_file.bak.$(date +%s)"

                # Remove marker line and following alias lines
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    # macOS sed
                    sed -i '' "/$marker/,+3d" "$config_file"
                else
                    sed -i "/$marker/,+3d" "$config_file"
                fi

                # Also remove any standalone claude-statusbar alias lines
                if [[ "$OSTYPE" == "darwin"* ]]; then
                    sed -i '' "/alias.*claude-statusbar/d" "$config_file"
                    sed -i '' "/alias cs='claude-statusbar'/d" "$config_file"
                    sed -i '' "/alias cstatus='claude-statusbar'/d" "$config_file"
                else
                    sed -i "/alias.*claude-statusbar/d" "$config_file"
                    sed -i "/alias cs='claude-statusbar'/d" "$config_file"
                    sed -i "/alias cstatus='claude-statusbar'/d" "$config_file"
                fi

                ok "Cleaned aliases from $config_file"
                break
            fi
        done

        if ! $found_marker; then
            # Check for standalone alias lines without marker
            if grep -q "claude-statusbar" "$config_file" 2>/dev/null; then
                info "Found claude-statusbar references in $config_file"
                if confirm "Remove them?"; then
                    cp "$config_file" "$config_file.bak.$(date +%s)"
                    if [[ "$OSTYPE" == "darwin"* ]]; then
                        sed -i '' "/claude-statusbar/d" "$config_file"
                    else
                        sed -i "/claude-statusbar/d" "$config_file"
                    fi
                    ok "Cleaned $config_file"
                else
                    skip "$config_file (user skipped)"
                fi
            fi
        fi
    done
}

# ── 5. Optionally uninstall claude-monitor ──────────────────────

uninstall_claude_monitor() {
    echo -e "\n${BOLD}5. Optional: claude-monitor package${NC}"

    if ! command -v claude-monitor &>/dev/null; then
        skip "claude-monitor not installed"
        return
    fi

    info "claude-monitor is installed (may be used by other tools)"
    if ! confirm "Also uninstall claude-monitor?"; then
        skip "Keeping claude-monitor"
        return
    fi

    local mon_path
    mon_path="$(which claude-monitor 2>/dev/null)"

    if [[ "$mon_path" == *"uv/tools"* ]] && command -v uv &>/dev/null; then
        uv tool uninstall claude-monitor && ok "Removed claude-monitor (uv)" || err "Failed"
    elif command -v pipx &>/dev/null && pipx list 2>/dev/null | grep -q claude-monitor; then
        pipx uninstall claude-monitor && ok "Removed claude-monitor (pipx)" || err "Failed"
    elif command -v pip3 &>/dev/null; then
        pip3 uninstall -y claude-monitor && ok "Removed claude-monitor (pip)" || err "Failed"
    else
        warn "Could not determine installation method for claude-monitor"
        warn "Remove manually: pip uninstall claude-monitor"
    fi
}

# ── Main ────────────────────────────────────────────────────────

main() {
    echo "This will remove claude-statusbar and all related files."
    echo ""

    if ! confirm "Continue with uninstallation?"; then
        info "Cancelled."
        exit 0
    fi

    uninstall_package
    clean_residual_files
    clean_statusline_config
    clean_shell_aliases
    uninstall_claude_monitor

    echo ""
    echo -e "${GREEN}${BOLD}======================================${NC}"
    if $removed_something; then
        echo -e "${GREEN}${BOLD} Uninstallation complete.${NC}"
    else
        echo -e "${YELLOW}${BOLD} Nothing to remove — already clean.${NC}"
    fi
    echo -e "${GREEN}${BOLD}======================================${NC}"
    echo ""
    echo "  Restart your shell to clear any cached aliases."
}

main "$@"
