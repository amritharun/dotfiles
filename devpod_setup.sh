#!/usr/bin/env bash
# Devpod setup script for amrith.
# Run once on a fresh devpod. Idempotent — safe to re-run.
#
# Usage:
#   ./devpod_setup.sh                  # run all steps
#   ./devpod_setup.sh --force-tmux     # overwrite ~/.tmux.conf even if it exists
#   ./devpod_setup.sh --skip=nvim,lazyvim,tmux  # skip specific steps
#   ./devpod_setup.sh --only=gh,claude          # only run specific steps
#   ./devpod_setup.sh --no-shell                # skip exec'ing a new shell at end
#
# Steps (in order):
#   apt        — apt update + install ripgrep, tmux, python3.11-venv, maven, acl, yazi companions
#   gh         — github auth (interactive if not authed); runs before git so the
#                git step can tell whose pod this is
#   git        — set global git user/email, without clobbering an existing identity
#   claude     — claude auth check (manual login if not authed)
#   python     — verify python3.11 present
#   venv       — create ~/.venvs/devpod and auto-activate via ~/.zshrc
#   pip        — install polars, pyarrow, requests, boto3, duckdb into the venv
#   duckdb_cli — install the pinned duckdb CLI binary
#   yazi       — install the pinned yazi TUI file manager (yazi + ya CLI)
#   delta      — install the pinned git-delta + wire it into ~/.gitconfig as pager
#   ghostty    — install xterm-ghostty terminfo + set TERM=xterm-ghostty in zshrc
#   nvim       — install the pinned neovim from the official tarball
#   lazyvim    — install LazyVim starter config
#   tmux       — port .tmux.conf from amritharun/dotfiles
#   docker     — grant this user access to the docker socket (per-user ACL)
#
# Environment overrides (all optional):
#   DEVPOD_GIT_NAME      — git user.name      (default: amrith-od)
#   DEVPOD_GIT_EMAIL     — git user.email     (default: aarunachalam@optimaldynamics.com)
#   DEVPOD_TMUX_CONF_URL — .tmux.conf source  (default: amritharun/dotfiles)
#   DEVPOD_FORCE_TMUX    — 1 to refetch .tmux.conf (same as --force-tmux)
#
# Test seams. These exist so tests/ can point the install steps at a sandbox and
# drive the checksum check; there is no reason to set them by hand:
#   DEVPOD_BIN_DIR     — prefix for installed CLIs (default: /usr/local/bin)
#   DEVPOD_OPT_DIR     — parent of the neovim tree (default: /opt)
#   DEVPOD_DOCKER_SOCK — docker socket to grant on (default: /var/run/docker.sock)
#   DEVPOD_{NVIM,DUCKDB,YAZI,DELTA}_SHA256 — override an expected checksum

set -euo pipefail

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
log()  { printf "\033[1;34m[devpod_setup]\033[0m %s\n" "$*"; }
ok()   { printf "  \033[1;32m✓\033[0m %s\n" "$*"; }
warn() { printf "  \033[1;33m!\033[0m %s\n" "$*"; }
err()  { printf "  \033[1;31m✗\033[0m %s\n" "$*" >&2; }

# ---------------------------------------------------------------------------
# Arguments
#
# Parsed before any environment probing so --help keeps working even where
# the rest of the script cannot run — e.g. an architecture we publish no
# download URLs for.
# ---------------------------------------------------------------------------
SKIP=""
ONLY=""
FORCE_TMUX="${DEVPOD_FORCE_TMUX:-0}"
NO_SHELL=0

for arg in "$@"; do
    case "$arg" in
        --skip=*)       SKIP="${arg#--skip=}" ;;
        --only=*)       ONLY="${arg#--only=}" ;;
        --force-tmux)   FORCE_TMUX=1 ;;
        --no-shell)     NO_SHELL=1 ;;
        -h|--help)
            # Print the leading comment block verbatim so usage text can never
            # drift out of sync with a hardcoded line range.
            awk 'NR>1 && /^#/ { sub(/^# ?/, ""); print; next } NR>1 { exit }' "$0"
            exit 0
            ;;
        *) echo "Unknown arg: $arg" >&2; exit 1 ;;
    esac
