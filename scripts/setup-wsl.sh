#!/usr/bin/env bash
#
# WSL Ubuntu 24.04 Environment Setup Script
# Recreates development environment from scratch
#
# Usage: ./setup-wsl.sh [--dry-run]
#
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

log_info()  { echo -e "${BLUE}[INFO]${NC} $*"; }
log_ok()    { echo -e "${GREEN}[OK]${NC} $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*"; }

run() {
    if $DRY_RUN; then
        echo -e "${YELLOW}[DRY-RUN]${NC} $*"
    else
        "$@"
    fi
}

command_exists() {
    command -v "$1" &>/dev/null
}

# ============================================================================
# PHASE 1: System Packages
# ============================================================================
install_apt_packages() {
    log_info "Installing APT packages..."

    local packages=(
        # Build essentials
        build-essential
        gcc
        g++
        make
        pkg-config
        autoconf
        automake
        libtool
        cmake

        # Development libraries
        libssl-dev
        zlib1g-dev
        uuid-dev
        libffi-dev
        libbz2-dev
        libreadline-dev
        libsqlite3-dev
        libncursesw5-dev
        libxml2-dev
        libxmlsec1-dev
        liblzma-dev

        # Core utilities
        git
        curl
        wget
        jq
        unzip
        zip
        htop

        # Shell & terminal
        zsh
        tmux
        vim

        # Modern CLI tools (available in Ubuntu 24.04)
        fzf
        ripgrep
        fd-find
        bat
        eza
        micro

        # Python
        python3
        python3-dev
        python3-pip
        python3-venv

        # Go (system version)
        golang-go

        # X11 / GUI support for WSL
        x11-apps
        xauth
        xclip

        # Misc
        ca-certificates
        gnupg
        lsb-release
        apt-transport-https
        software-properties-common
    )

    run sudo apt update
    run sudo apt install -y "${packages[@]}"
    log_ok "APT packages installed"
}

# ============================================================================
# PHASE 2: Snap Packages
# ============================================================================
install_snap_packages() {
    log_info "Installing Snap packages..."

    if ! command_exists snap; then
        log_warn "Snap not available, skipping snap packages"
        return
    fi

    # chezmoi - dotfiles manager
    if ! command_exists chezmoi; then
        run sudo snap install chezmoi --classic
        log_ok "chezmoi installed"
    else
        log_ok "chezmoi already installed"
    fi

    # zellij - terminal multiplexer
    if ! snap list zellij &>/dev/null; then
        run sudo snap install zellij --classic
        log_ok "zellij installed"
    else
        log_ok "zellij already installed"
    fi
}

# ============================================================================
# PHASE 3: Version Managers & Runtimes
# ============================================================================

install_nvm() {
    log_info "Installing NVM (Node Version Manager)..."

    export NVM_DIR="${HOME}/.nvm"

    if [[ -d "$NVM_DIR" ]]; then
        log_ok "NVM already installed at $NVM_DIR"
    else
        run curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash
        log_ok "NVM installed"
    fi

    # Source NVM for current session
    if [[ -s "$NVM_DIR/nvm.sh" ]]; then
        source "$NVM_DIR/nvm.sh"
    fi
}

install_node() {
    log_info "Installing Node.js via NVM..."

    export NVM_DIR="${HOME}/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

    if command_exists node; then
        log_ok "Node.js already installed: $(node --version)"
    else
        run nvm install --lts
        run nvm use --lts
        log_ok "Node.js installed"
    fi
}

install_node_globals() {
    log_info "Installing global npm packages..."

    export NVM_DIR="${HOME}/.nvm"
    [[ -s "$NVM_DIR/nvm.sh" ]] && source "$NVM_DIR/nvm.sh"

    local packages=(
        "@anthropic-ai/claude-code"
    )

    for pkg in "${packages[@]}"; do
        if npm list -g "$pkg" &>/dev/null; then
            log_ok "$pkg already installed"
        else
            run npm install -g "$pkg"
            log_ok "$pkg installed"
        fi
    done
}

install_rustup() {
    log_info "Installing Rust via rustup..."

    if command_exists rustup; then
        log_ok "Rustup already installed"
        run rustup update
    else
        run curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        log_ok "Rust installed"
    fi

    # Source cargo env
    [[ -f "$HOME/.cargo/env" ]] && source "$HOME/.cargo/env"
}

install_cargo_tools() {
    log_info "Installing Cargo tools..."

    source "$HOME/.cargo/env" 2>/dev/null || true

    local tools=(
        "dust"  # disk usage analyzer
    )

    for tool in "${tools[@]}"; do
        if command_exists "$tool"; then
            log_ok "$tool already installed"
        else
            run cargo install "$tool"
            log_ok "$tool installed"
        fi
    done
}

install_bun() {
    log_info "Installing Bun..."

    if command_exists bun; then
        log_ok "Bun already installed: $(bun --version)"
    else
        run curl -fsSL https://bun.sh/install | bash
        log_ok "Bun installed"
    fi
}

install_uv() {
    log_info "Installing UV (Python package manager)..."

    if command_exists uv; then
        log_ok "UV already installed"
    else
        run curl -LsSf https://astral.sh/uv/install.sh | sh
        log_ok "UV installed"
    fi
}

# ============================================================================
# PHASE 4: Special Tools
# ============================================================================

install_zoxide() {
    log_info "Installing zoxide..."

    if command_exists zoxide; then
        log_ok "zoxide already installed"
    else
        run curl -sSfL https://raw.githubusercontent.com/ajeetdsouza/zoxide/main/install.sh | sh
        log_ok "zoxide installed"
    fi
}

