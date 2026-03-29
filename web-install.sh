#!/bin/bash
# Claude Status Bar Monitor - Web Installer
# Usage: curl -fsSL https://raw.githubusercontent.com/leeguooooo/claude-code-usage-bar/main/web-install.sh | bash

set -e

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${BLUE}╔══════════════════════════════════════╗${NC}"
echo -e "${BLUE}║   Claude Status Bar Quick Installer  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════╝${NC}"
echo ""

# Detect package manager preference
detect_package_manager() {
    if command -v uv &> /dev/null; then
        echo "uv"
    elif command -v pipx &> /dev/null; then
        echo "pipx"
    elif command -v pip &> /dev/null || command -v pip3 &> /dev/null; then
        echo "pip"
    else
        echo "none"
    fi
}

# Show current version if installed
show_current_version() {
    if command -v claude-statusbar &> /dev/null; then
        local current_version=$(claude-statusbar --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "unknown")
        echo -e "${YELLOW}Current version: ${current_version}${NC}"
    else
        echo -e "${YELLOW}Not currently installed${NC}"
    fi
}

# Install with detected package manager
# Detect if running from the git repo (local source available)
detect_local_source() {
    # Check if script is in the repo dir, or pyproject.toml exists nearby
    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [ -f "$script_dir/pyproject.toml" ] && grep -q "claude-statusbar" "$script_dir/pyproject.toml" 2>/dev/null; then
        echo "$script_dir"
        return
    fi
    # Also check cwd
    if [ -f "./pyproject.toml" ] && grep -q "claude-statusbar" "./pyproject.toml" 2>/dev/null; then
        pwd
        return
    fi
    echo ""
}

install_package() {
    local pm=$(detect_package_manager)
    local local_src=$(detect_local_source)

    echo -e "${BLUE}Installing/upgrading claude-statusbar...${NC}"
    show_current_version

    if [ -n "$local_src" ]; then
        echo -e "${GREEN}Local source detected: $local_src${NC}"
        echo "Installing from local source (editable mode)..."
    fi

    # Determine the install target: local path or PyPI package name
    local pkg="claude-statusbar"
    local local_flag=""
    if [ -n "$local_src" ]; then
        pkg="$local_src"
        local_flag="--editable"
    fi

    case $pm in
        uv)
            echo "Using uv (recommended)..."
            if [ -n "$local_src" ]; then
                uv tool install --force-reinstall $local_flag "$pkg"
            else
                uv tool install --upgrade --force-reinstall --refresh "$pkg"
            fi
            # Also install claude-monitor for full functionality
            uv tool install --upgrade --force claude-monitor 2>/dev/null || true
            ;;
        pipx)
            echo "Using pipx..."
            if [ -n "$local_src" ]; then
                pipx install --force $local_flag "$pkg"
            else
                pipx install --force "$pkg"
            fi
            pipx install --force claude-monitor 2>/dev/null || true
            pipx upgrade claude-monitor 2>/dev/null || true
            ;;
        pip)
            echo "Using pip..."
            local pip_cmd="pip3"
            command -v pip3 &>/dev/null || pip_cmd="pip"
            if [ -n "$local_src" ]; then
                $pip_cmd install --user $local_flag "$pkg"
            else
                $pip_cmd install --user --upgrade --force-reinstall "$pkg" claude-monitor
            fi

            # Check PATH
            if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
                echo -e "${YELLOW}Adding ~/.local/bin to PATH...${NC}"
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc 2>/dev/null || true
                echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc 2>/dev/null || true
                export PATH="$HOME/.local/bin:$PATH"
            fi
            ;;
        none)
            echo -e "${YELLOW}No package manager found. Installing uv first...${NC}"

            # Install uv
            if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win32" ]]; then
                powershell -ExecutionPolicy ByPass -c "irm https://astral.sh/uv/install.ps1 | iex"
            else
                curl -LsSf https://astral.sh/uv/install.sh | sh
            fi

            # Add to PATH for current session
            export PATH="$HOME/.local/bin:$PATH"
            export PATH="$HOME/.cargo/bin:$PATH"

            # Install packages with uv
            if [ -n "$local_src" ]; then
                uv tool install --force-reinstall $local_flag "$pkg"
            else
                uv tool install --upgrade --force-reinstall --refresh "$pkg"
            fi
            uv tool install --upgrade --force claude-monitor 2>/dev/null || true
            ;;
    esac
}

# Configure shell integration
configure_shell() {
    echo -e "\n${BLUE}Configuring shell integration...${NC}"
    
    # Detect shell
    SHELL_NAME=$(basename "$SHELL")
    CONFIG_FILE=""
    
    case "$SHELL_NAME" in
        bash) CONFIG_FILE="$HOME/.bashrc" ;;
        zsh) CONFIG_FILE="$HOME/.zshrc" ;;
        fish) CONFIG_FILE="$HOME/.config/fish/config.fish" ;;
        *) CONFIG_FILE="" ;;
    esac
    
    if [ -n "$CONFIG_FILE" ] && [ -f "$CONFIG_FILE" ]; then
        # Check if already configured
        if ! grep -q "claude-statusbar" "$CONFIG_FILE" 2>/dev/null; then
            echo "" >> "$CONFIG_FILE"
            echo "# Claude Status Bar Monitor" >> "$CONFIG_FILE"
            echo "alias cs='claude-statusbar'" >> "$CONFIG_FILE"
            echo "alias cstatus='claude-statusbar'" >> "$CONFIG_FILE"
            echo -e "${GREEN}✅ Added aliases to $CONFIG_FILE${NC}"
        else
            echo -e "${GREEN}✅ Aliases already configured${NC}"
        fi
    fi
}