done

should_run() {
    local step="$1"
    if [[ -n "$ONLY" ]]; then
        [[ ",$ONLY," == *",$step,"* ]]
    else
        [[ ",$SKIP," != *",$step,"* ]]
    fi
}

# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------
# Release assets are per-arch, and the three projects we pull from spell the
# same architecture three different ways, so keep one variable per consumer
# rather than trying to normalise them into one.
case "$(uname -m)" in
    x86_64|amd64)
        ARCH_NVIM="x86_64"    # nvim-linux-<arch>.tar.gz
        ARCH_DUCKDB="amd64"   # duckdb_cli-linux-<arch>.zip
        ARCH_RUST="x86_64"    # <arch>-unknown-linux-gnu (yazi, delta)
        ;;
    aarch64|arm64)
        ARCH_NVIM="arm64"
        ARCH_DUCKDB="arm64"
        ARCH_RUST="aarch64"
        ;;
    *)
        err "unsupported architecture: $(uname -m)"
        err "this script only publishes x86_64 and arm64 download URLs"
        exit 1
        ;;
esac

GIT_DEFAULT_NAME="amrith-od"
GIT_DEFAULT_EMAIL="aarunachalam@optimaldynamics.com"
GIT_USER_NAME="${DEVPOD_GIT_NAME:-$GIT_DEFAULT_NAME}"
GIT_USER_EMAIL="${DEVPOD_GIT_EMAIL:-$GIT_DEFAULT_EMAIL}"
VENV_PATH="$HOME/.venvs/devpod"
BIN_DIR="${DEVPOD_BIN_DIR:-/usr/local/bin}"
OPT_DIR="${DEVPOD_OPT_DIR:-/opt}"
DOCKER_SOCK="${DEVPOD_DOCKER_SOCK:-/var/run/docker.sock}"
TMUX_CONF_URL="${DEVPOD_TMUX_CONF_URL:-https://raw.githubusercontent.com/amritharun/dotfiles/main/.tmux.conf}"
DELTA_REPO="dandavison/delta"

# Downloads are pinned and checksummed. `releases/latest` meant the bytes
# installed were never the bytes that were tested, and nothing verified them.
# To bump a tool: change its version here, then record the new digest with
#   curl -fsSL <asset-url> | sha256sum
NVIM_VERSION="v0.12.5"
DUCKDB_VERSION="v1.5.5"
YAZI_VERSION="v26.8.15"
DELTA_VERSION="0.19.2"

case "$ARCH_RUST" in
    x86_64)
        NVIM_SHA256="bce0f56eda1f1b1db6eee8f4133d7a38813ea07933837dd1777411ca384c6875"
        DUCKDB_SHA256="08c0ca117111fcede14239d0093792352befdc174218c344d232c13279643d05"
        YAZI_SHA256="cc67eb7991550c2f9407cda52d3f5af0937627aa6884e7de99a04fcf059807e0"
        DELTA_SHA256="8e695c5f586a8c53d6c3b01be0b4a422ed218bfed2a56191caebe373a1c18ab2"
        ;;
    aarch64)
        NVIM_SHA256="1aa5ca085249580ae0f91eb14f27ec0919773ff2d99a163d03f3d6c21ac29725"
        DUCKDB_SHA256="02163197027a42149147364d31fa67cac82108517a4be43304a1cc226eaef07a"
        YAZI_SHA256="f5a85771f06bb0e8c488136ae0aedaec8d341a7cee995549df391d7d852fe8d1"
        DELTA_SHA256="0bfce159a5cddd5feb3d6db4a616d883ff51253ce08ac7ec11cb1d208cfaab9e"
        ;;
esac
NVIM_SHA256="${DEVPOD_NVIM_SHA256:-$NVIM_SHA256}"
DUCKDB_SHA256="${DEVPOD_DUCKDB_SHA256:-$DUCKDB_SHA256}"
YAZI_SHA256="${DEVPOD_YAZI_SHA256:-$YAZI_SHA256}"
DELTA_SHA256="${DEVPOD_DELTA_SHA256:-$DELTA_SHA256}"

