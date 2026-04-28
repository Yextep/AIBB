#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

export DEBIAN_FRONTEND="${DEBIAN_FRONTEND:-noninteractive}"

AUTO_BOUNTY_VERSION="1.0.0"
AB_HOME="${AUTO_BOUNTY_HOME:-$HOME/.auto-bounty}"
TOOLS_DIR="${AUTO_BOUNTY_TOOLS:-$AB_HOME/tools}"
LOG_DIR="$AB_HOME/logs"
PIPX_HOME="${PIPX_HOME:-$AB_HOME/pipx}"

if [[ -n "${AUTO_BOUNTY_BIN:-}" ]]; then
  BIN_DIR="$AUTO_BOUNTY_BIN"
elif [[ "${EUID:-$(id -u)}" -eq 0 && -d /usr/local/bin && -w /usr/local/bin ]]; then
  BIN_DIR="/usr/local/bin"
else
  BIN_DIR="$HOME/.local/bin"
fi

export GOBIN="$BIN_DIR"
export PIPX_HOME
export PIPX_BIN_DIR="$BIN_DIR"
export PATH="$BIN_DIR:$HOME/.cargo/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"

SKIP_SYSTEM=0
VERIFY_ONLY=0
NO_GIT_PULL=0
WITH_BROWSER=0
PLATFORM="unknown"
LOG_FILE=""

OK=()
FAILED=()
WARNINGS=()

banner() {
  cat <<'EOF'
    ___         __        ____                  __
   /   | __  __/ /_____  / __ )____  __  ______/ /___  __
  / /| |/ / / / __/ __ \/ __  / __ \/ / / / __  / __ \/ /
 / ___ / /_/ / /_/ /_/ / /_/ / /_/ / /_/ / /_/ / / / /_/
/_/  |_\__,_/\__/\____/_____/\____/\__,_/\__,_/_/ /_(_)

                    A U T O   B O U N T Y
EOF
}

usage() {
  cat <<EOF
AUTO BOUNTY installer v$AUTO_BOUNTY_VERSION

Usage:
  bash install.sh [options]

Options:
  --verify-only        Only verify tools already installed.
  --skip-system        Do not install system packages.
  --bin-dir DIR        Install Go/Python/release binaries in DIR.
  --tools-dir DIR      Clone source repositories in DIR.
  --no-git-pull        Do not update already cloned repositories.
  --with-browser       Try to install Chromium for screenshot/browser tools.
  -h, --help           Show this help.

Environment overrides:
  AUTO_BOUNTY_HOME     Default: $HOME/.auto-bounty
  AUTO_BOUNTY_BIN      Default: /usr/local/bin when root, otherwise ~/.local/bin
  AUTO_BOUNTY_TOOLS    Default: ~/.auto-bounty/tools
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --verify-only)
        VERIFY_ONLY=1
        ;;
      --skip-system)
        SKIP_SYSTEM=1
        ;;
      --bin-dir)
        [[ $# -ge 2 ]] || die "--bin-dir requires a directory"
        BIN_DIR="$2"
        export GOBIN="$BIN_DIR"
        export PIPX_BIN_DIR="$BIN_DIR"
        export PATH="$BIN_DIR:$PATH"
        shift
        ;;
      --tools-dir)
        [[ $# -ge 2 ]] || die "--tools-dir requires a directory"
        TOOLS_DIR="$2"
        ;;
      --no-git-pull)
        NO_GIT_PULL=1
        ;;
      --with-browser)
        WITH_BROWSER=1
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

init_logging() {
  mkdir -p "$LOG_DIR" "$TOOLS_DIR" "$BIN_DIR"
  LOG_FILE="$LOG_DIR/install-$(date -u +%Y%m%dT%H%M%SZ).log"
  touch "$LOG_FILE"
  exec > >(tee -a "$LOG_FILE") 2>&1
}

log() {
  printf '[%s] [INFO] %s\n' "$(date -u +%H:%M:%S)" "$*"
}

warn() {
  WARNINGS+=("$*")
  printf '[%s] [WARN] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

err() {
  printf '[%s] [ERROR] %s\n' "$(date -u +%H:%M:%S)" "$*" >&2
}

die() {
  err "$*"
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

as_root() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    "$@"
  elif have sudo; then
    sudo "$@"
  else
    err "Root privileges or sudo are required for: $*"
    return 1
  fi
}

retry() {
  local attempts="$1"
  shift
  local n=1
  local delay=2
  local rc=0

  while (( n <= attempts )); do
    "$@" && return 0
    rc=$?
    if (( n == attempts )); then
      return "$rc"
    fi
    warn "Retry $n/$attempts failed: $*"
    sleep "$delay"
    delay=$((delay * 2))
    n=$((n + 1))
  done

  return "$rc"
}

detect_platform() {
  local os_id=""
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    os_id="${ID:-}"
  fi

  case "$os_id" in
    debian|ubuntu|kali|parrot)
      PLATFORM="apt"
      ;;
    fedora)
      PLATFORM="dnf"
      ;;
    arch|manjaro)
      PLATFORM="pacman"
      ;;
    alpine)
      PLATFORM="apk"
      ;;
    *)
      if have brew; then
        PLATFORM="brew"
      elif [[ -n "${TERMUX_VERSION:-}" || "${PREFIX:-}" == *"/com.termux/files/usr"* ]]; then
        PLATFORM="termux"
      elif have apt-get; then
        PLATFORM="apt"
      else
        PLATFORM="unknown"
      fi
      ;;
  esac

  log "Detected platform: $PLATFORM ($(uname -m))"
}