# Discover all Claude home directories (.claude, .claude-max, .claude-pro, etc.)
discover_claude_homes() {
    local homes=()

    # CLAUDE_CONFIG_DIR env override
    if [ -n "$CLAUDE_CONFIG_DIR" ]; then
        local base
        base="$(basename "$CLAUDE_CONFIG_DIR")"
        case "$base" in
            .claude|.claude[-_]*) [ -d "$CLAUDE_CONFIG_DIR" ] && homes+=("$CLAUDE_CONFIG_DIR") ;;
            *) [ -d "$CLAUDE_CONFIG_DIR/.claude" ] && homes+=("$CLAUDE_CONFIG_DIR/.claude") ;;
        esac
    fi

    # ~/.claude and ~/.claude-* prefixed dirs
    for candidate in "$HOME"/.claude "$HOME"/.claude[-_]*; do
        [ -d "$candidate" ] && homes+=("$candidate")
    done

    # Deduplicate
    printf '%s\n' "${homes[@]}" | sort -u
}

# Apply statusLine config to a single settings.json
apply_statusline() {
    local settings_file="$1"
    local cmd="$2"

    if [ -f "$settings_file" ] && [ -s "$settings_file" ]; then
        # Update existing settings using Python (safe JSON manipulation)
        python3 -c "
import json, sys, os
settings_path = sys.argv[1]
statusbar_cmd = sys.argv[2]
try:
    with open(settings_path, 'r') as f:
        settings = json.load(f)
except Exception:
    settings = {}
settings['statusLine'] = {'type': 'command', 'command': statusbar_cmd, 'padding': 0}
with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
" "$settings_file" "$cmd" 2>/dev/null
    else
        # Create new settings file
        mkdir -p "$(dirname "$settings_file")"
        python3 -c "
import json, sys
settings_path = sys.argv[1]
statusbar_cmd = sys.argv[2]
settings = {'statusLine': {'type': 'command', 'command': statusbar_cmd, 'padding': 0}}
with open(settings_path, 'w') as f:
    json.dump(settings, f, indent=2, ensure_ascii=False)
" "$settings_file" "$cmd" 2>/dev/null
    fi
}

# Configure Claude Code status bar (all discovered homes)
configure_claude_statusbar() {
    echo -e "\n${BLUE}Configuring Claude Code status bar...${NC}"

    # Get the installed claude-statusbar command path
    STATUSBAR_CMD=$(which claude-statusbar 2>/dev/null)

    if [ -z "$STATUSBAR_CMD" ]; then
        echo -e "${YELLOW}⚠️  claude-statusbar command not found in PATH${NC}"
        return
    fi

    local configured=0
    local claude_homes=()
    while IFS= read -r line; do
        claude_homes+=("$line")
    done < <(discover_claude_homes)

    # If no homes found at all, create ~/.claude as default
    if [ ${#claude_homes[@]} -eq 0 ]; then
        claude_homes=("$HOME/.claude")
    fi

    for claude_home in "${claude_homes[@]}"; do
        local settings_file="$claude_home/settings.json"

        # Backup existing settings
        if [ -f "$settings_file" ]; then
            cp "$settings_file" "$settings_file.backup.$(date +%Y%m%d_%H%M%S)"
        fi

        if apply_statusline "$settings_file" "$STATUSBAR_CMD"; then
            echo -e "${GREEN}✅ Configured: $settings_file${NC}"
            configured=$((configured + 1))
        else
            echo -e "${YELLOW}⚠️  Failed: $settings_file${NC}"
        fi
    done

    if [ $configured -gt 0 ]; then
        echo -e "${GREEN}✅ Claude Code status bar configured ($configured instance(s))!${NC}"
        echo -e "${YELLOW}📝 Restart Claude Code to see the updated status bar${NC}"
    fi
}

# Test installation
test_installation() {
    echo -e "\n${BLUE}Testing installation...${NC}"
    
    if command -v claude-statusbar &> /dev/null; then
        local new_version=$(claude-statusbar --version 2>/dev/null | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+' || echo "unknown")
        OUTPUT=$(claude-statusbar 2>&1 || true)
        echo -e "${GREEN}✅ Installation successful!${NC}"
        echo -e "${GREEN}Installed version: ${new_version}${NC}"
        echo -e "\nCurrent status: $OUTPUT"
    else
        echo -e "${RED}❌ Installation failed${NC}"
        echo "Please check the error messages above"
        exit 1
    fi
}

# Show usage instructions
show_usage() {
    echo -e "\n${GREEN}═══════════════════════════════════════${NC}"
    echo -e "${GREEN}Installation Complete! 🎉${NC}"
    echo -e "${GREEN}═══════════════════════════════════════${NC}"
    echo ""
    echo "Usage:"
    echo "  claude-statusbar    # Full command"
    echo "  cstatus            # Short alias"
    echo "  cs                 # Shortest alias"
    echo ""
    echo "Integration examples:"
    echo "  tmux:  set -g status-right '#(claude-statusbar)'"
    echo "  zsh:   RPROMPT='\$(claude-statusbar)'"
    echo ""
    echo "For more options: claude-statusbar --help"
}

# Main installation flow
main() {
    # Check Python
    if ! command -v python3 &> /dev/null; then
        echo -e "${RED}Python 3 is required but not installed${NC}"
        echo "Please install Python 3.9+ from https://python.org"
        exit 1
    fi
    
    # Install package
    install_package
    
    # Configure shell
    configure_shell
    
    # Configure Claude Code status bar
    configure_claude_statusbar
    
    # Test
    test_installation
    
    # Show usage
    show_usage
}

# Run installation
main "$@"