NVIM_INSTALL_DIR="$OPT_DIR/nvim-linux-$ARCH_NVIM"
NVIM_TARBALL_URL="https://github.com/neovim/neovim/releases/download/$NVIM_VERSION/nvim-linux-$ARCH_NVIM.tar.gz"
DUCKDB_CLI_URL="https://github.com/duckdb/duckdb/releases/download/$DUCKDB_VERSION/duckdb_cli-linux-$ARCH_DUCKDB.zip"
YAZI_URL="https://github.com/sxyazi/yazi/releases/download/$YAZI_VERSION/yazi-$ARCH_RUST-unknown-linux-gnu.zip"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GHOSTTY_TERMINFO_FILE="$SCRIPT_DIR/ghostty.terminfo"
ZSHRC_MARKER_BEGIN="# >>> devpod_setup >>>"
ZSHRC_MARKER_END="# <<< devpod_setup <<<"

ALL_STEPS=(apt gh git claude python venv pip duckdb_cli yazi delta ghostty nvim lazyvim tmux docker)

# verify_sha256 <file> <expected-digest>
verify_sha256() {
    local file="$1" want="$2" got
    got="$(sha256sum "$file")"
    got="${got%% *}"
    if [[ "$got" != "$want" ]]; then
        err "checksum mismatch for ${file##*/} — refusing to install"
        err "  expected $want"
        err "  actual   $got"
        return 1
    fi
    ok "checksum verified: ${file##*/}"
}

# ---------------------------------------------------------------------------
# apt update + apt installs
# ---------------------------------------------------------------------------
step_apt() {
    log "Step: apt update + install ripgrep, tmux, python3.11-venv, maven, acl, yazi companions"
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -y
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y \
        ripgrep tmux python3.11-venv maven acl \
        fd-find fzf zoxide poppler-utils jq
    ok "apt packages installed"
}

# ---------------------------------------------------------------------------
# git global config
# ---------------------------------------------------------------------------
step_git() {
    log "Step: git global config"

    local have_name have_email
    have_name="$(git config --global --get user.name || true)"
    have_email="$(git config --global --get user.email || true)"

    if [[ -n "${DEVPOD_GIT_NAME:-}" || -n "${DEVPOD_GIT_EMAIL:-}" ]]; then
        : # an explicit request; fall through and write it
    elif [[ -n "$have_name" && -n "$have_email" ]]; then
        # This pod already has an identity. Whoever set it meant it.
        ok "keeping existing git identity: $have_name <$have_email>"
        GIT_USER_NAME="$have_name"
        GIT_USER_EMAIL="$have_email"
    else
        # Nothing configured, and the built-in default is one specific person's.
        # Check whose pod this is before stamping their name on its commits.
        local gh_login=""
        gh_login="$(gh api user --jq .login 2>/dev/null || true)"
        if [[ -n "$gh_login" && "$gh_login" != "$GIT_DEFAULT_NAME" ]]; then
            err "no git identity is configured here, and the built-in default is $GIT_DEFAULT_NAME's"
            err "you are authenticated as '$gh_login' — commits would be misattributed"
            err "set DEVPOD_GIT_NAME and DEVPOD_GIT_EMAIL, then re-run --only=git"
            return 1
        fi
    fi

    git config --global user.name "$GIT_USER_NAME"
    git config --global user.email "$GIT_USER_EMAIL"
    # A configured editor is a personal preference; don't overwrite one.
    if [[ -z "$(git config --global --get core.editor || true)" ]]; then
        git config --global core.editor "nvim"
    fi
    ok "git user.name=$GIT_USER_NAME, user.email=$GIT_USER_EMAIL"
}

# ---------------------------------------------------------------------------
# GitHub auth
# ---------------------------------------------------------------------------
step_gh() {
    log "Step: GitHub CLI auth"
    if ! command -v gh >/dev/null; then
        err "gh not found — devcontainer should provide it. Aborting step."
        return 1
    fi
    if gh auth status >/dev/null 2>&1; then
        ok "gh already authenticated"
    else
        warn "gh not authenticated — launching interactive login"
        gh auth login
    fi
    gh auth setup-git
    ok "gh credential helper configured for git"
}