install_system_packages() {
  case "$PLATFORM" in
    apt)
      install_apt_packages
      ;;
    termux)
      install_termux_packages
      ;;
    dnf)
      install_dnf_packages
      ;;
    pacman)
      install_pacman_packages
      ;;
    apk)
      install_apk_packages
      ;;
    brew)
      install_brew_packages
      ;;
    *)
      warn "No supported package manager detected. Continuing with existing dependencies."
      ;;
  esac
}

apt_has_package() {
  apt-cache show "$1" >/dev/null 2>&1
}

install_apt_packages() {
  log "Refreshing apt repositories"
  retry 3 as_root apt-get update -y || return 1

  local wanted=(
    ca-certificates curl wget git unzip zip tar gzip xz-utils
    build-essential make gcc g++ clang pkg-config
    libpcap-dev libssl-dev zlib1g-dev libcurl4-openssl-dev
    libxml2-dev libxslt1-dev libsqlite3-dev libcap2-bin
    python3 python3-pip python3-venv pipx
    ruby ruby-dev ruby-bundler
    golang-go rustc cargo
    nmap masscan dnsutils jq whois
  )

  if (( WITH_BROWSER == 1 )); then
    wanted+=(chromium chromium-headless-shell)
  fi

  local pkgs=()
  local pkg
  for pkg in "${wanted[@]}"; do
    if apt_has_package "$pkg"; then
      pkgs+=("$pkg")
    else
      warn "Apt package not found, skipping: $pkg"
    fi
  done

  if ((${#pkgs[@]} == 0)); then
    warn "No apt packages selected."
    return 0
  fi

  log "Installing system packages with apt"
  retry 2 as_root apt-get install -y --no-install-recommends "${pkgs[@]}" || \
    retry 2 as_root apt-get install -y "${pkgs[@]}" || return 1
}

install_termux_packages() {
  log "Refreshing Termux repositories"
  retry 3 pkg update -y || return 1
  local pkgs=(
    ca-certificates curl wget git unzip zip tar xz-utils
    make clang binutils pkg-config openssl libpcap
    python pipx ruby golang rust
    nmap masscan dnsutils jq whois
  )
  if (( WITH_BROWSER == 1 )); then
    pkgs+=(chromium)
  fi
  retry 2 pkg install -y "${pkgs[@]}" || return 1
}

install_dnf_packages() {
  local pkgs=(
    ca-certificates curl wget git unzip zip tar gzip xz
    @development-tools make gcc gcc-c++ clang pkgconf-pkg-config
    libpcap-devel openssl-devel zlib-devel libcurl-devel
    libxml2-devel libxslt-devel sqlite-devel libcap
    python3 python3-pip pipx ruby ruby-devel golang rust cargo
    nmap masscan bind-utils jq whois
  )
  retry 2 as_root dnf install -y "${pkgs[@]}" || return 1
}

install_pacman_packages() {
  local pkgs=(
    ca-certificates curl wget git unzip zip tar gzip xz
    base-devel make gcc clang pkgconf
    libpcap openssl zlib curl libxml2 libxslt sqlite libcap
    python python-pip python-pipx ruby go rust cargo
    nmap masscan bind jq whois
  )
  retry 2 as_root pacman -Sy --needed --noconfirm "${pkgs[@]}" || return 1
}

install_apk_packages() {
  local pkgs=(
    ca-certificates curl wget git unzip zip tar gzip xz
    build-base make gcc g++ clang pkgconf
    libpcap-dev openssl-dev zlib-dev curl-dev
    libxml2-dev libxslt-dev sqlite-dev libcap
    python3 py3-pip py3-pipx ruby ruby-dev go rust cargo
    nmap masscan bind-tools jq whois
  )
  retry 2 as_root apk add --no-cache "${pkgs[@]}" || return 1
}

install_brew_packages() {
  local pkgs=(
    ca-certificates curl wget git unzip zip
    pkg-config libpcap openssl zlib
    python pipx ruby go rust nmap masscan jq
    ffuf findomain amass
  )
  retry 2 brew install "${pkgs[@]}" || true
}

write_env_file() {
  mkdir -p "$AB_HOME" "$BIN_DIR" "$TOOLS_DIR"
  {
    printf '# Auto Bounty environment\n'
    printf 'export AUTO_BOUNTY_HOME=%q\n' "$AB_HOME"
    printf 'export AUTO_BOUNTY_TOOLS=%q\n' "$TOOLS_DIR"
    printf 'export PATH=%q:$PATH\n' "$BIN_DIR"
    printf 'export PATH=%q:$PATH\n' "$HOME/.cargo/bin"
    printf 'export PATH=%q:$PATH\n' "$HOME/go/bin"
    printf 'export PATH=%q:$PATH\n' "/usr/local/go/bin"
  } > "$AB_HOME/env"

  local rc_file="$HOME/.bashrc"
  if [[ -f "$rc_file" ]] && ! grep -Fq "$AB_HOME/env" "$rc_file"; then
    {
      printf '\n# Auto Bounty tools\n'
      printf '[ -f %q ] && . %q\n' "$AB_HOME/env" "$AB_HOME/env"
    } >> "$rc_file"
    log "Added Auto Bounty PATH loader to $rc_file"
  fi
}

run_tool_step() {
  local name="$1"
  shift
  log "Installing/verifying $name"
  set +e
  "$@"
  local rc=$?
  set -e
  if (( rc == 0 )); then
    OK+=("$name")
    log "OK: $name"
  else
    FAILED+=("$name")
    err "FAILED: $name"
  fi
}

ensure_python_bootstrap() {
  have python3 || return 1
  if ! python3 -m pip --version >/dev/null 2>&1; then
    warn "python3 -m pip is not available"
    return 1
  fi
  if ! python3 -m pipx --version >/dev/null 2>&1; then
    log "Installing pipx with pip"
    python3 -m pip install --user --break-system-packages pipx || \
      python3 -m pip install --user pipx || return 1
  fi
}

install_pipx_package() {
  local name="$1"
  local spec="$2"
  local binary="$3"

  if [[ "${AUTO_BOUNTY_FORCE_UPDATE:-0}" != "1" ]] && verify_command "$binary" >/dev/null 2>&1; then
    log "$name already installed"
    return 0
  fi

  ensure_python_bootstrap || return 1
  retry 2 python3 -m pipx install --force "$spec" || return 1
  verify_command "$binary" || return 1
  log "$name installed with pipx"
}

clone_or_update() {
  local repo="$1"
  local dest="$2"

  if [[ -d "$dest/.git" ]]; then
    git -C "$dest" remote set-url origin "$repo" || return 1
    if (( NO_GIT_PULL == 0 )); then
      log "Updating $dest"
      git -C "$dest" pull --ff-only --tags || {
        warn "Fast-forward pull failed for $dest; trying fetch only"
        git -C "$dest" fetch --all --tags --prune || return 1
      }
    fi
    return 0
  fi

  if [[ -e "$dest" ]]; then
    local backup="${dest}.backup.$(date -u +%Y%m%dT%H%M%SZ)"
    warn "$dest exists and is not a git repository. Moving it to $backup"
    mv "$dest" "$backup" || return 1
  fi

  mkdir -p "$(dirname "$dest")"
  git clone --depth 1 "$repo" "$dest" || git clone "$repo" "$dest" || return 1
}

write_python_wrapper() {
  local command_name="$1"
  local repo_dir="$2"
  local python_bin="$3"
  local script_path="$4"
  local wrapper="$BIN_DIR/$command_name"
  local tmp
  tmp="$(mktemp)" || return 1

  {
    printf '#!/usr/bin/env bash\n'
    printf 'cd %q\n' "$repo_dir"
    printf 'exec %q %q "$@"\n' "$python_bin" "$script_path"
  } > "$tmp"

  install -m 0755 "$tmp" "$wrapper" || {
    rm -f "$tmp"
    return 1
  }
  rm -f "$tmp"
}

install_python_repo() {
  local name="$1"
  local repo="$2"
  local entry="$3"
  local command_name="$4"
  local repo_dir="$TOOLS_DIR/$name"
  local venv="$repo_dir/.venv"

  if [[ "${AUTO_BOUNTY_FORCE_UPDATE:-0}" != "1" ]] && verify_command "$command_name" >/dev/null 2>&1; then
    log "$name already installed"
    return 0
  fi

  clone_or_update "$repo" "$repo_dir" || return 1
  python3 -m venv "$venv" || return 1
  "$venv/bin/python" -m pip install --upgrade pip setuptools wheel || return 1

  if [[ -f "$repo_dir/requirements.txt" ]]; then
    "$venv/bin/python" -m pip install -r "$repo_dir/requirements.txt" || return 1
  fi

  if [[ -f "$repo_dir/pyproject.toml" || -f "$repo_dir/setup.py" ]]; then
    "$venv/bin/python" -m pip install "$repo_dir" || warn "$name does not install as a Python package; wrapper fallback will be used"
  fi

  if [[ -n "$entry" && -f "$repo_dir/$entry" ]]; then
    write_python_wrapper "$command_name" "$repo_dir" "$venv/bin/python" "$repo_dir/$entry" || return 1
  elif [[ -x "$venv/bin/$command_name" ]]; then
    ln -sf "$venv/bin/$command_name" "$BIN_DIR/$command_name" || return 1
  else
    err "Could not find entrypoint for $name"
    return 1
  fi

  verify_command "$command_name" || return 1
}

release_os() {
  case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
    linux)
      printf 'linux'
      ;;
    darwin)
      printf 'macos'
      ;;
    mingw*|msys*|cygwin*)
      printf 'windows'
      ;;
    *)
      uname -s | tr '[:upper:]' '[:lower:]'
      ;;
  esac
}