install_atuin() {
    log_info "Installing Atuin (shell history)..."

    if command_exists atuin; then
        log_ok "Atuin already installed"
    else
        run curl --proto '=https' --tlsv1.2 -LsSf https://setup.atuin.sh | sh
        log_ok "Atuin installed"
    fi
}

install_yazi() {
    log_info "Installing Yazi (file manager)..."

    if command_exists yazi; then
        log_ok "Yazi already installed"
    else
        # Yazi requires building from source or downloading binary
        local YAZI_VERSION="v25.5.31"
        local YAZI_URL="https://github.com/sxyazi/yazi/releases/download/${YAZI_VERSION}/yazi-x86_64-unknown-linux-gnu.zip"
        local TEMP_DIR=$(mktemp -d)

        run curl -L "$YAZI_URL" -o "$TEMP_DIR/yazi.zip"
        run unzip "$TEMP_DIR/yazi.zip" -d "$TEMP_DIR"
        run sudo mv "$TEMP_DIR/yazi-x86_64-unknown-linux-gnu/yazi" /usr/local/bin/
        run sudo mv "$TEMP_DIR/yazi-x86_64-unknown-linux-gnu/ya" /usr/local/bin/
        run sudo chmod +x /usr/local/bin/yazi /usr/local/bin/ya
        rm -rf "$TEMP_DIR"
        log_ok "Yazi installed"
    fi
}

# ============================================================================
# PHASE 5: Shell Setup
# ============================================================================

install_oh_my_zsh() {
    log_info "Installing Oh My Zsh..."

    if [[ -d "$HOME/.oh-my-zsh" ]]; then
        log_ok "Oh My Zsh already installed"
    else
        RUNZSH=no CHSH=no run sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
        log_ok "Oh My Zsh installed"
    fi
}

install_zsh_plugins() {
    log_info "Installing Zsh plugins..."

    local ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"

    # Powerlevel10k theme
    if [[ -d "$ZSH_CUSTOM/themes/powerlevel10k" ]]; then
        log_ok "Powerlevel10k already installed"
    else
        run git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$ZSH_CUSTOM/themes/powerlevel10k"
        log_ok "Powerlevel10k installed"
    fi

    # zsh-autosuggestions
    if [[ -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]]; then
        log_ok "zsh-autosuggestions already installed"
    else
        run git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
        log_ok "zsh-autosuggestions installed"
    fi

    # zsh-syntax-highlighting
    if [[ -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]]; then
        log_ok "zsh-syntax-highlighting already installed"
    else
        run git clone https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
        log_ok "zsh-syntax-highlighting installed"
    fi

    # zsh-history-substring-search
    if [[ -d "$ZSH_CUSTOM/plugins/zsh-history-substring-search" ]]; then
        log_ok "zsh-history-substring-search already installed"
    else
        run git clone https://github.com/zsh-users/zsh-history-substring-search "$ZSH_CUSTOM/plugins/zsh-history-substring-search"
        log_ok "zsh-history-substring-search installed"
    fi
}

set_default_shell() {
    log_info "Setting Zsh as default shell..."

    if [[ "$SHELL" == *"zsh"* ]]; then
        log_ok "Zsh is already default shell"
    else
        run chsh -s "$(which zsh)"
        log_ok "Default shell changed to Zsh"
    fi
}

# ============================================================================
# PHASE 6: Apply Dotfiles
# ============================================================================

apply_chezmoi() {
    log_info "Applying chezmoi dotfiles..."

    if ! command_exists chezmoi; then
        log_error "chezmoi not installed, skipping dotfiles"
        return 1
    fi

    # Initialize chezmoi if not already done
    if [[ ! -d "$HOME/.local/share/chezmoi" ]]; then
        log_warn "chezmoi not initialized. Run: chezmoi init <your-repo>"
        return 1
    fi

    run chezmoi apply
    log_ok "Dotfiles applied"
}

# ============================================================================
# PHASE 7: Post-install Verification
# ============================================================================

verify_installation() {
    log_info "Verifying installation..."

    local tools=(
        "git"
        "zsh"
        "fzf"
        "rg:ripgrep"
        "fd:fd-find"
        "bat:bat"
        "eza:eza"
        "micro"
        "chezmoi"
        "zellij"
        "node"
        "npm"
        "rustc"
        "cargo"
        "bun"
        "uv"
        "zoxide"
        "atuin"
        "yazi"
        "go"
    )

    local missing=()

    for tool_spec in "${tools[@]}"; do
        local cmd="${tool_spec%%:*}"
        local name="${tool_spec##*:}"
        if command_exists "$cmd"; then
            log_ok "$name"
        else
            log_error "$name NOT FOUND"
            missing+=("$name")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_warn "Missing tools: ${missing[*]}"
        return 1
    fi

    log_ok "All tools verified!"
}

# ============================================================================
# Main
# ============================================================================

main() {
    echo ""
    echo "========================================"
    echo "  WSL Ubuntu Development Environment"
    echo "========================================"
    echo ""

    if $DRY_RUN; then
        log_warn "DRY RUN MODE - No changes will be made"
        echo ""
    fi

    install_apt_packages
    install_snap_packages

    install_nvm
    install_node
    install_node_globals

    install_rustup
    install_cargo_tools

    install_bun
    install_uv

    install_zoxide
    install_atuin
    install_yazi

    install_oh_my_zsh
    install_zsh_plugins
    set_default_shell

    apply_chezmoi

    echo ""
    log_info "Running verification..."
    verify_installation

    echo ""
    echo "========================================"
    log_ok "Setup complete!"
    echo "========================================"
    echo ""
    echo "Next steps:"
    echo "  1. Restart your terminal or run: exec zsh"
    echo "  2. Run 'p10k configure' if you want to reconfigure Powerlevel10k"
    echo "  3. Run 'atuin login' if you want to sync shell history"
    echo ""
}

main "$@"