# ---------------------------------------------------------------------------
# Claude auth
# ---------------------------------------------------------------------------
step_claude() {
    log "Step: Claude CLI auth"
    if ! command -v claude >/dev/null; then
        err "claude not found on PATH — install it first, then re-run --only=claude"
        return 1
    fi
    # claude stores credentials under ~/.claude — presence of credentials.json
    # (or .credentials.json) indicates an authed session.
    if [[ -f "$HOME/.claude/.credentials.json" ]] || [[ -f "$HOME/.claude/credentials.json" ]]; then
        ok "claude already authenticated"
        return 0
    fi
    warn "claude not authenticated — launching interactive login"
    warn "complete the OAuth flow in the browser, then exit claude (Ctrl+D) to continue this script"
    claude
    if [[ -f "$HOME/.claude/.credentials.json" ]] || [[ -f "$HOME/.claude/credentials.json" ]]; then
        ok "claude authentication complete"
    else
        warn "could not detect claude credentials after login — verify manually with: claude"
    fi
}

# ---------------------------------------------------------------------------
# Python version check
# ---------------------------------------------------------------------------
step_python() {
    log "Step: Python version check (repo pins 3.11)"
    if ! command -v python3.11 >/dev/null; then
        err "python3.11 not found — devcontainer should provide it"
        return 1
    fi
    ok "$(python3.11 --version) at $(command -v python3.11)"
}

# ---------------------------------------------------------------------------
# venv + auto-activate via .zshrc
# ---------------------------------------------------------------------------
step_venv() {
    log "Step: venv at $VENV_PATH + auto-activate via ~/.zshrc"
    if [[ -d "$VENV_PATH" ]] && [[ ! -x "$VENV_PATH/bin/pip" ]]; then
        warn "found broken venv at $VENV_PATH (no pip) — removing and recreating"
        rm -rf "$VENV_PATH"
    fi
    if [[ ! -d "$VENV_PATH" ]]; then
        mkdir -p "$(dirname "$VENV_PATH")"
        python3.11 -m venv "$VENV_PATH"
        ok "created venv at $VENV_PATH"
    else
        ok "venv already exists at $VENV_PATH"
    fi

    local zshrc="$HOME/.zshrc"
    touch "$zshrc"
    # Strip any prior block, then append a fresh one. A marker range is only
    # safe to delete when it is balanced: a BEGIN with no END would take
    # everything after it, which on a hand-edited .zshrc is someone's config.
    local begins ends
    begins="$(grep -cxF "$ZSHRC_MARKER_BEGIN" "$zshrc" || true)"
    ends="$(grep -cxF "$ZSHRC_MARKER_END" "$zshrc" || true)"
    if (( begins > 0 || ends > 0 )); then
        if (( begins != ends )); then
            local backup="$zshrc.bak.$(date +%s)"
            cp "$zshrc" "$backup"
            warn "unbalanced devpod_setup markers in $zshrc ($begins begin, $ends end)"
            warn "everything from the marker on will be rewritten — saved a copy at $backup"
        fi
        awk -v b="$ZSHRC_MARKER_BEGIN" -v e="$ZSHRC_MARKER_END" '
            $0 == b { inblock = 1; next }
            $0 == e { inblock = 0; next }
            !inblock
        ' "$zshrc" > "$zshrc.devpod_tmp"
        mv "$zshrc.devpod_tmp" "$zshrc"
    fi
    cat >> "$zshrc" <<EOF
$ZSHRC_MARKER_BEGIN
# Tell tmux + apps the truth about our outer terminal (Ghostty), but ONLY in
# the outer shell. Inside tmux, TERM must remain tmux-256color (set by tmux's
# default-terminal) — overriding it to xterm-ghostty inside a pane causes apps
# to emit Ghostty-specific escapes tmux can't interpret, producing blank
# screens / corrupted text on pane switches.
# Requires xterm-ghostty terminfo to be installed (see step_ghostty).
if [ -z "\${TMUX:-}" ] && infocmp xterm-ghostty >/dev/null 2>&1; then
    export TERM=xterm-ghostty
fi
# Repaint every cell each frame in Claude Code's fullscreen renderer. tmux
# mishandles the renderer's incremental cell writes, leaving stale fragments on
# scroll (jumbled transcript). Full repaint trades a little throughput to fix it.
export CLAUDE_CODE_ALT_SCREEN_FULL_REPAINT=1
# Auto-activate the devpod venv on shell start. Disable the venv's own
# "(devpod)" prompt prefix — the pod-name segment below replaces it.
if [ -f "$VENV_PATH/bin/activate" ]; then
    export VIRTUAL_ENV_DISABLE_PROMPT=1
    source "$VENV_PATH/bin/activate"
fi
# Show the running devpod's name in the prompt. DevPod exports
# LOCAL_WORKSPACE_FOLDER as .../workspaces/<name>/content; fall back to the
# container hostname if it's absent. Prepended after the venv activation so it
# sits at the front of whatever PROMPT the devcontainer theme produced.
if [ -n "\${LOCAL_WORKSPACE_FOLDER:-}" ]; then
    DEVPOD_NAME="\$(basename "\$(dirname "\$LOCAL_WORKSPACE_FOLDER")")"
else
    DEVPOD_NAME="\$(hostname)"
fi
PROMPT="%F{magenta}⬡ \${DEVPOD_NAME}%f \${PROMPT}"
$ZSHRC_MARKER_END
EOF
    ok "auto-activate block written to ~/.zshrc"
}