release_arch() {
  case "$(uname -m)" in
    x86_64|amd64)
      printf 'amd64'
      ;;
    i386|i686)
      printf '386'
      ;;
    aarch64|arm64)
      printf 'arm64'
      ;;
    armv7l|armv7*)
      printf 'arm'
      ;;
    *)
      uname -m
      ;;
  esac
}

install_archive_binary_from_url() {
  local url="$1"
  local binary="$2"
  local digest="${3:-}"
  local tmp archive extract found

  tmp="$(mktemp -d)" || return 1
  archive="$tmp/archive"
  extract="$tmp/extract"
  mkdir -p "$extract"

  log "Downloading release asset: $url"
  curl -fL --retry 3 --retry-delay 2 -o "$archive" "$url" || {
    rm -rf "$tmp"
    return 1
  }

  if [[ "$digest" == sha256:* ]] && have sha256sum; then
    local expected actual
    expected="${digest#sha256:}"
    actual="$(sha256sum "$archive" | awk '{print $1}')"
    if [[ "$expected" != "$actual" ]]; then
      err "Checksum mismatch for $url"
      rm -rf "$tmp"
      return 1
    fi
  fi

  case "$url" in
    *.zip)
      unzip -qo "$archive" -d "$extract" || {
        rm -rf "$tmp"
        return 1
      }
      ;;
    *.tar.gz|*.tgz)
      tar -xzf "$archive" -C "$extract" || {
        rm -rf "$tmp"
        return 1
      }
      ;;
    *)
      install -m 0755 "$archive" "$BIN_DIR/$binary" || {
        rm -rf "$tmp"
        return 1
      }
      rm -rf "$tmp"
      verify_command "$binary" || return 1
      return 0
      ;;
  esac

  found="$(find "$extract" -type f \( -name "$binary" -o -name "$binary.exe" \) -print | head -n 1)"
  if [[ -z "$found" ]]; then
    found="$(find "$extract" -type f -perm -111 -print | head -n 1)"
  fi
  if [[ -z "$found" ]]; then
    err "Could not find $binary inside release archive"
    rm -rf "$tmp"
    return 1
  fi

  install -m 0755 "$found" "$BIN_DIR/$binary" || {
    rm -rf "$tmp"
    return 1
  }
  rm -rf "$tmp"
  verify_command "$binary" || return 1
}