# ---------------------------------------------------------------------------
# pip installs into the venv
# ---------------------------------------------------------------------------
step_pip() {
    log "Step: pip install polars pyarrow requests boto3 duckdb (into $VENV_PATH)"
    if [[ ! -x "$VENV_PATH/bin/pip" ]]; then
        err "venv pip missing — run --only=venv first"
        return 1
    fi
    "$VENV_PATH/bin/pip" install --upgrade pip
    "$VENV_PATH/bin/pip" install --upgrade polars pyarrow requests boto3 duckdb
    ok "polars, pyarrow, requests, boto3, duckdb installed"
}

# ---------------------------------------------------------------------------
# install latest duckdb CLI
# ---------------------------------------------------------------------------
step_duckdb_cli() {
    log "Step: install duckdb CLI $DUCKDB_VERSION"
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN EXIT

    log "  downloading $DUCKDB_CLI_URL"
    curl -fL --progress-bar -o "$tmp/duckdb_cli.zip" "$DUCKDB_CLI_URL"
    verify_sha256 "$tmp/duckdb_cli.zip" "$DUCKDB_SHA256"

    log "  extracting"
    unzip -o -q "$tmp/duckdb_cli.zip" -d "$tmp"

    sudo install -m 0755 "$tmp/duckdb" "$BIN_DIR/duckdb"
    ok "duckdb CLI installed: $("$BIN_DIR/duckdb" --version)"
}

# ---------------------------------------------------------------------------
# install latest yazi (yazi TUI + ya CLI)
# ---------------------------------------------------------------------------
step_yazi() {
    log "Step: install yazi $YAZI_VERSION"
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN EXIT

    log "  downloading $YAZI_URL"
    curl -fL --progress-bar -o "$tmp/yazi.zip" "$YAZI_URL"
    verify_sha256 "$tmp/yazi.zip" "$YAZI_SHA256"

    log "  extracting"
    unzip -o -q "$tmp/yazi.zip" -d "$tmp"

    # The release zip extracts into a versioned dir like yazi-<arch>-unknown-linux-gnu/.
    local extracted
    extracted=$(find "$tmp" -maxdepth 2 -type f -name yazi -executable | head -1)
    if [[ -z "$extracted" ]]; then
        err "yazi binary not found in extracted archive"
        return 1
    fi
    local extracted_dir
    extracted_dir=$(dirname "$extracted")

    sudo install -m 0755 "$extracted_dir/yazi" "$BIN_DIR/yazi"
    sudo install -m 0755 "$extracted_dir/ya"   "$BIN_DIR/ya"
    ok "yazi installed: $("$BIN_DIR/yazi" --version)"
}

# ---------------------------------------------------------------------------
# install latest git-delta + wire into ~/.gitconfig
# ---------------------------------------------------------------------------
step_delta() {
    log "Step: install git-delta $DELTA_VERSION"
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN EXIT

    local version="$DELTA_VERSION"
    local url="https://github.com/$DELTA_REPO/releases/download/${version}/delta-${version}-$ARCH_RUST-unknown-linux-gnu.tar.gz"

    log "  downloading $url"
    curl -fL --progress-bar -o "$tmp/delta.tar.gz" "$url"
    verify_sha256 "$tmp/delta.tar.gz" "$DELTA_SHA256"

    log "  extracting"
    tar -C "$tmp" -xzf "$tmp/delta.tar.gz"

    local extracted
    extracted=$(find "$tmp" -maxdepth 2 -type f -name delta -executable | head -1)
    if [[ -z "$extracted" ]]; then
        err "delta binary not found in extracted archive"
        return 1
    fi

    sudo install -m 0755 "$extracted" "$BIN_DIR/delta"
    ok "delta installed: $("$BIN_DIR/delta" --version)"

    log "  wiring delta into ~/.gitconfig"
    git config --global core.pager "delta"
    git config --global interactive.diffFilter "delta --color-only"
    git config --global delta.navigate true
    git config --global delta.line-numbers true
    git config --global merge.conflictstyle zdiff3
    ok "git pager configured to delta"
}

# ---------------------------------------------------------------------------
# install xterm-ghostty terminfo
# ---------------------------------------------------------------------------
step_ghostty() {
    log "Step: install xterm-ghostty terminfo"
    if infocmp xterm-ghostty >/dev/null 2>&1; then
        ok "xterm-ghostty terminfo already present"
        return 0
    fi
    if ! command -v tic >/dev/null; then
        err "tic not found — install ncurses-bin first"
        return 1
    fi
    if [ ! -f "$GHOSTTY_TERMINFO_FILE" ]; then
        err "vendored terminfo not found at $GHOSTTY_TERMINFO_FILE"
        err "regenerate on a Ghostty-equipped machine: infocmp -x xterm-ghostty > $GHOSTTY_TERMINFO_FILE"
        return 1
    fi

    log "  compiling $GHOSTTY_TERMINFO_FILE with tic -x"
    # tic emits a non-fatal warning about description-field aliases on older
    # versions; success is determined by exit code, not stderr noise.
    tic -x "$GHOSTTY_TERMINFO_FILE" 2>&1 | grep -v "older tic versions" || true
    if infocmp xterm-ghostty >/dev/null 2>&1; then
        ok "xterm-ghostty terminfo installed"
    else
        err "tic ran but xterm-ghostty still not found"
        return 1
    fi
}

# ---------------------------------------------------------------------------
# install latest neovim from official tarball
# ---------------------------------------------------------------------------
step_nvim() {
    log "Step: install neovim $NVIM_VERSION"
    local tmp
    tmp=$(mktemp -d)
    trap "rm -rf '$tmp'" RETURN EXIT

    log "  downloading $NVIM_TARBALL_URL"
    curl -fL --progress-bar -o "$tmp/nvim.tar.gz" "$NVIM_TARBALL_URL"
    verify_sha256 "$tmp/nvim.tar.gz" "$NVIM_SHA256"

    log "  extracting to $OPT_DIR"
    sudo rm -rf "$NVIM_INSTALL_DIR"
    # Unpacking as root: don't let the archive pick owners or modes.
    sudo tar -C "$OPT_DIR" --no-same-owner --no-same-permissions -xzf "$tmp/nvim.tar.gz"

    sudo ln -sf "$NVIM_INSTALL_DIR/bin/nvim" "$BIN_DIR/nvim"
    ok "nvim installed: $("$BIN_DIR/nvim" --version | head -1)"
}