install_github_release_binary() {
  local repo="$1"
  local binary="$2"
  local prefix="$3"
  local os_filter
  local arch_filter
  local api json info url digest

  if [[ $# -ge 4 ]]; then
    os_filter="$4"
  else
    os_filter="$(release_os)"
  fi
  if [[ $# -ge 5 ]]; then
    arch_filter="$5"
  else
    arch_filter="$(release_arch)"
  fi

  have curl || return 1
  have jq || return 1
  api="https://api.github.com/repos/$repo/releases/latest"
  json="$(mktemp)" || return 1

  curl -fsSL "$api" -o "$json" || {
    rm -f "$json"
    return 1
  }

  info="$(jq -r \
    --arg prefix "$prefix" \
    --arg os "$os_filter" \
    --arg arch "$arch_filter" \
    '.assets[]
      | (.name | ascii_downcase) as $n
      | ($prefix | ascii_downcase) as $p
      | select($n | startswith($p))
      | select(($os == "") or ($n | contains($os)))
      | select(($arch == "") or ($n | contains($arch)))
      | select($n | test("\\.(zip|tar\\.gz|tgz)$"))
      | [.browser_download_url, (.digest // "")] | @tsv' "$json" | head -n 1)"
  rm -f "$json"

  if [[ -z "$info" ]]; then
    err "No compatible release asset found for $repo ($prefix, $os_filter, $arch_filter)"
    return 1
  fi

  IFS=$'\t' read -r url digest <<< "$info"
  install_archive_binary_from_url "$url" "$binary" "$digest"
}

install_go_or_release() {
  local name="$1"
  local binary="$2"
  local repo="$3"
  local prefix="$4"
  local cgo="$5"
  shift 5

  if [[ "${AUTO_BOUNTY_FORCE_UPDATE:-0}" != "1" ]] && verify_command "$binary" >/dev/null 2>&1; then
    log "$name already installed"
    return 0
  fi

  if go_install_tool "$name" "$binary" "$cgo" "$@"; then
    return 0
  fi

  warn "$name Go install failed; trying official GitHub release"
  install_github_release_binary "$repo" "$binary" "$prefix" || return 1
}

install_release_or_go() {
  local name="$1"
  local binary="$2"
  local repo="$3"
  local prefix="$4"
  local cgo="$5"
  shift 5

  if [[ "${AUTO_BOUNTY_FORCE_UPDATE:-0}" != "1" ]] && verify_command "$binary" >/dev/null 2>&1; then
    log "$name already installed"
    return 0
  fi

  if install_github_release_binary "$repo" "$binary" "$prefix"; then
    return 0
  fi

  warn "$name release install failed; trying Go install"
  go_install_tool "$name" "$binary" "$cgo" "$@" || return 1
}

go_install_tool() {
  local name="$1"
  local binary="$2"
  local cgo="$3"
  shift 3
  local module

  have go || return 1
  mkdir -p "$BIN_DIR"

  if [[ "${AUTO_BOUNTY_FORCE_UPDATE:-0}" != "1" ]] && verify_command "$binary" >/dev/null 2>&1; then
    log "$name already installed"
    return 0
  fi

  for module in "$@"; do
    log "Trying $name from $module"
    if [[ -n "$cgo" ]]; then
      if retry 2 env GOBIN="$BIN_DIR" CGO_ENABLED="$cgo" GOTOOLCHAIN=local go install -v "$module"; then
        if [[ -x "$BIN_DIR/$binary" ]] || have "$binary"; then
          verify_command "$binary" || return 1
          return 0
        fi
      fi
    else
      if retry 2 env GOBIN="$BIN_DIR" GOTOOLCHAIN=local go install -v "$module"; then
        if [[ -x "$BIN_DIR/$binary" ]] || have "$binary"; then
          verify_command "$binary" || return 1
          return 0
        fi
      fi
    fi
    warn "$name install candidate failed: $module"
  done

  return 1
}

install_aquatone() {
  if [[ "${AUTO_BOUNTY_FORCE_UPDATE:-0}" != "1" ]] && verify_command aquatone >/dev/null 2>&1; then
    log "aquatone already installed"
    return 0
  fi

  local repo_dir="$TOOLS_DIR/aquatone"
  clone_or_update "https://github.com/michenriksen/aquatone.git" "$repo_dir" || return 1

  if [[ -f "$repo_dir/parsers/regex.go" ]]; then
    sed -i 's/xurls\.Relaxed()/xurls.Relaxed/g' "$repo_dir/parsers/regex.go" || return 1
  fi

  (
    cd "$repo_dir" || exit 1
    if [[ ! -f go.mod ]]; then
      go mod init github.com/michenriksen/aquatone
    fi
    go get \
      github.com/PuerkitoBio/goquery@v1.5.0 \
      github.com/andybalholm/cascadia@v1.0.0 \
      github.com/asaskevich/EventBus@d46933a94f05 \
      github.com/fatih/color@v1.7.0 \
      github.com/google/uuid@v1.1.1 \
      github.com/lair-framework/go-nmap@3b9bafddefee \
      github.com/mvdan/xurls@v1.1.0 \
      github.com/parnurzeal/gorequest@v0.2.15 \
      github.com/pkg/errors@v0.8.1 \
      github.com/pmezard/go-difflib@v1.0.0 \
      github.com/remeh/sizedwaitgroup@5e7302b12cce \
      golang.org/x/text@v0.3.2
    go mod tidy
    env GOBIN="$BIN_DIR" GOTOOLCHAIN=local go install .
  ) || return 1

  verify_command aquatone || return 1
}

install_findomain() {
  local arch cargo_bin rustc_bin
  arch="$(uname -m)"

  if [[ "${AUTO_BOUNTY_FORCE_UPDATE:-0}" != "1" ]] && verify_command findomain >/dev/null 2>&1; then
    log "findomain already installed"
    return 0
  fi

  case "$arch" in
    x86_64|amd64)
      if install_github_release_binary "Findomain/Findomain" "findomain" "findomain-linux.zip" "" ""; then
        return 0
      fi
      ;;
    aarch64|arm64)
      if install_github_release_binary "Findomain/Findomain" "findomain" "findomain-aarch64" "" ""; then
        return 0
      fi
      ;;
    armv7l|armv7*)
      if install_github_release_binary "Findomain/Findomain" "findomain" "findomain-armv7" "" ""; then
        return 0
      fi
      ;;
  esac

  warn "Findomain release download failed; trying cargo"

  cargo_bin=""
  for candidate in /usr/bin/cargo "$(command -v cargo 2>/dev/null || true)"; do
    if [[ -n "$candidate" && -x "$candidate" ]] && "$candidate" --version >/dev/null 2>&1; then
      cargo_bin="$candidate"
      break
    fi
  done
  [[ -n "$cargo_bin" ]] || return 1

  rustc_bin="$(command -v rustc 2>/dev/null || true)"
  if [[ -x /usr/bin/rustc ]]; then
    rustc_bin="/usr/bin/rustc"
  fi

  retry 2 env RUSTC="$rustc_bin" "$cargo_bin" install findomain --locked --force || \
    retry 2 env RUSTC="$rustc_bin" "$cargo_bin" install findomain --force || return 1
  if [[ -x "$HOME/.cargo/bin/findomain" && "$BIN_DIR" != "$HOME/.cargo/bin" ]]; then
    ln -sf "$HOME/.cargo/bin/findomain" "$BIN_DIR/findomain" || return 1
  fi
  verify_command findomain || return 1
}

install_wpscan() {
  if [[ "${AUTO_BOUNTY_FORCE_UPDATE:-0}" != "1" ]] && verify_command wpscan >/dev/null 2>&1; then
    log "wpscan already installed"
    return 0
  fi

  have gem || return 1
  retry 2 env NOKOGIRI_USE_SYSTEM_LIBRARIES=true gem install wpscan --no-document || return 1
  verify_command wpscan || return 1
}

install_gf_patterns() {
  go_install_tool "gf" "gf" "" "github.com/tomnomnom/gf@latest" || return 1

  local gf_src="$TOOLS_DIR/gf-source"
  local gf_extra="$TOOLS_DIR/gf-patterns"
  mkdir -p "$HOME/.gf"

  clone_or_update "https://github.com/tomnomnom/gf.git" "$gf_src" || warn "Could not clone gf examples"
  if [[ -d "$gf_src/examples" ]]; then
    cp -n "$gf_src/examples/"*.json "$HOME/.gf/" 2>/dev/null || true
  fi

  clone_or_update "https://github.com/1ndianl33t/Gf-Patterns.git" "$gf_extra" || warn "Could not clone extra gf patterns"
  if [[ -d "$gf_extra" ]]; then
    cp -n "$gf_extra/"*.json "$HOME/.gf/" 2>/dev/null || true
  fi

  verify_command gf || return 1
}

install_aliases() {
  if [[ -x "$BIN_DIR/httpx" ]]; then
    ln -sf "$BIN_DIR/httpx" "$BIN_DIR/httpx-toolkit" || return 1
  fi

  if [[ -x "$BIN_DIR/Gxss" ]]; then
    ln -sf "$BIN_DIR/Gxss" "$BIN_DIR/gxss" || true
  fi

  if [[ -x "$BIN_DIR/corscanner" ]]; then
    ln -sf "$BIN_DIR/corscanner" "$BIN_DIR/CORScanner" || true
  fi
}

install_nuclei_templates() {
  if have nuclei; then
    nuclei -update-templates -silent >/dev/null 2>&1 || nuclei -ut -silent >/dev/null 2>&1 || warn "Could not update nuclei templates automatically"
  fi
}

try_setcap() {
  local binary="$1"
  local path=""
  path="$(command -v "$binary" 2>/dev/null || true)"
  [[ -n "$path" ]] || return 0
  have setcap || return 0
  as_root setcap cap_net_raw,cap_net_admin=eip "$path" >/dev/null 2>&1 || warn "Could not set raw-socket capabilities on $binary; run it with root privileges if needed"
}

verify_command() {
  local cmd="$1"
  local path=""
  path="$(command -v "$cmd" 2>/dev/null || true)"
  if [[ -z "$path" ]]; then
    err "Command not found in PATH: $cmd"
    return 1
  fi

  local tmp arg rc
  tmp="$(mktemp)" || return 1
  local probes=(--version -version version -h --help)

  for arg in "${probes[@]}"; do
    set +e
    if have timeout; then
      timeout 45 "$path" "$arg" >"$tmp" 2>&1
    else
      "$path" "$arg" >"$tmp" 2>&1
    fi
    rc=$?
    set -e

    if (( rc == 0 )) || grep -Eiq 'usage|options|flags|help|version|examples|commands' "$tmp"; then
      rm -f "$tmp"
      return 0
    fi
  done

  err "$cmd exists at $path but did not pass help/version probes"
  sed -n '1,12p' "$tmp" >&2 || true
  rm -f "$tmp"
  return 1
}

install_go_tools() {
  run_tool_step "subzy" go_install_tool "subzy" "subzy" "" \
    "github.com/PentestPad/subzy@latest" \
    "github.com/LukaSikic/subzy@latest"

  run_tool_step "qsreplace" go_install_tool "qsreplace" "qsreplace" "" \
    "github.com/tomnomnom/qsreplace@latest"

  run_tool_step "bxss" go_install_tool "bxss" "bxss" "" \
    "github.com/ethicalhackingplayground/bxss/v2/cmd/bxss@latest"

  run_tool_step "dalfox" go_install_tool "dalfox" "dalfox" "" \
    "github.com/hahwul/dalfox/v2@latest"

  run_tool_step "Gxss" go_install_tool "Gxss" "Gxss" "" \
    "github.com/KathanP19/Gxss@latest"

  run_tool_step "naabu" go_install_tool "naabu" "naabu" "1" \
    "github.com/projectdiscovery/naabu/v2/cmd/naabu@latest"

  run_tool_step "nuclei" install_release_or_go "nuclei" "nuclei" "projectdiscovery/nuclei" "nuclei" "" \
    "github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest"

  run_tool_step "gf" install_gf_patterns

  run_tool_step "urlfinder" go_install_tool "urlfinder" "urlfinder" "" \
    "github.com/projectdiscovery/urlfinder/cmd/urlfinder@latest"

  run_tool_step "gau" go_install_tool "gau" "gau" "" \
    "github.com/lc/gau/v2/cmd/gau@latest"

  run_tool_step "hakrawler" go_install_tool "hakrawler" "hakrawler" "" \
    "github.com/hakluke/hakrawler@latest"

  run_tool_step "katana" install_release_or_go "katana" "katana" "projectdiscovery/katana" "katana" "" \
    "github.com/projectdiscovery/katana/cmd/katana@latest"

  run_tool_step "aquatone" install_aquatone

  run_tool_step "httpx-toolkit" install_release_or_go "httpx-toolkit" "httpx" "projectdiscovery/httpx" "httpx" "" \
    "github.com/projectdiscovery/httpx/cmd/httpx@latest"

  run_tool_step "asnmap" go_install_tool "asnmap" "asnmap" "" \
    "github.com/projectdiscovery/asnmap/cmd/asnmap@latest"

  run_tool_step "ffuf" go_install_tool "ffuf" "ffuf" "" \
    "github.com/ffuf/ffuf/v2@latest"

  run_tool_step "dnsx" go_install_tool "dnsx" "dnsx" "" \
    "github.com/projectdiscovery/dnsx/cmd/dnsx@latest"

  run_tool_step "alterx" go_install_tool "alterx" "alterx" "" \
    "github.com/projectdiscovery/alterx/cmd/alterx@latest"

  run_tool_step "shosubgo" go_install_tool "shosubgo" "shosubgo" "" \
    "github.com/incogbyte/shosubgo@latest"

  run_tool_step "github-subdomains" go_install_tool "github-subdomains" "github-subdomains" "" \
    "github.com/gwen001/github-subdomains@latest"

  run_tool_step "assetfinder" go_install_tool "assetfinder" "assetfinder" "" \
    "github.com/tomnomnom/assetfinder@latest"

  run_tool_step "amass" go_install_tool "amass" "amass" "1" \
    "github.com/owasp-amass/amass/v5/cmd/amass@main" \
    "github.com/owasp-amass/amass/v4/cmd/amass@master" \
    "github.com/owasp-amass/amass/v4/cmd/amass@latest"

  run_tool_step "subfinder" go_install_tool "subfinder" "subfinder" "" \
    "github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest"
}

install_python_tools() {
  run_tool_step "CORScanner" install_python_repo "CORScanner" \
    "https://github.com/chenjj/CORScanner.git" "cors_scan.py" "corscanner"

  run_tool_step "Corsy" install_python_repo "Corsy" \
    "https://github.com/s0md3v/Corsy.git" "corsy.py" "corsy"

  run_tool_step "uro" install_pipx_package "uro" "uro" "uro"

  run_tool_step "dirsearch" install_dirsearch

  run_tool_step "arjun" install_pipx_package "arjun" "arjun" "arjun"
}

install_dirsearch() {
  install_python_repo "dirsearch" "https://github.com/maurosoria/dirsearch.git" "dirsearch.py" "dirsearch"
}

install_native_tools() {
  run_tool_step "curl" verify_command curl
  run_tool_step "masscan" verify_command masscan
  run_tool_step "nmap" verify_command nmap
  run_tool_step "wpscan" install_wpscan
  run_tool_step "findomain" install_findomain
}

verify_all_tools() {
  log "Running final verification"
  install_aliases || warn "Could not create all aliases"

  local commands=(
    curl
    subzy
    corscanner
    corsy
    qsreplace
    bxss
    dalfox
    Gxss
    uro
    masscan
    nmap
    naabu
    wpscan
    dirsearch
    arjun
    nuclei
    gf
    urlfinder
    gau
    hakrawler
    katana
    aquatone
    httpx-toolkit
    asnmap
    ffuf
    dnsx
    alterx
    shosubgo
    github-subdomains
    assetfinder
    findomain
    amass
    subfinder
  )

  local cmd
  local missing=0
  for cmd in "${commands[@]}"; do
    if verify_command "$cmd"; then
      log "Verified: $cmd"
    else
      FAILED+=("verify:$cmd")
      missing=1
    fi
  done

  try_setcap masscan
  try_setcap naabu

  return "$missing"
}

summary() {
  printf '\n'
  log "Log file: $LOG_FILE"
  log "Binary directory: $BIN_DIR"
  log "Tools directory: $TOOLS_DIR"

  if ((${#WARNINGS[@]} > 0)); then
    printf '\nWarnings:\n'
    printf '  - %s\n' "${WARNINGS[@]}"
  fi

  if ((${#FAILED[@]} > 0)); then
    printf '\nFailed items:\n'
    printf '  - %s\n' "${FAILED[@]}"
    printf '\nAUTO BOUNTY finished with errors. Check the log above and rerun the script after fixing the listed items.\n'
    exit 1
  fi

  printf '\nAUTO BOUNTY finished successfully. All requested tools were installed or verified.\n'
  printf 'Open a new shell or run: source %q\n' "$AB_HOME/env"
}

main() {
  parse_args "$@"
  init_logging
  banner
  log "Starting Auto Bounty installer v$AUTO_BOUNTY_VERSION"
  log "Use these tools only on assets where you have explicit authorization."
  detect_platform
  write_env_file

  if (( VERIFY_ONLY == 1 )); then
    verify_all_tools || true
    summary
    exit 0
  fi

  if (( SKIP_SYSTEM == 0 )); then
    run_tool_step "system-packages" install_system_packages
  else
    warn "Skipping system package installation by user request"
  fi

  run_tool_step "python-bootstrap" ensure_python_bootstrap
  install_native_tools
  install_go_tools
  install_python_tools
  install_aliases || warn "Could not create all aliases"
  install_nuclei_templates
  verify_all_tools || true
  summary
}

main "$@"