# ---------------------------------------------------------------------------
# LazyVim
# ---------------------------------------------------------------------------
step_lazyvim() {
    log "Step: install LazyVim"
    local nvim_cfg="$HOME/.config/nvim"
    if [[ -f "$nvim_cfg/lua/config/lazy.lua" ]]; then
        ok "LazyVim already installed at $nvim_cfg"
    else
        if [[ -d "$nvim_cfg" ]]; then
            local backup="$nvim_cfg.bak.$(date +%s)"
            warn "existing nvim config found — backing up to $backup"
            mv "$nvim_cfg" "$backup"
        fi
        # Also back up the other state dirs LazyVim docs recommend clearing.
        for d in "$HOME/.local/share/nvim" "$HOME/.local/state/nvim" "$HOME/.cache/nvim"; do
            if [[ -d "$d" ]]; then
                mv "$d" "$d.bak.$(date +%s)"
                warn "backed up $d"
            fi
        done
        git clone https://github.com/LazyVim/starter "$nvim_cfg"
        rm -rf "$nvim_cfg/.git"
        ok "LazyVim starter cloned to $nvim_cfg"
        warn "run \`nvim\` once interactively to let Lazy install plugins"
    fi

    # Drop a plugin spec that registers gruvbox and tells LazyVim to use it.
    # Re-written every run so the colorscheme stays pinned even if the user
    # later edits this file by hand and we re-run the script.
    local plugins_dir="$nvim_cfg/lua/plugins"
    mkdir -p "$plugins_dir"
    cat > "$plugins_dir/colorscheme.lua" <<'EOF'
return {
  { "ellisonleao/gruvbox.nvim", lazy = false, priority = 1000 },
  {
    "LazyVim/LazyVim",
    opts = {
      colorscheme = "gruvbox",
    },
  },
}
EOF
    ok "gruvbox colorscheme plugin spec written to $plugins_dir/colorscheme.lua"

    # Drop a plugin spec wiring up yazi.nvim. Requires the `yazi` binary on
    # PATH (provided by step_yazi). snacks.nvim is already a LazyVim default
    # dependency, so no extra plugin pull is needed for it.
    cat > "$plugins_dir/yazi.lua" <<'EOF'
return {
  {
    "mikavilpas/yazi.nvim",
    event = "VeryLazy",
    dependencies = { "folke/snacks.nvim" },
    keys = {
      { "<leader>-",  mode = { "n", "v" }, "<cmd>Yazi<cr>",        desc = "Open yazi at the current file" },
      { "<leader>cw", "<cmd>Yazi cwd<cr>",                          desc = "Open yazi in nvim's working directory" },
      { "<c-up>",     "<cmd>Yazi toggle<cr>",                       desc = "Resume the last yazi session" },
    },
    opts = {
      open_for_directories = false,
      keymaps = { show_help = "<f1>" },
    },
  },
}
EOF
    ok "yazi.nvim plugin spec written to $plugins_dir/yazi.lua"
}

# ---------------------------------------------------------------------------
# tmux config
# ---------------------------------------------------------------------------
step_tmux() {
    log "Step: tmux config from amritharun/dotfiles"
    local conf="$HOME/.tmux.conf"
    if [[ ! -f "$conf" ]] || [[ "$FORCE_TMUX" -eq 1 ]]; then
        if [[ -f "$conf" ]]; then
            local backup="$conf.bak.$(date +%s)"
            warn "backing up existing $conf to $backup"
            mv "$conf" "$backup"
        fi
        curl -fL --progress-bar -o "$conf" "$TMUX_CONF_URL"
        ok "$conf fetched from upstream"
    else
        ok "$conf already exists (use --force-tmux to refetch)"
    fi

    # If tmux is already running, reload the config so changes apply now.
    if command -v tmux >/dev/null && tmux info >/dev/null 2>&1; then
        tmux source-file "$conf" 2>/dev/null && ok "live tmux server reloaded" || warn "could not reload live tmux server"
    fi
}

# ---------------------------------------------------------------------------
# docker socket permissions for docker-in-docker
# ---------------------------------------------------------------------------
step_docker() {
    log "Step: docker socket access for docker-in-docker"
    if [[ ! -S "$DOCKER_SOCK" ]]; then
        warn "$DOCKER_SOCK not found — skipping (docker not mounted?)"
        return 0
    fi

    # docker-outside-of-docker bind-mounts the host's socket and leaves a
    # symlink at $DOCKER_SOCK; permissions and ACLs live on the target.
    local sock user
    sock="$(readlink -f "$DOCKER_SOCK")"
    user="$(id -un)"

    if [[ -w "$sock" ]]; then
        ok "$sock is already writable by $user"
        return 0
    fi

    # Grant exactly one user access, rather than chmod 666. Write access to the
    # docker socket is equivalent to root on the docker host, so it must not go
    # to every process in the container. An ACL also takes effect immediately,
    # which added group membership does not.
    #
    # Two things this does not do. The entry lands on the bind-mounted inode,
    # i.e. on the docker host, and nothing here ever revokes it — it outlives
    # the pod. And ACLs record a numeric uid, so if this container's uid maps to
    # a different person on the host, that account inherits the grant.
    if command -v setfacl >/dev/null; then
        if sudo setfacl -m "u:$user:rw" "$sock" && [[ -w "$sock" ]]; then
            ok "granted $user rw on $sock via ACL"
            return 0
        fi
        warn "ACL did not take effect — falling back to group membership"
    else
        warn "setfacl not found (apt package 'acl') — falling back to group membership"
    fi

    # Fallback. The socket's GID comes from the docker host, so inside this
    # container it may name an unrelated group (or none at all) — resolve it by
    # number and create a group for it if nothing owns that GID here.
    local gid group entry
    gid="$(stat -c '%g' "$sock")"
    # getent exits 2 when no group owns the gid, which under pipefail would
    # abort the step instead of falling through to creating one.
    group=""
    if entry="$(getent group "$gid")"; then
        group="${entry%%:*}"
    fi
    if [[ -z "$group" ]]; then
        group="docker-host"
        if ! sudo groupadd -g "$gid" "$group"; then
            err "could not create a group for gid $gid — docker will stay unusable"
            return 1
        fi
        ok "created group '$group' for gid $gid"
    fi
    if ! sudo usermod -aG "$group" "$user"; then
        err "could not add $user to '$group' — docker will stay unusable"
        return 1
    fi
    ok "added $user to '$group' (gid $gid)"
    warn "group membership applies to NEW login sessions only — run 'newgrp $group'"
    warn "or reconnect to the pod before using docker"
}

# ---------------------------------------------------------------------------
# Driver
# ---------------------------------------------------------------------------
main() {
    log "Devpod setup starting"
    log "user=$(whoami) host=$(hostname) home=$HOME arch=$(uname -m)"
    echo

    local ran=()
    local skipped=()
    local failed=()
    for step in "${ALL_STEPS[@]}"; do
        if ! should_run "$step"; then
            skipped+=("$step")
            continue
        fi
        # Each step runs in a subshell so one failure doesn't abort the run.
        # The `set +e` / `set -e` dance around it is load-bearing: bash suspends
        # errexit for the whole of an `if`/`||` condition and that suspension is
        # inherited by subshells, so `if ( set -e; step ); then` would let a step
        # keep running past its own failed command. Invoking outside a condition
        # context is what lets the inner `set -e` actually bite.
        local status=0
        set +e
        ( set -e; "step_$step" )
        status=$?
        set -e
        if (( status == 0 )); then
            ran+=("$step")
        else
            err "step '$step' failed (exit $status) — continuing with the remaining steps"
            failed+=("$step")
        fi
        echo
    done

    log "Done."
    log "Ran:     ${ran[*]:-(none)}"
    log "Skipped: ${skipped[*]:-(none)}"
    if (( ${#failed[@]} > 0 )); then
        log "Failed:  ${failed[*]}"
    fi
    echo
    log "Next steps:"
    log "  1. Run \`nvim\` once to let LazyVim install plugins"
    log "  2. Run \`tmux\` to verify your config loads cleanly"
    echo

    if (( ${#failed[@]} > 0 )); then
        err "${#failed[@]} step(s) failed: ${failed[*]}"
        err "re-run just those with: $0 --only=$(IFS=,; echo "${failed[*]}")"
        return 1
    fi
    if [[ "$NO_SHELL" -eq 1 ]]; then
        log "Skipping shell exec (--no-shell). Source ~/.zshrc manually to activate the venv."
        return 0
    fi
    if [[ ! -t 1 ]]; then
        log "Non-interactive stdout — skipping shell exec. Source ~/.zshrc manually to activate the venv."
        return 0
    fi
    log "Replacing current shell with a fresh zsh so the venv auto-activates..."
    exec zsh -l
}

# Run only when executed, not when sourced — tests/ sources this file to call
# individual step functions in isolation.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main
fi
