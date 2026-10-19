#!/usr/bin/env bash
#
# envstrap.sh — 交互式 Linux 开发环境安装脚本
#
# 覆盖技术栈:
#   - Web 全栈: node (fnm/nvm), pnpm, git, docker, uv (python)
#   - ROS 2:    ros-<distro>-desktop, colcon, rosdep, vcs
#   - Rust:     rustup (用户级, 不碰系统 rust)
#   - STM32:    arm-none-eabi-gcc, cmake, ninja, openocd, udev 规则
#   - 镜像源:   npm/pnpm, PyPI(uv/pip), crates.io(cargo/rustup), Docker registry, ROS, apt
#
# 支持: Ubuntu / Debian (apt) 与 Fedora / RHEL (dnf)
#
# 特性: 幂等(已装则跳过), 失败不中断(最后汇总), 幂等可重复执行
#
# 用法:
#   ./envstrap.sh              # 交互式选择模块
#   ./envstrap.sh --all        # 安装全部模块(非交互)
#   ./envstrap.sh --dry-run    # 只打印将要执行的命令
#   ./envstrap.sh --list       # 列出模块
#   ./envstrap.sh -h           # 帮助
#
set -uo pipefail

# ---------------------------------------------------------------------------
# 全局状态
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
INSTALL_ALL=0
NO_TUI=0        # --no-tui: 强制行式菜单(便于脚本/CI 调用)

RESULT_NAMES=()
RESULT_STATES=()   # ok | skip | fail | dry
RESULT_NOTES=()

C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
C_BLU=$'\033[34m'; C_BLD=$'\033[1m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
if [[ ! -t 1 ]]; then C_RED=; C_GRN=; C_YEL=; C_BLU=; C_BLD=; C_DIM=; C_RST=; fi

# ---------------------------------------------------------------------------
# 输出 helper
# ---------------------------------------------------------------------------
say()  { printf '%s\n' "$*"; }
info() { printf '%s[info]%s %s\n' "$C_BLU" "$C_RST" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[err ]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
ok()   { printf '%s[ ok ]%s %s\n' "$C_GRN" "$C_RST" "$*"; }

record() { # record <name> <state> [note]
  RESULT_NAMES+=("$1"); RESULT_STATES+=("$2"); RESULT_NOTES+=("${3:-}")
}

# 统一的命令执行入口, 支持 dry-run
run() {
  if (( DRY_RUN )); then
    printf '%s  $%s %s\n' "$C_DIM" "$C_RST" "$*"
    return 0
  fi
  "$@"
}

# run_sudo: 需要 root 的命令; 在已是 root 或无 sudo 的环境(容器)下直接执行
run_sudo() {
  if (( DRY_RUN )); then
    printf '%s  $ sudo%s %s\n' "$C_DIM" "$C_RST" "$*"
    return 0
  fi
  if [[ "$(id -u 2>/dev/null)" == "0" ]] || ! have sudo; then
    "$@"
  else
    sudo "$@"
  fi
}

# 静默检查命令是否存在
have() { command -v "$1" >/dev/null 2>&1; }

# 兼容: 已是 root 但未安装 sudo 的环境(如最小容器), 让脚本中的 sudo 调用直接执行
if ! have sudo && [[ "$(id -u 2>/dev/null)" == "0" ]]; then
  sudo() { "$@"; }
fi

# 当前会话能否无交互地使用 root 权限
sudo_ok() {
  (( DRY_RUN )) && return 0
  [[ "$(id -u 2>/dev/null)" == "0" ]] && return 0
  sudo -n true 2>/dev/null
}

# ---------------------------------------------------------------------------
# 包管理器抽象
# ---------------------------------------------------------------------------
PKG_FAMILY=""    # deb | rpm
DISTRO_ID=""
DISTRO_VER=""
DISTRO_CODENAME=""
DISTRO_LIKE=""
TARGET_USER="${USER:-$(id -un 2>/dev/null || echo root)}"   # 受 install 影响的用户

# 显示宽度(CJK 算 2 列), 用于报告对齐
disp_width() {
  local s="$1" bytes chars
  bytes="$(LC_ALL=C; printf '%s' "${#s}")"
  chars="$(printf '%s' "${#s}")"
  printf '%s' $(( chars + (bytes - chars) / 2 ))
}
pad_disp() { # <str> <width> → 右侧补空格
  local s="$1" want="$2" w pad
  w="$(disp_width "$s")"; pad=$(( want - w )); (( pad < 0 )) && pad=0
  printf '%s%*s' "$s" "$pad" ""
}

detect_distro() {
  if [[ ! -r /etc/os-release ]]; then
    err "无法读取 /etc/os-release, 未知发行版"
    exit 1
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  DISTRO_ID="${ID:-unknown}"
  DISTRO_VER="${VERSION_ID:-}"
  DISTRO_CODENAME="${VERSION_CODENAME:-}"
  DISTRO_LIKE="${ID_LIKE:-}"

  # Ubuntu 没有 VERSION_CODENAME 时的兜底
  if [[ -z "$DISTRO_CODENAME" && -n "${UBUNTU_CODENAME:-}" ]]; then
    DISTRO_CODENAME="$UBUNTU_CODENAME"
  fi

  case "$DISTRO_ID $DISTRO_LIKE" in
    *ubuntu*|*debian*|*mint*|*pop*) PKG_FAMILY="deb" ;;
    *fedora*|*rhel*|*centos*|*rocky*|*almalinux*) PKG_FAMILY="rpm" ;;
    *)
      err "不支持的发行版: $DISTRO_ID (ID_LIKE=$DISTRO_LIKE)"
      err "本脚本仅支持 apt (Ubuntu/Debian) 与 dnf (Fedora/RHEL) 系"
      exit 1
      ;;
  esac
}

pkg_update() {
  if [[ "$PKG_FAMILY" == "deb" ]]; then
    run_sudo apt-get update -qq
  else
    run_sudo dnf makecache -q
  fi
}

# pkg_install <包...> — 一次装一批, 幂等(apt/dnf 自带)
pkg_install() {
  [[ $# -gt 0 ]] || return 0
  if (( DRY_RUN )); then
    printf '%s  $ %s install %s%s\n' "$C_DIM" \
      "$([[ $PKG_FAMILY == deb ]] && echo apt-get || echo dnf)" "$*" "$C_RST"
    return 0
  fi
  if [[ "$PKG_FAMILY" == "deb" ]]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@"
  else
    sudo dnf install -y -q "$@"
  fi
}

# pkg_install_optional <包...> — 允许部分包不存在(如不同版本的 ros 包名差异)
pkg_install_optional() {
  [[ $# -gt 0 ]] || return 0
  if (( DRY_RUN )); then
    printf '%s  $ %s install (optional) %s%s\n' "$C_DIM" \
      "$([[ $PKG_FAMILY == deb ]] && echo apt-get || echo dnf)" "$*" "$C_RST"
    return 0
  fi
  if [[ "$PKG_FAMILY" == "deb" ]]; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@" 2>/dev/null || {
      warn "optional 包安装有失败项: $*"; return 1; }
  else
    sudo dnf install -y -q "$@" 2>/dev/null || {
      warn "optional 包安装有失败项: $*"; return 1; }
  fi
}

pkg_installed() { # pkg_installed <pkg> → 0 表示已安装
  if [[ "$PKG_FAMILY" == "deb" ]]; then
    dpkg -s "$1" >/dev/null 2>&1
  else
    rpm -q "$1" >/dev/null 2>&1
  fi
}

# ---------------------------------------------------------------------------
# shell 集成管理
#   所有写入 ~/.bashrc / ~/.zshrc 的行由状态文件统一生成:
#     状态文件: ~/.config/envstrap/profile-lines  (格式: <key>TAB<line>)
#   rc 文件中只维护一个标记块, 因此:
#     - 重复执行不会产生重复行
#     - 同一 key(如 UV_DEFAULT_INDEX) 换源时会原地更新而不是叠加
#     - 用户在块外手动设置的同名变量不会被覆盖
# ---------------------------------------------------------------------------
PROFILE_MARKER="# >>> envstrap managed block >>>"
PROFILE_END="# <<< envstrap managed block <<<"

profile_state_file() { printf '%s' "$HOME/.config/envstrap/profile-lines"; }

# ENVSTRAP_NO_PROFILE=1 → 完全不碰 ~/.bashrc / ~/.zshrc / 其他配置(只打印要手动添加的内容)
profile_writes_disabled() { (( ${ENVSTRAP_NO_PROFILE:-0} )); }

profile_rc_files() {
  local -a rcs=()
  [[ -f "$HOME/.bashrc" ]] && rcs+=("$HOME/.bashrc")
  [[ -f "$HOME/.zshrc"  ]] && rcs+=("$HOME/.zshrc")
  if [[ ${#rcs[@]} -eq 0 ]]; then
    case "${SHELL:-}" in
      *zsh) rcs+=("$HOME/.zshrc") ;;
      *)    rcs+=("$HOME/.bashrc") ;;
    esac
  fi
  printf '%s\n' "${rcs[@]}"
}

# 依据状态文件重建 rc 中的标记块
_profile_regenerate() {
  (( DRY_RUN )) && return 0                     # 双保险: dry-run 绝不写文件
  profile_writes_disabled && return 0            # 用户禁用了 shell 配置写入
  local state; state="$(profile_state_file)"
  local -a rcs=(); mapfile -t rcs < <(profile_rc_files)
  local rc tmp body=""
  [[ -s "$state" ]] && body="$(cut -f2- "$state")"

  for rc in "${rcs[@]}"; do
    [[ -f "$rc" ]] || { (( DRY_RUN )) && continue; : > "$rc"; }
    tmp="$(mktemp)"
    if ! awk -v b="$PROFILE_MARKER" -v e="$PROFILE_END" -v body="$body" '
      BEGIN { inb=0; done=0 }
      $0==b { inb=1; if (body!="") print; next }
      $0==e { inb=0; if (!done) { if (body!="") { print body; print e }; done=1 } next }
      inb { next }
      { print }
      END { if (!done && body!="") { print ""; print b; print body; print e } }
    ' "$rc" > "$tmp"; then
      rm -f "$tmp"; warn "重写 $(basename "$rc") 失败"; continue
    fi
    if cmp -s "$tmp" "$rc"; then rm -f "$tmp"; continue; fi
    cp -n "$rc" "$rc.bak.envstrap" 2>/dev/null || true
    cat "$tmp" > "$rc" && rm -f "$tmp"
    ok "已更新 $(basename "$rc") 的 envstrap 配置块"
  done
}

# managed_profile_add <dedupe-key> <line>
managed_profile_add() {
  local key="$1" line="$2"
  if profile_writes_disabled; then
    info "[ENVSTRAP_NO_PROFILE=1] 未写入 shell 配置, 请手动添加: $line"
    return 0
  fi
  local state; state="$(profile_state_file)"

  # 冲突检测: 同名环境变量由用户在块外手动设置过 → 不覆盖
  # 例外: PATH 类变量是追加语义, 可以安全叠加
  if [[ "$line" =~ ^export[[:space:]]+([A-Za-z_][A-Za-z0-9_]*)= ]]; then
    local vkey="${BASH_REMATCH[1]}" rc
    case "$vkey" in
      PATH|MANPATH|LD_LIBRARY_PATH|FPATH) vkey="" ;;
    esac
    if [[ -n "$vkey" ]]; then
      while IFS= read -r rc; do
        [[ -f "$rc" ]] || continue
        if awk -v b="$PROFILE_MARKER" -v e="$PROFILE_END" \
               -v pat="^export[[:space:]]+${vkey}=" '
              $0==b { inb=1; next }
              $0==e { inb=0; next }
              inb { next }
              $0 ~ pat { found=1 }
              END { exit !found }' "$rc"; then
          warn "$(basename "$rc") 中已有你手动设置的 $vkey, 跳过该行以免覆盖你的配置"
          return 1
        fi
      done < <(profile_rc_files)
    fi
  fi

  if (( DRY_RUN )); then
    printf '%s  $ profile: %s → %s%s\n' "$C_DIM" "$key" "$line" "$C_RST"
    return 0
  fi

  mkdir -p "$(dirname "$state")"
  touch "$state"
  local tmp; tmp="$(mktemp)"
  awk -v k="$key" -v l="$line" '
    BEGIN { FS="\t"; OFS="\t"; done=0 }
    { if ($1==k) { if (!done) { print k, l; done=1 }; next } print }
    END { if (!done) print k, l }
  ' "$state" > "$tmp" && mv "$tmp" "$state"

  _profile_regenerate
}

# managed_profile_remove <dedupe-key>
managed_profile_remove() {
  local key="$1" state; state="$(profile_state_file)"
  [[ -f "$state" ]] || return 0
  if (( DRY_RUN )); then
    printf '%s  $ profile remove: %s%s\n' "$C_DIM" "$key" "$C_RST"; return 0
  fi
  local tmp; tmp="$(mktemp)"
  awk -v k="$key" 'BEGIN{FS="\t";OFS="\t"} $1!=k {print}' "$state" > "$tmp" && mv "$tmp" "$state"
  _profile_regenerate
}

ensure_profile_line() { # 静态行: 以行内容作为去重 key
  managed_profile_add "$1" "$1"
}

# 通用: 在任意配置文件里维护一个标记块 (uv.toml / cargo config.toml / pip.conf)
file_block_upsert() { # <file> ; 内容从 stdin 读取
  local f="$1" content; content="$(cat)"
  if profile_writes_disabled; then
    info "[ENVSTRAP_NO_PROFILE=1] 未写入 $f"
    return 0
  fi
  if (( DRY_RUN )); then
    printf '%s  $ upsert block in %s%s\n' "$C_DIM" "$f" "$C_RST"; return 0
  fi
  mkdir -p "$(dirname "$f")"
  [[ -f "$f" ]] || : > "$f"
  cp -n "$f" "$f.bak.envstrap" 2>/dev/null || true
  local tmp; tmp="$(mktemp)"
  awk -v b="$PROFILE_MARKER" -v e="$PROFILE_END" -v body="$content" '
    BEGIN { inb=0; done=0 }
    $0==b { inb=1; if (body!="") print; next }
    $0==e { inb=0; if (!done) { if (body!="") { print body; print e }; done=1 } next }
    inb { next }
    { print }
    END { if (!done && body!="") { print ""; print b; print body; print e } }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

file_block_remove() { # <file>
  local f="$1"
  [[ -f "$f" ]] || return 0
  profile_writes_disabled && return 0
  if (( DRY_RUN )); then
    printf '%s  $ remove block in %s%s\n' "$C_DIM" "$f" "$C_RST"; return 0
  fi
  local tmp; tmp="$(mktemp)"
  awk -v b="$PROFILE_MARKER" -v e="$PROFILE_END" '
    $0==b { inb=1; next }
    $0==e { inb=0; next }
    inb { next }
    { print }
  ' "$f" > "$tmp" && mv "$tmp" "$f"
}

# ---------------------------------------------------------------------------
# 模块: 镜像源测速与切换
#   对每个生态列出候选源, 并行探测真实下载速度, 选最快者写入对应配置:
#     npm/pnpm → ~/.npmrc          PyPI/uv/pip → uv.toml + pip.conf + UV_DEFAULT_INDEX
#     cargo    → ~/.cargo/config.toml   rustup → RUSTUP_DIST_SERVER
#     docker   → /etc/docker/daemon.json registry-mirrors
#     ROS 2    → /etc/apt/sources.list.d/ros2.*        apt 主源 → 需显式确认
#     GitHub   → 供 oh-my-zsh / 插件 clone 使用
# ---------------------------------------------------------------------------
MIRROR_MODE="auto"            # auto | cn | official | skip
MIRROR_APPLY_APT_MAIN=0
MIRROR_APT_URL=""
MIRROR_ROS_URL=""
MIRROR_RUSTUP_DIST=""
MIRROR_GITHUB_PREFIX=""
MIRROR_SUMMARY=()
MIRROR_ORDERED=()
MIRROR_MIN_SPEED_BYTES=32768

# probe_url <url> [maxtime] [range_bytes] → "code ttfb_sec speed_Bps size"
probe_url() {
  local url="$1" mt="${2:-6}" range="${3:-}"
  local -a a=(-sS -L --max-redirs 5 -o /dev/null -m "$mt" -w '%{http_code} %{time_starttransfer} %{speed_download} %{size_download}')
  [[ -n "$range" ]] && a+=(-r "0-$range")
  local out
  out="$(curl "${a[@]}" "$url" 2>/dev/null)" || true
  if [[ -z "$out" ]]; then printf '000 0 0 0\n'; else printf '%s\n' "$out"; fi
}

# select_source <label> <metric: speed|latency> <accept_codes> <range> <timeout> <official_cfg> <name|cfg|probe|region>...
# 结果: MIRROR_PICK_NAME / MIRROR_PICK_CFG / MIRROR_ORDERED(全部可用源按快慢排序)
select_source() {
  local label="$1" metric="$2" accept="$3" range="$4" tmo="$5" official_cfg="$6"; shift 6
  local -a all=("$@") filtered=()
  MIRROR_ORDERED=()

  if [[ "$MIRROR_MODE" == "official" ]]; then
    MIRROR_PICK_NAME="官方"; MIRROR_PICK_CFG="$official_cfg"
    printf '  %s→ %-22s 使用官方源 (模式=official)%s\n' "$C_DIM" "$label" "$C_RST"
    return 0
  fi

  local it
  for it in "${all[@]}"; do
    [[ "$MIRROR_MODE" == "cn" && "${it##*|}" == "official" ]] && continue
    filtered+=("$it")
  done
  (( ${#filtered[@]} )) || { warn "$label: 无候选镜像源"; return 1; }

  local tmpd; tmpd="$(mktemp -d)"
  local -a pids=() names=() cfgs=() probes=()
  local nm cfg pr reg i=0
  for it in "${filtered[@]}"; do
    IFS='|' read -r nm cfg pr reg <<< "$it"
    names+=("$nm"); cfgs+=("$cfg"); probes+=("$pr")
    ( probe_url "$pr" "$tmo" "$range" > "$tmpd/$i" ) &
    pids+=("$!")
    i=$((i+1))
  done
  wait "${pids[@]}" 2>/dev/null || true

  printf '  %s[%s] 测速结果%s\n' "$C_BLD" "$label" "$C_RST"
  for i in "${!names[@]}"; do
    local code="000" ttfb=0 speed=0 size=0 okflag=0 rank=0
    read -r code ttfb speed size < "$tmpd/$i" 2>/dev/null || true
    [[ "$code" =~ ^($accept)$ ]] && okflag=1
    if (( okflag )); then
      if [[ "$metric" == "speed" ]]; then
        if awk -v s="${size:-0}" -v m="$MIRROR_MIN_SPEED_BYTES" 'BEGIN{exit !(s>=m)}'; then
          rank="$(awk -v s="$speed" 'BEGIN{printf "%.3f", s}')"
        else
          rank="$(awk -v t="$ttfb" 'BEGIN{ if (t>0) printf "%.3f", 20000/t; else print 0 }')"
        fi
      else
        rank="$(awk -v t="$ttfb" 'BEGIN{ if (t>0) printf "%.3f", 1000000/t; else print 0 }')"
      fi
    fi
    printf '    %-20s %s code=%-4s %8.1fms %10.1fKB/s %9sB\n' \
      "${names[$i]}" \
      "$([[ $okflag == 1 ]] && printf '%s✔%s' "$C_GRN" "$C_RST" || printf '%s✘%s' "$C_RED" "$C_RST")" \
      "$code" \
      "$(awk -v t="$ttfb" 'BEGIN{print t*1000}')" \
      "$(awk -v s="$speed" 'BEGIN{print s/1024}')" \
      "${size%.*}"
    printf '%s\t%s\n' "$rank" "$i" >> "$tmpd/rank"
  done

  local best_idx=-1
  if [[ -f "$tmpd/rank" ]]; then
    while IFS=$'\t' read -r r idx; do
      awk -v a="$r" 'BEGIN{exit !(a>0)}' || continue
      MIRROR_ORDERED+=("${names[$idx]}|${cfgs[$idx]}|${probes[$idx]}")
      (( best_idx < 0 )) && best_idx="$idx"
    done < <(sort -k1,1gr "$tmpd/rank")
  fi
  rm -rf "$tmpd"

  if (( best_idx < 0 )); then
    warn "$label: 所有候选源均不可用, 保持当前配置不变"
    return 1
  fi
  MIRROR_PICK_NAME="${names[$best_idx]}"
  MIRROR_PICK_CFG="${cfgs[$best_idx]}"
  printf '  %s→ %s 选择: %s%s\n' "$C_GRN" "$label" "$MIRROR_PICK_NAME" "$C_RST"
  return 0
}

# ---- 各生态配置写入 ----
npmrc_set() {
  local f="$HOME/.npmrc" k="$1" v="$2"
  if (( DRY_RUN )); then
    printf '%s  $ ~/.npmrc: %s=%s%s\n' "$C_DIM" "$k" "$v" "$C_RST"; return 0
  fi
  touch "$f"
  if grep -qE "^${k}=" "$f"; then
    sed -i "s@^${k}=.*@${k}=${v}@" "$f"
  else
    printf '%s=%s\n' "$k" "$v" >> "$f"
  fi
}

apply_npm_registry() {
  local url="$1"
  [[ -n "$url" ]] || return 1
  have npm  && run npm  config set registry "$url" >/dev/null 2>&1 || true
  npmrc_set registry "$url"
  have pnpm && run pnpm config set registry "$url" >/dev/null 2>&1 || true
  ok "npm / pnpm registry: $url"
}

apply_pypi_index() { # <simple index url | official>
  local url="$1"
  local official=0
  [[ "$url" == "official" || "$url" == "https://pypi.org/simple" ]] && official=1
  local pip_bin=""
  if have pip3; then pip_bin="pip3"; elif have pip; then pip_bin="pip"; fi

  if (( official )); then
    [[ -n "$pip_bin" ]] && { run "$pip_bin" config unset global.index-url >/dev/null 2>&1 || true; }
    file_block_remove "$HOME/.config/pip/pip.conf"
    file_block_remove "$HOME/.config/uv/uv.toml"
    managed_profile_remove UV_DEFAULT_INDEX || true
    unset UV_DEFAULT_INDEX UV_INDEX_URL 2>/dev/null || true
    info "PyPI / uv 使用官方源"
    return 0
  fi

  if [[ -n "$pip_bin" ]]; then
    run "$pip_bin" config set global.index-url "$url" >/dev/null 2>&1 || true
  else
    file_block_upsert "$HOME/.config/pip/pip.conf" <<EOF
[global]
index-url = $url
timeout = 60
EOF
  fi

  # 环境变量优先级最高, 保证 uv 一定生效(含未来新装 shell)
  managed_profile_add UV_DEFAULT_INDEX "export UV_DEFAULT_INDEX=\"$url\"" || true
  export UV_DEFAULT_INDEX="$url"

  local uvf="$HOME/.config/uv/uv.toml"
  if [[ -f "$uvf" ]] && ! grep -qF "$PROFILE_MARKER" "$uvf" \
     && grep -qE '^[[:space:]]*index-url|^[[:space:]]*\[\[index\]\]|default[[:space:]]*=[[:space:]]*true' "$uvf"; then
    warn "$uvf 已有自定义索引配置, 不改动 (UV_DEFAULT_INDEX 环境变量仍会生效)"
  else
    file_block_upsert "$uvf" <<EOF
[[index]]
url = "$url"
default = true
EOF
  fi
  ok "PyPI / uv 索引: $url"
}

apply_cargo_source() { # <sparse+url | official>
  local url="$1" cfg="$HOME/.cargo/config.toml"
  if [[ "$url" == "official" || -z "$url" || "$url" == "https://index.crates.io" ]]; then
    file_block_remove "$cfg"
    info "cargo 使用官方 crates.io"
    return 0
  fi
  if [[ -f "$cfg" ]] && ! grep -qF "$PROFILE_MARKER" "$cfg" \
     && grep -qE '^[[:space:]]*\[source\.crates-io\]' "$cfg"; then
    warn "$cfg 已有自定义 [source.crates-io], 不覆盖, 请手动调整"
    return 1
  fi
  file_block_upsert "$cfg" <<EOF
[source.crates-io]
replace-with = "setupdev-mirror"

[source.setupdev-mirror]
registry = "$url"
EOF
  ok "cargo 源: $url"
}

apply_rustup_dist() { # <dist_server | official>
  local dist="$1"
  if [[ "$dist" == "official" || -z "$dist" ]]; then
    managed_profile_remove RUSTUP_DIST_SERVER || true
    managed_profile_remove RUSTUP_UPDATE_ROOT || true
    unset RUSTUP_DIST_SERVER RUSTUP_UPDATE_ROOT 2>/dev/null || true
    info "rustup 使用官方下载源"
    return 0
  fi
  local root="${dist%/}/rustup"
  managed_profile_add RUSTUP_DIST_SERVER "export RUSTUP_DIST_SERVER=\"$dist\"" || true
  managed_profile_add RUSTUP_UPDATE_ROOT "export RUSTUP_UPDATE_ROOT=\"$root\"" || true
  export RUSTUP_DIST_SERVER="$dist" RUSTUP_UPDATE_ROOT="$root"
  MIRROR_RUSTUP_DIST="$dist"
  ok "rustup 下载源: $dist"
}

# 将 JSON 片段合并进 /etc/docker/daemon.json: 保留已有键, 幂等
#   docker_daemon_merge '{"log-driver":"json-file"}'
docker_daemon_merge() { # <json fragment>
  local frag="$1" f=/etc/docker/daemon.json existing merged
  if (( DRY_RUN )); then
    printf '%s  $ merge %s → %s%s\n' "$C_DIM" "$frag" "$f" "$C_RST"
    return 0
  fi
  sudo_ok || { warn "当前会话无法使用 sudo, 跳过 $f 配置"; return 1; }
  have python3 || { warn "缺少 python3, 无法安全合并 $f, 跳过"; return 1; }

  existing="$(sudo cat "$f" 2>/dev/null || true)"
  [[ -z "$existing" ]] && existing='{}'
  merged="$(python3 - "$existing" "$frag" <<'PY'
import json, sys
try:
    d = json.loads(sys.argv[1])
except Exception:
    d = {}
if not isinstance(d, dict):
    d = {}
try:
    add = json.loads(sys.argv[2])
except Exception:
    add = {}
if not isinstance(add, dict):
    add = {}
out = dict(d)
out.update(add)
if out == d:
    print("__NOCHANGE__")
else:
    print(json.dumps(out, indent=2, ensure_ascii=False))
PY
)" || { warn "解析 $f 失败, 跳过"; return 1; }

  if [[ "$merged" == "__NOCHANGE__" ]]; then
    info "$f 已包含所需配置, 无需改动"
    return 0
  fi
  sudo mkdir -p /etc/docker
  printf '%s\n' "$merged" | sudo tee "$f" >/dev/null || return 1
  if systemctl cat docker.service >/dev/null 2>&1; then
    run_sudo systemctl restart docker || warn "重启 docker 失败"
  else
    info "docker 服务尚不存在, 配置将在首次启动时生效"
  fi
  ok "已更新 $f : $frag"
}

apply_docker_mirrors() { # <mirror url...>  无参=清空 registry-mirrors
  local -a mirrors=( ${1+"$@"} )
  local json_frag
  if (( ${#mirrors[@]} )); then
    warn "registry-mirrors 属于第三方镜像通道, 存在被投毒/篡改风险, 仅建议开发机使用"
    json_frag="{\"registry-mirrors\": [$(printf '"%s",' "${mirrors[@]}" | sed 's/,$//')]}"
  else
    json_frag='{"registry-mirrors": []}'
  fi
  docker_daemon_merge "$json_frag"
}

apply_ros_apt_mirror() { # <base url>
  local url="$1" f changed=0
  local -a files=(/etc/apt/sources.list.d/ros2.sources /etc/apt/sources.list.d/ros2.list)
  if (( DRY_RUN )); then
    printf '%s  $ sed ros2 source → %s in %s%s\n' "$C_DIM" "$url" "${files[*]}" "$C_RST"
    return 0
  fi
  sudo_ok || { warn "当前会话无法使用 sudo, 跳过 ROS 换源"; return 1; }
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    sudo grep -q 'packages\.ros\.org' "$f" 2>/dev/null || continue
    sudo cp "$f" "$f.bak.envstrap" 2>/dev/null || true
    sudo sed -i "s#https\?://packages\.ros\.org/ros2/ubuntu#${url}#g" "$f"
    changed=1
  done
  (( changed )) || { info "未发现 packages.ros.org 源(ROS 可能还未安装)"; return 1; }
  if pkg_update; then
    ok "ROS 2 apt 源 → $url"
  else
    warn "换源后 apt update 失败, 回滚 ROS 源"
    for f in "${files[@]}"; do [[ -f "$f.bak.envstrap" ]] && sudo cp "$f.bak.envstrap" "$f"; done
    pkg_update >/dev/null 2>&1 || true
    return 1
  fi
}

apply_apt_main_mirror() { # <base url>  仅 ubuntu
  local url="$1" f
  local -a files=()
  [[ -f /etc/apt/sources.list.d/ubuntu.sources ]] && files+=(/etc/apt/sources.list.d/ubuntu.sources)
  [[ -f /etc/apt/sources.list ]] && files+=(/etc/apt/sources.list)
  (( ${#files[@]} )) || { warn "未找到 apt 源文件"; return 1; }
  if (( DRY_RUN )); then
    printf '%s  $ apt 主源 → %s (%s)%s\n' "$C_DIM" "$url" "${files[*]}" "$C_RST"; return 0
  fi
  sudo_ok || { warn "当前会话无法使用 sudo, 跳过 apt 主源切换"; return 1; }
  for f in "${files[@]}"; do
    sudo cp "$f" "$f.bak.envstrap" 2>/dev/null || true
    sudo sed -i -E "s#https?://[a-z0-9.-]*\.?ubuntu\.com/ubuntu#${url}#g" "$f"
  done
  if pkg_update; then
    ok "apt 主源 → $url"
  else
    warn "换源后 apt update 失败, 自动回滚 apt 主源"
    for f in "${files[@]}"; do [[ -f "$f.bak.envstrap" ]] && sudo cp "$f.bak.envstrap" "$f"; done
    pkg_update >/dev/null 2>&1 || true
    return 1
  fi
}

# git clone 封装: 若测速结果推荐了 GitHub 加速前缀则优先使用
#   git_clone <https url> <dest> [depth]   depth=0 表示完整克隆
_git_clone_once() { # <url> <dest> <depth>
  local url="$1" dest="$2" depth="$3"
  if [[ "$depth" == "0" ]]; then git clone "$url" "$dest"
  else git clone --depth="$depth" "$url" "$dest"; fi
}

git_clone() {
  local url="$1" dest="$2" depth="${3:-1}"
  if [[ -d "$dest" ]]; then info "已存在: $dest"; return 0; fi
  if (( DRY_RUN )); then
    printf '%s  $ git clone %s %s%s\n' "$C_DIM" "$url" "$dest" "$C_RST"; return 0
  fi
  if [[ -n "$MIRROR_GITHUB_PREFIX" ]]; then
    if _git_clone_once "${MIRROR_GITHUB_PREFIX}${url}" "$dest" "$depth" 2>/dev/null; then
      ok "已克隆(加速): $dest"; return 0
    fi
    rm -rf "$dest"; warn "加速前缀克隆失败, 回退直连"
  fi
  _git_clone_once "$url" "$dest" "$depth"
}

mod_mirrors() {
  if [[ "$MIRROR_MODE" == "skip" ]]; then
    info "跳过镜像源切换 (--mirror skip)"; return 0
  fi
  case "$MIRROR_MODE" in
    auto|cn|official) ;;
    *) err "--mirror 只支持 auto|cn|official|skip"; return 1 ;;
  esac
  info "模式: $MIRROR_MODE  (auto=全部候选取最快 / cn=仅国内 / official=恢复官方)"
  if (( DRY_RUN )); then
    info "DRY-RUN: 将测速并切换 npm/pnpm, PyPI(uv/pip), crates(cargo), rustup, Docker registry, ROS, GitHub 加速"
    return 0
  fi
  have curl || { warn "缺少 curl, 无法测速换源"; return 1; }
  local okc=0

  # --- npm / pnpm ---
  if select_source "npm/pnpm" speed '200|206' 1048575 6 "https://registry.npmjs.org" \
      "官方 npmjs|https://registry.npmjs.org|https://registry.npmjs.org/typescript/-/typescript-5.4.5.tgz|official" \
      "npmmirror(阿里)|https://registry.npmmirror.com|https://registry.npmmirror.com/typescript/-/typescript-5.4.5.tgz|cn" \
      "腾讯云|https://mirrors.cloud.tencent.com/npm|https://mirrors.cloud.tencent.com/npm/typescript/-/typescript-5.4.5.tgz|cn" \
      "华为云|https://repo.huaweicloud.com/repository/npm|https://repo.huaweicloud.com/repository/npm/typescript/-/typescript-5.4.5.tgz|cn" \
      "中科大 USTC|https://npmreg.proxy.ustclug.org|https://npmreg.proxy.ustclug.org/typescript/-/typescript-5.4.5.tgz|cn" ; then
    apply_npm_registry "$MIRROR_PICK_CFG" && { okc=$((okc+1)); MIRROR_SUMMARY+=("npm/pnpm → $MIRROR_PICK_NAME"); }
  fi

  # --- PyPI (uv / pip) ---
  if select_source "PyPI(uv/pip)" speed '200|206' 1048575 6 "https://pypi.org/simple" \
      "官方 PyPI|https://pypi.org/simple|https://pypi.org/simple/boto3/|official" \
      "清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple|https://mirrors.tuna.tsinghua.edu.cn/pypi/web/simple/boto3/|cn" \
      "中科大 USTC|https://mirrors.ustc.edu.cn/pypi/simple|https://mirrors.ustc.edu.cn/pypi/simple/boto3/|cn" \
      "阿里云|https://mirrors.aliyun.com/pypi/simple|https://mirrors.aliyun.com/pypi/simple/boto3/|cn" \
      "华为云|https://repo.huaweicloud.com/repository/pypi/simple|https://repo.huaweicloud.com/repository/pypi/simple/boto3/|cn" ; then
    apply_pypi_index "$MIRROR_PICK_CFG" && { okc=$((okc+1)); MIRROR_SUMMARY+=("PyPI/uv → $MIRROR_PICK_NAME"); }
  fi

  # --- crates.io (cargo) ---
  if select_source "crates.io" speed '200|206' 1048575 6 "official" \
      "官方 crates.io|https://index.crates.io|https://index.crates.io/se/rd/serde|official" \
      "RsProxy(字节)|sparse+https://rsproxy.cn/index/|https://rsproxy.cn/index/se/rd/serde|cn" \
      "清华 TUNA|sparse+https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/|https://mirrors.tuna.tsinghua.edu.cn/crates.io-index/se/rd/serde|cn" \
      "中科大 USTC|sparse+https://mirrors.ustc.edu.cn/crates.io-index/|https://mirrors.ustc.edu.cn/crates.io-index/se/rd/serde|cn" ; then
    apply_cargo_source "$MIRROR_PICK_CFG" && { okc=$((okc+1)); MIRROR_SUMMARY+=("cargo → $MIRROR_PICK_NAME"); }
  fi

  # --- rustup 工具链下载 ---
  if select_source "rustup" speed '200|206' 262144 6 "official" \
      "官方 static.rust-lang.org|https://static.rust-lang.org|https://static.rust-lang.org/dist/channel-rust-stable.toml|official" \
      "RsProxy(字节)|https://rsproxy.cn|https://rsproxy.cn/dist/channel-rust-stable.toml|cn" \
      "清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/rustup|https://mirrors.tuna.tsinghua.edu.cn/rustup/dist/channel-rust-stable.toml|cn" \
      "中科大 USTC|https://mirrors.ustc.edu.cn/rust-static|https://mirrors.ustc.edu.cn/rust-static/dist/channel-rust-stable.toml|cn" \
      "阿里云|https://mirrors.aliyun.com/rustup|https://mirrors.aliyun.com/rustup/dist/channel-rust-stable.toml|cn" ; then
    apply_rustup_dist "$MIRROR_PICK_CFG" && { okc=$((okc+1)); MIRROR_SUMMARY+=("rustup → $MIRROR_PICK_NAME"); }
  fi

  # --- Docker registry ---
  if select_source "Docker registry" latency '200|401|403' '' 5 "https://registry-1.docker.io" \
      "官方 Docker Hub|https://registry-1.docker.io|https://registry-1.docker.io/v2/|official" \
      "DaoCloud|https://docker.m.daocloud.io|https://docker.m.daocloud.io/v2/|cn" \
      "1Panel|https://docker.1panel.live|https://docker.1panel.live/v2/|cn" \
      "1ms.run|https://docker.1ms.run|https://docker.1ms.run/v2/|cn" \
      "dockerproxy.net|https://dockerproxy.net|https://dockerproxy.net/v2/|cn" \
      "南京大学|https://docker.nju.edu.cn|https://docker.nju.edu.cn/v2/|cn" \
      "腾讯云|https://mirror.ccs.tencentyun.com|https://mirror.ccs.tencentyun.com/v2/|cn" ; then
    local -a dms=() ent c
    if [[ "$MIRROR_PICK_CFG" != "https://registry-1.docker.io" ]]; then
      for ent in "${MIRROR_ORDERED[@]}"; do
        c="$(printf '%s' "$ent" | cut -d'|' -f2)"
        [[ "$c" == "https://registry-1.docker.io" ]] && continue
        dms+=("$c"); (( ${#dms[@]} >= 3 )) && break
      done
    fi
    if apply_docker_mirrors ${dms[@]+"${dms[@]}"}; then
      okc=$((okc+1))
      MIRROR_SUMMARY+=("docker → $([[ ${#dms[@]} -gt 0 ]] && printf '%s' "${dms[0]}" || printf '不加镜像(官方最快)')")
    fi
  fi

  # --- GitHub 加速(供 oh-my-zsh / 插件 clone) ---
  if select_source "GitHub 加速" speed '200|206' 65536 6 "-" \
      "直连 GitHub|-|https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/README.md|official" \
      "ghfast.top|https://ghfast.top/|https://ghfast.top/https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/README.md|cn" \
      "gh-proxy.com|https://gh-proxy.com/|https://gh-proxy.com/https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/README.md|cn" \
      "ghproxy.net|https://ghproxy.net/|https://ghproxy.net/https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/README.md|cn" \
      "gitmirror|https://hub.gitmirror.com/|https://hub.gitmirror.com/https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/README.md|cn" ; then
    if [[ "$MIRROR_PICK_CFG" == "-" ]]; then
      MIRROR_GITHUB_PREFIX=""; okc=$((okc+1))
    else
      MIRROR_GITHUB_PREFIX="$MIRROR_PICK_CFG"; okc=$((okc+1))
      MIRROR_SUMMARY+=("GitHub → $MIRROR_PICK_NAME")
    fi
  fi

  # --- ROS 2 apt 源 ---
  if [[ "$PKG_FAMILY" == "deb" && -n "$DISTRO_CODENAME" ]]; then
    if select_source "ROS 2 apt" speed '200|206' 131072 6 "https://packages.ros.org/ros2/ubuntu" \
        "官方 packages.ros.org|https://packages.ros.org/ros2/ubuntu|https://packages.ros.org/ros2/ubuntu/dists/${DISTRO_CODENAME}/Release|official" \
        "清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ros2/ubuntu/dists/${DISTRO_CODENAME}/Release|cn" \
        "中科大 USTC|https://mirrors.ustc.edu.cn/ros2/ubuntu|https://mirrors.ustc.edu.cn/ros2/ubuntu/dists/${DISTRO_CODENAME}/Release|cn" \
        "上海交大|https://mirror.sjtu.edu.cn/ros2/ubuntu|https://mirror.sjtu.edu.cn/ros2/ubuntu/dists/${DISTRO_CODENAME}/Release|cn" ; then
      if [[ "$MIRROR_PICK_CFG" == "https://packages.ros.org/ros2/ubuntu" ]]; then
        info "ROS 2 apt 源保持官方"
      else
        MIRROR_ROS_URL="$MIRROR_PICK_CFG"
        if apply_ros_apt_mirror "$MIRROR_ROS_URL"; then
          okc=$((okc+1)); MIRROR_SUMMARY+=("ROS 2 → $MIRROR_PICK_NAME")
        fi
      fi
    fi
  fi

  # --- apt 主源(需显式开启) ---
  if (( MIRROR_APPLY_APT_MAIN )) && [[ "$DISTRO_ID" == "ubuntu" && -n "$DISTRO_CODENAME" ]]; then
    if [[ -n "$MIRROR_APT_URL" ]]; then
      apply_apt_main_mirror "$MIRROR_APT_URL" && { okc=$((okc+1)); MIRROR_SUMMARY+=("apt → $MIRROR_APT_URL"); }
    elif select_source "apt 主源" speed '200|206' 262144 6 "official" \
        "官方 archive.ubuntu.com|https://archive.ubuntu.com/ubuntu|https://archive.ubuntu.com/ubuntu/dists/${DISTRO_CODENAME}/Release|official" \
        "清华 TUNA|https://mirrors.tuna.tsinghua.edu.cn/ubuntu|https://mirrors.tuna.tsinghua.edu.cn/ubuntu/dists/${DISTRO_CODENAME}/Release|cn" \
        "阿里云|https://mirrors.aliyun.com/ubuntu|https://mirrors.aliyun.com/ubuntu/dists/${DISTRO_CODENAME}/Release|cn" \
        "腾讯云|https://mirrors.cloud.tencent.com/ubuntu|https://mirrors.cloud.tencent.com/ubuntu/dists/${DISTRO_CODENAME}/Release|cn" \
        "华为云|https://repo.huaweicloud.com/ubuntu|https://repo.huaweicloud.com/ubuntu/dists/${DISTRO_CODENAME}/Release|cn" ; then
      apply_apt_main_mirror "$MIRROR_PICK_CFG" && { okc=$((okc+1)); MIRROR_SUMMARY+=("apt → $MIRROR_PICK_NAME"); }
    fi
  elif (( MIRROR_APPLY_APT_MAIN )); then
    warn "apt 主源切换目前仅支持 Ubuntu, 已跳过"
  fi

  if (( okc )); then ok "镜像源处理完成"; return 0; fi
  warn "未能切换任何镜像源"; return 1
}

# ---------------------------------------------------------------------------
# 模块: 基础工具
# ---------------------------------------------------------------------------
mod_base() {
  pkg_update || { warn "包索引更新失败, 继续尝试安装"; }

  local pkgs_common=(curl wget git ca-certificates)
  local pkgs
  if [[ "$PKG_FAMILY" == "deb" ]]; then
    pkgs=(build-essential cmake ninja-build pkg-config \
          python3 python3-pip python3-venv \
          unzip zip xz-utils \
          locales "${pkgs_common[@]}")
    pkg_install locales || true
    # ROS 2 需要 UTF-8 locale
    if ! locale 2>/dev/null | grep -qi 'UTF-8'; then
      info "配置 UTF-8 locale"
      run_sudo locale-gen en_US en_US.UTF-8 || warn "locale-gen 失败"
      run_sudo update-locale LC_ALL=en_US.UTF-8 LANG=en_US.UTF-8 || true
    fi
  else
    pkgs=(gcc gcc-c++ make cmake ninja-build pkgconf-pkg-config \
          python3 python3-pip python3-devel \
          unzip zip xz patch \
          glibc-langpack-en "${pkgs_common[@]}")
    pkg_install glibc-langpack-en || true
  fi

  pkg_install "${pkgs[@]}" || return 1
  ok "基础工具已就绪"
}

# ---------------------------------------------------------------------------
# 模块: Git 配置 (可选, 交互时询问)
# ---------------------------------------------------------------------------
mod_git_config() {
  have git || { warn "git 未安装, 跳过配置"; return 1; }

  local name email
  name="$(git config --global user.name 2>/dev/null || true)"
  email="$(git config --global user.email 2>/dev/null || true)"

  if [[ -n "$name" && -n "$email" ]]; then
    info "git 已配置: $name <$email>"
    return 0
  fi

  if (( ASSUME_YES )) || [[ ! -t 0 ]]; then
    info "非交互模式, 跳过 git 身份配置"
    return 0
  fi

  read -r -p "配置 git 全局 user.name? (留空跳过): " name
  read -r -p "配置 git 全局 user.email? (留空跳过): " email
  [[ -n "$name"  ]] && run git config --global user.name "$name"
  [[ -n "$email" ]] && run git config --global user.email "$email"

  # 常用体验项
  run git config --global init.defaultBranch main
  run git config --global pull.rebase false
  run git config --global core.autocrlf input
  ok "git 配置完成"
}

# ---------------------------------------------------------------------------
# 模块: Docker (官方源 + 免 sudo + buildx/compose)
# ---------------------------------------------------------------------------
DOCKER_SUDO_GROUP=1   # 由交互决定是否加入 docker 组

mod_docker() {
  if have docker && docker compose version >/dev/null 2>&1; then
    info "docker 与 compose 插件已安装, 跳过仓库配置"
  else
    info "配置 Docker 官方仓库并安装"
    if [[ "$PKG_FAMILY" == "deb" ]]; then
      # 移除发行版自带的冲突包
      local conflicts=(docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc)
      if (( DRY_RUN )); then
        printf '%s  $ sudo apt-get remove -y %s%s\n' "$C_DIM" "${conflicts[*]}" "$C_RST"
      else
        sudo apt-get remove -y -qq "${conflicts[@]}" >/dev/null 2>&1 || true
      fi

      pkg_install ca-certificates curl gnupg || return 1
      run_sudo install -m 0755 -d /etc/apt/keyrings
      if (( DRY_RUN )); then
        printf '%s  $ curl -fsSL https://download.docker.com/linux/%s/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg%s\n' \
          "$C_DIM" "$DISTRO_ID" "$C_RST"
      else
        curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" \
          | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg || return 1
        sudo chmod a+r /etc/apt/keyrings/docker.gpg
      fi

      local arch; arch="$(dpkg --print-architecture)"
      local cs; cs="${DISTRO_CODENAME}"
      [[ -z "$cs" ]] && cs="$(. /etc/os-release && echo "${VERSION_CODENAME:-stable}")"
      local line="deb [arch=${arch} signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${DISTRO_ID} ${cs} stable"
      if (( DRY_RUN )); then
        printf '%s  $ echo %s | sudo tee /etc/apt/sources.list.d/docker.list%s\n' "$C_DIM" "'$line'" "$C_RST"
      else
        echo "$line" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
      fi
      pkg_update || true
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    else
      # Fedora / RHEL 系
      pkg_install dnf-plugins-core || return 1
      if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
        local repo_url="https://download.docker.com/linux/fedora/docker-ce.repo"
        [[ "$DISTRO_ID" == "rhel" || "$DISTRO_ID" == "centos" || "$DISTRO_ID" == "rocky" || "$DISTRO_ID" == "almalinux" ]] \
          && repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
        run_sudo dnf config-manager addrepo --from-repofile="$repo_url" \
          || run_sudo dnf config-manager --add-repo "$repo_url" \
          || return 1
      else
        info "docker-ce.repo 已存在"
      fi
      # Fedora 上 moby-engine 与 docker-ce 冲突
      if (( DRY_RUN )); then
        printf '%s  $ sudo dnf remove -y moby-engine%s\n' "$C_DIM" "$C_RST"
      else
        sudo dnf remove -y -q moby-engine >/dev/null 2>&1 || true
      fi
      pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin || return 1
    fi
  fi

  # 启动服务
  run_sudo systemctl enable --now docker || warn "docker 服务启动失败, 请检查 journalctl -u docker"

  # 免 sudo
  if (( DOCKER_SUDO_GROUP )); then
    if id -nG "$TARGET_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
      info "用户 $TARGET_USER 已在 docker 组"
    else
      run_sudo groupadd -f docker || true
      run_sudo usermod -aG docker "$TARGET_USER" || warn "加入 docker 组失败"
      warn "已加入 docker 组, 需要重新登录(或 newgrp docker)后生效"
    fi
  fi

  # 验证
  if ! (( DRY_RUN )); then
    if sudo docker run --rm hello-world >/dev/null 2>&1; then
      ok "docker 验证通过 (hello-world)"
    else
      warn "hello-world 验证失败(可能无外网), 但二进制已安装"
    fi
  fi

  # daemon 配置: 日志轮转, 避免长期开发把磁盘写满
  # (与镜像模块写入的 registry-mirrors 合并, 不会互相覆盖)
  docker_daemon_merge '{"log-driver":"json-file","log-opts":{"max-size":"20m","max-file":"3"}}'
  ok "Docker 模块完成"
}

# ---------------------------------------------------------------------------
# 模块: Node.js (fnm 用户级) + pnpm
# ---------------------------------------------------------------------------
NODE_VERSION="lts/*"

mod_node() {
  # 优先 fnm (快、用户级、无需 sudo); 若已有 nvm 则尊重现有环境
  if have fnm; then
    info "fnm 已安装: $(fnm --version 2>/dev/null)"
  elif [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    info "检测到 nvm, 使用 nvm 安装 node"
    # shellcheck disable=SC1091
    . "$HOME/.nvm/nvm.sh"
    run nvm install "$NODE_VERSION" || return 1
    run nvm alias default node || true
  else
    info "通过官方安装脚本安装 fnm"
    if (( DRY_RUN )); then
      printf '%s  $ curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell%s\n' "$C_DIM" "$C_RST"
    else
      if have curl; then
        curl -fsSL https://fnm.vercel.app/install | bash -s -- --skip-shell || return 1
      else
        wget -qO- https://fnm.vercel.app/install | bash -s -- --skip-shell || return 1
      fi
    fi
    ensure_profile_line 'eval "$(fnm env --use-on-cd --shell "$(basename "${SHELL:-/bin/bash}")" 2>/dev/null)"'
    export PATH="$HOME/.local/share/fnm:$PATH"
    (( DRY_RUN )) || eval "$(fnm env --shell bash 2>/dev/null || true)"
  fi

  # 安装 node
  if (( DRY_RUN )); then
    printf '%s  $ fnm install --lts && fnm default lts-latest%s\n' "$C_DIM" "$C_RST"
  else
    if have fnm; then
      fnm install --lts || warn "fnm install --lts 失败"
      fnm default lts-latest 2>/dev/null || true
      eval "$(fnm env --shell bash 2>/dev/null || true)"
    fi
  fi

  # 配置 npm 全局包目录 (避免 sudo)
  if have node; then
    ok "node $(node --version) / npm $(npm --version 2>/dev/null)"
    if (( ! DRY_RUN )); then
      npm config set fund false >/dev/null 2>&1 || true
      npm config set audit false >/dev/null 2>&1 || true
    fi
  else
    warn "node 不在当前 PATH, 新开终端后生效"
  fi

  # pnpm: 优先独立安装脚本(不依赖 node 全局前缀), 否则 corepack
  if have pnpm; then
    info "pnpm 已安装: $(pnpm --version 2>/dev/null)"
  else
    info "安装 pnpm"
    if (( DRY_RUN )); then
      printf '%s  $ curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=latest sh -%s\n' "$C_DIM" "$C_RST"
    else
      if have curl; then
        curl -fsSL https://get.pnpm.io/install.sh | env PNPM_VERSION=latest sh - || warn "pnpm 独立安装失败"
      else
        wget -qO- https://get.pnpm.io/install.sh | env PNPM_VERSION=latest sh - || warn "pnpm 独立安装失败"
      fi
      # 兜底: corepack
      if ! have pnpm && have corepack; then
        info "尝试 corepack 启用 pnpm"
        corepack enable pnpm >/dev/null 2>&1 || true
      fi
    fi
    ensure_profile_line 'export PNPM_HOME="$HOME/.local/share/pnpm"'
    ensure_profile_line 'export PATH="$PNPM_HOME:$PATH"'
  fi

  # 全局 CLI: bun 可选, typescript/tsx 常用
  if (( ! DRY_RUN )) && have pnpm; then
    ok "pnpm $(pnpm --version 2>/dev/null)"
  fi
  ok "Node 模块完成"
}

# ---------------------------------------------------------------------------
# 模块: Python 工具链 (uv)
# ---------------------------------------------------------------------------
mod_python() {
  if have uv; then
    info "uv 已安装: $(uv --version 2>/dev/null)"
  else
    info "通过官方脚本安装 uv (用户级)"
    if (( DRY_RUN )); then
      printf '%s  $ curl -LsSf https://astral.sh/uv/install.sh | sh%s\n' "$C_DIM" "$C_RST"
    else
      if have curl; then
        curl -LsSf https://astral.sh/uv/install.sh | sh || return 1
      else
        wget -qO- https://astral.sh/uv/install.sh | sh || return 1
      fi
    fi
    ensure_profile_line 'export PATH="$HOME/.local/bin:$PATH"'
    export PATH="$HOME/.local/bin:$PATH"
  fi

  # uv 管理一个默认 python, 方便 pipx 风格全局工具
  if (( ! DRY_RUN )) && have uv; then
    uv python install --default >/dev/null 2>&1 || warn "uv python install 失败(可稍后手动执行)"
    ok "uv $(uv --version)"
  fi

  # python 基础库(ROS 2 的 rosdep 需要)
  if [[ "$PKG_FAMILY" == "deb" ]]; then
    pkg_install python3-venv python3-pip || warn "python3 附加包安装失败"
  else
    pkg_install python3-pip || warn "python3-pip 安装失败"
  fi
  ok "Python 模块完成"
}

# ---------------------------------------------------------------------------
# 模块: Rust (rustup 用户级)
# ---------------------------------------------------------------------------
RUST_PROFILE="default"
RUST_COMPONENTS="rustfmt,clippy,rust-src,llvm-tools"

mod_rust() {
  if have rustup && have cargo; then
    info "rustup 已安装: $(rustup --version 2>/dev/null | head -1)"
    if (( ! DRY_RUN )); then
      rustup update stable >/dev/null 2>&1 && ok "已更新 stable 工具链" || warn "rustup update 失败"
    fi
  else
    if have rustc && [[ ! -d "$HOME/.cargo" ]]; then
      warn "检测到系统 rustc, 但仍安装 rustup 到 ~/.cargo (通过 PATH 优先)"
    fi
    info "安装 rustup 到 ~/.cargo (用户级, 不修改系统 rust)"
    if (( DRY_RUN )); then
      printf '%s  $ curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile %s%s\n' \
        "$C_DIM" "$RUST_PROFILE" "$C_RST"
    else
      if have curl; then
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
          | sh -s -- -y --no-modify-path --profile "$RUST_PROFILE" || return 1
      else
        wget -qO- https://sh.rustup.rs \
          | sh -s -- -y --no-modify-path --profile "$RUST_PROFILE" || return 1
      fi
    fi
    if [[ -f "$HOME/.cargo/env" ]]; then
      ensure_profile_line '. "$HOME/.cargo/env"'
      # shellcheck disable=SC1091
      (( DRY_RUN )) || . "$HOME/.cargo/env"
    fi
  fi

  # 组件
  if (( ! DRY_RUN )) && have rustup; then
    local c
    IFS=',' read -ra _comps <<< "$RUST_COMPONENTS"
    for c in "${_comps[@]}"; do
      rustup component add "$c" >/dev/null 2>&1 || warn "组件 $c 安装失败(可忽略)"
    done
    # 嵌入式常用 target
    rustup target add thumbv7em-none-eabihf thumbv6m-none-eabi >/dev/null 2>&1 \
      || warn "嵌入式 target 添加失败(可忽略)"
    ok "rust $(rustc --version 2>/dev/null)"
  fi
  ok "Rust 模块完成"
}

# ---------------------------------------------------------------------------
# 模块: 嵌入式 (STM32: arm-none-eabi + openocd + udev)
# ---------------------------------------------------------------------------
mod_embedded() {
  local pkgs_core=(cmake ninja-build openocd gdb-multiarch)

  if [[ "$PKG_FAMILY" == "deb" ]]; then
    # Debian/Ubuntu 提供 gcc-arm-none-eabi 与 newlib
    pkg_install gcc-arm-none-eabi binutils-arm-none-eabi libnewlib-arm-none-eabi \
                libstdc++-arm-none-eabi-newlib "${pkgs_core[@]}" \
      || { warn "部分嵌入式包安装失败, 尝试拆开安装"; \
           pkg_install_optional gcc-arm-none-eabi binutils-arm-none-eabi \
             libnewlib-arm-none-eabi libstdc++-arm-none-eabi-newlib "${pkgs_core[@]}" || true; }
    pkg_install_optional openocd gdb-multiarch || true
  else
    pkg_install arm-none-eabi-gcc-cs arm-none-eabi-gcc-cs-c++ \
                arm-none-eabi-binutils-cs arm-none-eabi-newlib \
                "${pkgs_core[@]}" \
      || { warn "部分嵌入式包安装失败, 尝试拆开安装"; \
           pkg_install_optional arm-none-eabi-gcc-cs arm-none-eabi-newlib \
             arm-none-eabi-binutils-cs "${pkgs_core[@]}" || true; }
  fi

  if have arm-none-eabi-gcc; then
    ok "arm-none-eabi-gcc: $(arm-none-eabi-gcc --version 2>/dev/null | head -1)"
  else
    warn "arm-none-eabi-gcc 未安装成功, 可考虑 ARM 官方 toolchain 或 xPack"
  fi
  have openocd && ok "openocd: $(openocd --version 2>&1 | head -1)"

  # udev 规则: 免 root 访问调试器与串口
  install_udev_rules

  # 常用调试工具(可选, 失败不影响)
  if (( ! DRY_RUN )); then
    if have cargo && ! have probe-rs; then
      info "安装 probe-rs (rust 工具链)"
      cargo install probe-rs-tools --locked >/dev/null 2>&1 \
        && ok "probe-rs 已安装" || warn "probe-rs 安装失败(可稍后手动 cargo install)"
    fi
  fi
  ok "嵌入式模块完成"
}

install_udev_rules() {
  local rule_file=/etc/udev/rules.d/99-embedded-debug.rules

  if [[ -f "$rule_file" ]]; then
    info "$rule_file 已存在, 跳过"
    return 0
  fi

  info "安装 udev 规则: ST-Link / J-Link / CMSIS-DAP / 常见 USB 串口免 root"
  local rules
  rules=$(cat <<'RULES'
# --- ST-Link (STMicroelectronics) ---
# ST-Link/V2, V2-1, V3, on-board ST-Link
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="3744", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="3748", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374b", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374d", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374e", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374f", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="3752", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="3753", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="3754", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0483", ATTRS{idProduct}=="374f", MODE="0666", GROUP="plugdev"

# --- SEGGER J-Link ---
ATTRS{idVendor}=="1366", MODE="0666", GROUP="plugdev"

# --- CMSIS-DAP / DAPLink (ARM) ---
ATTRS{idVendor}=="0d28", ATTRS{idProduct}=="0204", MODE="0666", GROUP="plugdev"
# Raspberry Pi Debug Probe / Picoprobe
ATTRS{idVendor}=="2e8a", MODE="0666", GROUP="plugdev"

# --- ESP32 / Espressif 内置 USB-JTAG 串口 ---
ATTRS{idVendor}=="303a", MODE="0666", GROUP="plugdev"

# --- 常见 USB 转串口芯片 (CH340/CH341, CP210x, FTDI, PL2303) ---
ATTRS{idVendor}=="1a86", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="10c4", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="0403", MODE="0666", GROUP="plugdev"
ATTRS{idVendor}=="067b", MODE="0666", GROUP="plugdev"
RULES
)

  if (( DRY_RUN )); then
    printf '%s  $ sudo tee %s <<< (udev rules)%s\n' "$C_DIM" "$rule_file" "$C_RST"
    printf '%s  $ sudo udevadm control --reload-rules && sudo udevadm trigger%s\n' "$C_DIM" "$C_RST"
    return 0
  fi
  sudo_ok || { warn "当前会话无法使用 sudo, 跳过 udev 规则安装 (串口/调试器将需要 root)"; return 1; }

  printf '%s\n' "$rules" | sudo tee "$rule_file" >/dev/null || { warn "写入 udev 规则失败"; return 1; }
  sudo udevadm control --reload-rules 2>/dev/null || true
  sudo udevadm trigger 2>/dev/null || true

  # dialout 组: 串口访问 (Debian 系); plugdev 常在 Fedora 不存在
  if getent group dialout >/dev/null 2>&1; then
    if id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx dialout; then
      info "用户 $TARGET_USER 已在 dialout 组"
    else
      run_sudo usermod -aG dialout "$TARGET_USER" && warn "已加入 dialout 组, 重新登录后生效"
    fi
  fi
  if getent group plugdev >/dev/null 2>&1; then
    id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx plugdev \
      || run_sudo usermod -aG plugdev "$TARGET_USER" || true
  fi
  # Fedora 常用 uucp 组访问串口
  if [[ "$PKG_FAMILY" == "rpm" ]] && getent group uucp >/dev/null 2>&1; then
    id -nG "$TARGET_USER" | tr ' ' '\n' | grep -qx uucp \
      || run_sudo usermod -aG uucp "$TARGET_USER" || true
  fi

  ok "udev 规则已安装: $rule_file"
}

# ---------------------------------------------------------------------------
# 模块: ROS 2
# ---------------------------------------------------------------------------
ROS_DISTRO_CHOICE=""

ros_distro_for_system() {
  # 依据官方 REP 2000 的可用二进制包给出建议
  if [[ "$PKG_FAMILY" == "deb" ]]; then
    case "${DISTRO_ID}:${DISTRO_CODENAME}" in
      ubuntu:noble)  echo "jazzy"  ;;
      ubuntu:jammy)  echo "humble" ;;
      ubuntu:focal)  echo "foxy"   ;;
      *)             echo "jazzy"  ;;
    esac
  else
    case "$DISTRO_VER" in
      9*)  echo "jazzy" ;;
      10*) echo "lyrical" ;;
      *)   echo "jazzy" ;;
    esac
  fi
}

mod_ros2() {
  local distro="${ROS_DISTRO_CHOICE:-$(ros_distro_for_system)}"
  info "ROS 2 发行版: $distro"

  if [[ -f "/opt/ros/${distro}/setup.bash" ]]; then
    info "/opt/ros/${distro} 已存在, 跳过安装"
  else
    if [[ "$PKG_FAMILY" == "deb" ]]; then
      mod_ros2_apt "$distro" || return 1
    else
      mod_ros2_dnf "$distro" || return 1
    fi
  fi

  # 开发工具
  if [[ "$PKG_FAMILY" == "deb" ]]; then
    pkg_install_optional ros-dev-tools || warn "ros-dev-tools 安装失败, 尝试单独装 colcon"
    if ! have colcon; then
      pkg_install_optional python3-colcon-common-extensions python3-rosdep python3-vcstool || true
    fi
  else
    pkg_install_optional cmake gcc-c++ make patch \
      python3-colcon-common-extensions python3-rosdep python3-vcstool \
      python3-pytest python3-setuptools || warn "部分 ROS 开发工具安装失败"
  fi

  # 环境变量 (bash / zsh 均可用)
  ensure_profile_line "if [ -n \"\${ZSH_VERSION:-}\" ] && [ -f /opt/ros/${distro}/setup.zsh ]; then source /opt/ros/${distro}/setup.zsh; else source /opt/ros/${distro}/setup.bash; fi"

  # 镜像模块若已选定 ROS 镜像, 此时 ROS 源刚建立, 在此应用
  if [[ -n "$MIRROR_ROS_URL" && "$MIRROR_ROS_URL" != "https://packages.ros.org/ros2/ubuntu" ]]; then
    apply_ros_apt_mirror "$MIRROR_ROS_URL" || warn "ROS 换源失败, 继续使用官方源"
  fi

  # rosdep 初始化 (幂等: 已初始化则跳过)
  if (( ! DRY_RUN )) && have rosdep; then
    if [[ -f /etc/ros/rosdep/sources.list.d/20-default.list ]]; then
      info "rosdep 已初始化"
    else
      info "初始化 rosdep"
      run_sudo rosdep init >/dev/null 2>&1 || warn "rosdep init 失败(可能已初始化)"
      rosdep update >/dev/null 2>&1 || warn "rosdep update 失败, 请手动执行: rosdep update"
    fi
  fi

  ok "ROS 2 ($distro) 模块完成"
}

mod_ros2_apt() {
  local distro="$1"

  # universe 仓库 + 依赖
  pkg_install software-properties-common curl gnupg lsb-release || return 1
  if (( ! DRY_RUN )); then
    sudo add-apt-repository -y universe >/dev/null 2>&1 || warn "启用 universe 失败"
  fi

  # Ubuntu 24.04 的 apt sources 需含 -updates/-backports, 否则 ros-dev-tools 依赖冲突
  local ubuntu_sources=/etc/apt/sources.list.d/ubuntu.sources
  if [[ -f "$ubuntu_sources" ]] && (( ! DRY_RUN )); then
    if ! grep -q 'noble-updates' "$ubuntu_sources" && grep -q 'Suites:.*noble' "$ubuntu_sources"; then
      info "补充 noble-updates/backports 到 $ubuntu_sources"
      sudo cp "$ubuntu_sources" "${ubuntu_sources}.bak.$$"
      sudo sed -i -E 's/^(Suites:.*noble)([[:space:]]*)$/\1 noble-updates noble-backports/' "$ubuntu_sources" || true
    fi
  fi

  # ros2-apt-source: 官方推荐的仓库配置方式
  if ! dpkg -s ros2-apt-source >/dev/null 2>&1; then
    info "安装 ros2-apt-source (配置 ROS 仓库与密钥)"
    local ros_ver
    if (( DRY_RUN )); then
      printf '%s  $ curl -L -o /tmp/ros2-apt-source.deb https://github.com/ros-infrastructure/ros-apt-source/releases/download/<latest>/ros2-apt-source_<ver>.<codename>_all.deb%s\n' \
        "$C_DIM" "$C_RST"
    else
      ros_ver="$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
        | grep -F '"tag_name"' | awk -F'"' '{print $4}')"
      [[ -z "$ros_ver" ]] && { warn "无法获取 ros-apt-source 版本"; return 1; }
      local codename="${DISTRO_CODENAME:-$(. /etc/os-release && echo "$VERSION_CODENAME")}"
      if curl -L -o /tmp/ros2-apt-source.deb \
        "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ros_ver}/ros2-apt-source_${ros_ver}.${codename}_all.deb"; then
        sudo dpkg -i /tmp/ros2-apt-source.deb || { warn "ros2-apt-source 安装失败"; return 1; }
      else
        warn "下载 ros2-apt-source 失败"; return 1
      fi
    fi
  else
    info "ros2-apt-source 已安装"
  fi

  pkg_update || true
  pkg_install "ros-${distro}-desktop" || {
    warn "ros-${distro}-desktop 安装失败, 回退到 ros-${distro}-ros-base"
    pkg_install "ros-${distro}-ros-base" || return 1
  }
}

mod_ros2_dnf() {
  local distro="$1"

  # EPEL + CRB/PowerTools
  pkg_install curl || return 1
  if ! rpm -q epel-release >/dev/null 2>&1; then
    info "启用 EPEL 仓库"
    local rhel_major; rhel_major="$(rpm -E %rhel 2>/dev/null || echo "")"
    if [[ -n "$rhel_major" && "$rhel_major" =~ ^[0-9]+$ ]]; then
      run_sudo dnf install -y -q "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${rhel_major}.noarch.rpm" \
        || warn "EPEL 安装失败"
    else
      run_sudo dnf install -y -q epel-release || warn "EPEL 安装失败"
    fi
  else
    info "EPEL 已启用"
  fi
  run_sudo env FORCE_DNF=1 crb enable >/dev/null 2>&1 \
    || run_sudo dnf config-manager --set-enabled crb >/dev/null 2>&1 \
    || warn "启用 CRB/PowerTools 失败(非 RHEL 可忽略)"

  # ROS 官方 rpm 仓库配置包
  if ! rpm -q ros2-release >/dev/null 2>&1; then
    info "安装 ros2-release (配置 ROS rpm 仓库)"
    if (( DRY_RUN )); then
      printf '%s  $ sudo dnf install https://github.com/ros-infrastructure/ros-apt-source/releases/download/<ver>/ros2-release-<ver>-1.noarch.rpm%s\n' \
        "$C_DIM" "$C_RST"
    else
      local ros_ver
      ros_ver="$(curl -s https://api.github.com/repos/ros-infrastructure/ros-apt-source/releases/latest \
        | grep -F '"tag_name"' | awk -F'"' '{print $4}')"
      [[ -z "$ros_ver" ]] && { warn "无法获取 ros2-release 版本"; return 1; }
      sudo dnf install -y -q \
        "https://github.com/ros-infrastructure/ros-apt-source/releases/download/${ros_ver}/ros2-release-${ros_ver}-1.noarch.rpm" \
        || { warn "ros2-release 安装失败"; return 1; }
    fi
  else
    info "ros2-release 已安装"
  fi

  pkg_install "ros-${distro}-desktop" || {
    warn "ros-${distro}-desktop 安装失败, 回退到 ros-${distro}-ros-base"
    pkg_install "ros-${distro}-ros-base" || return 1
  }
}

# ---------------------------------------------------------------------------
# 模块: 常用附加工具
# ---------------------------------------------------------------------------
mod_extra() {
  local pkgs
  if [[ "$PKG_FAMILY" == "deb" ]]; then
    pkgs=(jq ripgrep fd-find tree tmux htop httpie shellcheck \
          clangd clang-format cppcheck gdb valgrind \
          minicom picocom can-utils)
  else
    pkgs=(jq ripgrep fd-find tree tmux htop shellcheck \
          clang-tools-extra cppcheck gdb valgrind \
          minicom picocom can-utils)
  fi
  pkg_install_optional "${pkgs[@]}" || warn "部分附加工具安装失败(可忽略)"
  ok "附加工具完成"
}

# ---------------------------------------------------------------------------
# 模块: zsh + oh-my-zsh (+ 插件/主题, 可选设为默认 shell)
# ---------------------------------------------------------------------------
ZSH_THEME_CHOICE="robbyrussell"   # robbyrussell | powerlevel10k | agnoster | ...
ZSH_SET_DEFAULT=1
ZSH_OVERWRITE_RC=0

mod_zsh() {
  # 1) zsh 本体
  pkg_install zsh || { warn "zsh 安装失败"; return 1; }
  if (( ! DRY_RUN )) && ! have zsh; then warn "zsh 不在 PATH 中"; return 1; fi

  local zsh_dir="$HOME/.oh-my-zsh" custom="$HOME/.oh-my-zsh/custom"

  # 2) oh-my-zsh
  if [[ -d "$zsh_dir/.git" ]]; then
    info "oh-my-zsh 已安装: $zsh_dir"
  else
    git_clone https://github.com/ohmyzsh/ohmyzsh.git "$zsh_dir" 0 || { warn "oh-my-zsh 克隆失败"; return 1; }
  fi

  # 3) 插件与主题
  git_clone https://github.com/zsh-users/zsh-autosuggestions.git "$custom/plugins/zsh-autosuggestions" \
    || warn "zsh-autosuggestions 克隆失败"
  git_clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$custom/plugins/zsh-syntax-highlighting" \
    || warn "zsh-syntax-highlighting 克隆失败"
  git_clone https://github.com/zsh-users/zsh-completions.git "$custom/plugins/zsh-completions" \
    || warn "zsh-completions 克隆失败"
  if [[ "$ZSH_THEME_CHOICE" == "powerlevel10k" ]]; then
    git_clone https://github.com/romkatv/powerlevel10k.git "$custom/themes/powerlevel10k" \
      || warn "powerlevel10k 克隆失败(p10k 需要 Nerd Font 字体才好看)"
  fi

  # 4) ~/.zshrc
  write_zshrc

  # 5) 默认 shell
  if (( ZSH_SET_DEFAULT )); then set_default_shell; fi

  ok "zsh 模块完成 (新开终端或 exec zsh 即可使用)"
}

write_zshrc() {
  local rc="$HOME/.zshrc" theme="$ZSH_THEME_CHOICE"
  [[ "$theme" == "powerlevel10k" ]] && theme="powerlevel10k/powerlevel10k"

  # 已有 oh-my-zsh 配置 → 保留用户配置, 仅以管理块方式补上插件加载
  if [[ -f "$rc" ]] && grep -q 'oh-my-zsh' "$rc" 2>/dev/null; then
    info "~/.zshrc 已使用 oh-my-zsh, 保留你的配置"
    if ! grep -q 'zsh-autosuggestions' "$rc" 2>/dev/null; then
      ensure_profile_line '[[ -n "${ZSH_VERSION:-}" && -f "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh" ]] && source "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh"'
    fi
    # syntax-highlighting 必须在插件最后加载
    ensure_profile_line '[[ -n "${ZSH_VERSION:-}" && -f "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh" ]] && source "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh"'
    ensure_profile_line '[[ -n "${ZSH_VERSION:-}" && -d "$HOME/.oh-my-zsh/custom/plugins/zsh-completions/src" ]] && fpath=("$HOME/.oh-my-zsh/custom/plugins/zsh-completions/src" $fpath)'
    return 0
  fi

  # 存在非 oh-my-zsh 的 .zshrc: 不静默覆盖
  if [[ -f "$rc" ]] && (( ! ZSH_OVERWRITE_RC )); then
    warn "~/.zshrc 已存在且未检测到 oh-my-zsh, 未自动覆盖"
    warn "如需使用本脚本生成的配置: 备份后删除 ~/.zshrc 重跑, 或加参数 --zsh-overwrite-rc"
    return 1
  fi

  if (( DRY_RUN )); then
    printf '%s  $ write ~/.zshrc (ZSH_THEME=%s) + oh-my-zsh plugins%s\n' "$C_DIM" "$theme" "$C_RST"
    return 0
  fi

  [[ -f "$rc" ]] && cp "$rc" "$rc.bak.envstrap.$(date +%Y%m%d%H%M%S)"
  cat > "$rc" <<ZSHRC
# ~/.zshrc — 由 envstrap.sh 生成, 可自由修改
# 注意: 文件末尾的 envstrap 管理块由脚本维护, 个人配置建议写到 ~/.zshrc.local

export ZSH="\$HOME/.oh-my-zsh"
ZSH_THEME="$theme"

# 插件: git/z 增强、解压、命令未找到提示、彩色 man、sudo 补全
#      自动建议、补全定义、语法高亮(语法高亮应放最后)
plugins=(
  git
  z
  extract
  command-not-found
  colored-man-pages
  sudo
  zsh-autosuggestions
  zsh-completions
  zsh-syntax-highlighting
)

# zsh-completions 需在 compinit 前加入 fpath
fpath=("\$ZSH/custom/plugins/zsh-completions/src" \$fpath)
# 避免可写目录导致的 compaudit 警告
ZSH_DISABLE_COMPFIX=true

# 历史记录
HISTFILE="\$HOME/.zsh_history"
HISTSIZE=100000
SAVEHIST=100000
setopt HIST_IGNORE_ALL_DUPS HIST_REDUCE_BLANKS HIST_IGNORE_SPACE
setopt SHARE_HISTORY INC_APPEND_HISTORY EXTENDED_HISTORY
setopt INTERACTIVE_COMMENTS NO_BEEP

# oh-my-zsh 自动更新
zstyle ':omz:update' mode auto
zstyle ':omz:update' frequency 13

source "\$ZSH/oh-my-zsh.sh"

# ---- 常用别名 ----
alias ll='ls -alFh'
alias la='ls -A'
alias l='ls -CF'
alias ..='cd ..'
alias ...='cd ../..'
alias gs='git status -sb'
alias gd='git diff'
alias gl='git log --oneline --graph --decorate -20'
alias gco='git checkout'
alias gb='git branch -vv'
alias dps='docker ps --format "table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Ports}}"'
alias dcu='docker compose up -d'
alias dcd='docker compose down'
alias dcl='docker compose logs -f'
alias ports='ss -tulpn'

# ---- 个人附加配置(不参与脚本管理) ----
[[ -f "\$HOME/.zshrc.local" ]] && source "\$HOME/.zshrc.local"
ZSHRC
  ok "已写入 ~/.zshrc (theme=$theme)"
  _profile_regenerate
}

set_default_shell() {
  local zsh_path cur
  zsh_path="$(command -v zsh 2>/dev/null || true)"
  if [[ -z "$zsh_path" ]]; then warn "未找到 zsh, 跳过 chsh"; return 1; fi
  cur="$(getent passwd "$TARGET_USER" 2>/dev/null | cut -d: -f7)"
  if [[ "$cur" == "$zsh_path" ]]; then info "默认 shell 已是 zsh"; return 0; fi
  if (( DRY_RUN )); then
    printf '%s  $ sudo chsh -s %s %s%s\n' "$C_DIM" "$zsh_path" "$TARGET_USER" "$C_RST"; return 0
  fi
  if ! grep -qxF "$zsh_path" /etc/shells 2>/dev/null; then
    printf '%s\n' "$zsh_path" | run_sudo tee -a /etc/shells >/dev/null || true
  fi
  if run_sudo chsh -s "$zsh_path" "$TARGET_USER"; then
    ok "默认 shell 已设为 zsh (重新登录后生效)"
  else
    warn "chsh 失败, 可手动执行: chsh -s $zsh_path"
  fi
}

# ---------------------------------------------------------------------------
# 交互式菜单
# ---------------------------------------------------------------------------
MODULE_KEYS=(    base      mirror      docker     node       python     rust       embedded     ros2       zsh        gitconfig extra )
MODULE_NAMES=(   "基础工具" "镜像源测速" "Docker"   "Node/pnpm" "Python/uv" "Rust"     "嵌入式STM32" "ROS 2"    "zsh/OMZ"  "Git 配置" "附加工具" )
MODULE_FUNCS=(   mod_base  mod_mirrors mod_docker mod_node   mod_python mod_rust   mod_embedded mod_ros2   mod_zsh    mod_git_config mod_extra )
MODULE_DEFAULT=( 1         1           1          1          1          1          1            0          1          0         0 )
# 各模块是否需要 root 权限(仅用于决定要不要提前申请 sudo)
MODULE_SUDO=(    1         1           1          0          1          0          1            1          1          0         1 )
# 模块说明(TUI 下方帮助栏显示)
MODULE_DESC=(
  "编译器/cmake/git/curl/patch 与 UTF-8 locale"
  "对 npm/PyPI/cargo/rustup/Docker/ROS 实际测速并切到最快源"
  "Docker CE 官方源 + buildx/compose, 免 sudo, 日志轮转"
  "fnm 管理 Node LTS + pnpm (用户级, 无需 sudo)"
  "uv (用户级) + python3-venv, pip/uv 索引随换源"
  "rustup 到 ~/.cargo (不碰系统 rust), clippy/rustfmt, 嵌入式 target"
  "arm-none-eabi-gcc + openocd/probe-rs + USB 调试器 udev 免 root"
  "ros-<distro>-desktop + colcon/rosdep (体积较大, 默认不装)"
  "zsh + oh-my-zsh + 自动建议/语法高亮/补全, 可设为默认 shell"
  "git 全局 user.name/user.email 与常用选项"
  "jq/rg/fd/tmux/htop/clangd/valgrind/minicom/can-utils 等"
)

declare -a SELECTED=()

idx_of() { # <key> → 模块索引
  local k="$1" i
  for i in "${!MODULE_KEYS[@]}"; do
    [[ "${MODULE_KEYS[$i]}" == "$k" ]] && { printf '%s' "$i"; return 0; }
  done
  return 1
}

# ===========================================================================
# TUI 基础层 (纯 bash + ANSI, 无外部依赖; 非 TTY/不支持时自动退化为行式菜单)
# ===========================================================================
TUI_ACTIVE=0
TUI_ROWS_DRAWN=0
TUI_KEY=""
TUI_RESULT=0
TUI_TEXT=""
TUI_SAVED_STTY=""

if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" == *[Uu][Tt][Ff]* ]]; then
  TUI_PTR="❯"; TUI_RULE_CH="─"; TUI_ARROW_UP="↑"; TUI_ARROW_DN="↓"
else
  TUI_PTR=">"; TUI_RULE_CH="-"; TUI_ARROW_UP="^"; TUI_ARROW_DN="v"
fi

# 终端是否支持 TUI
tui_supported() {
  (( ${NO_TUI:-0} )) && return 1
  [[ -t 0 && -t 1 ]] || return 1
  [[ -n "${TERM:-}" && "${TERM:-}" != "dumb" ]] || return 1
  local rows
  rows="$(stty size 2>/dev/null | awk '{print $1}')"
  # 仅在能确定行数且确实太小时禁用; 未知(0)时仍用宽 80 回退值照常绘屏
  if [[ -n "$rows" && "$rows" != "0" ]] && (( rows < 20 )); then return 1; fi
  return 0
}

tui_width() {
  local w
  w="$(stty size 2>/dev/null | awk '{print $2}')"
  [[ -z "$w" || "$w" -lt 40 ]] && w=80
  printf '%s' "$w"
}

# 按显示宽度截断(CJK 算 2 列)
tui_fit() {
  local s="$1" max="$2" out="" w=0 ch cw i
  for (( i=0; i<${#s}; i++ )); do
    ch="${s:i:1}"
    cw=1
    [[ "$ch" =~ [[:ascii:]] ]] || cw=2
    if (( w + cw > max - 1 )); then out+="…"; break; fi
    out+="$ch"; w=$(( w + cw ))
  done
  printf '%s' "$out"
}

tui_rule() { # <width>
  local s; printf -v s '%*s' "$1" ''
  printf '%s' "${s// /$TUI_RULE_CH}"
}

tui_begin() {
  TUI_SAVED_STTY="$(stty -g 2>/dev/null || true)"
  stty -icanon -echo 2>/dev/null || true
  printf '\033[?25l'          # 隐藏光标
  TUI_ROWS_DRAWN=0
  TUI_ACTIVE=1
  trap 'tui_end; exit 130' INT
}

tui_end() {
  (( TUI_ACTIVE )) || return 0
  printf '\033[?25h'          # 恢复光标
  [[ -n "$TUI_SAVED_STTY" ]] && stty "$TUI_SAVED_STTY" 2>/dev/null
  TUI_ACTIVE=0
  trap - INT
}

# 读取一个按键 → TUI_KEY: UP/DOWN/LEFT/RIGHT/ENTER/SPACE/ESC/CHAR:x/TIMEOUT/EOF
tui_read_key() { # [timeout_sec]
  local tmo="${1:-}" k rest
  TUI_KEY=""
  if [[ -n "$tmo" ]]; then
    IFS= read -rsn1 -t "$tmo" k || { TUI_KEY="TIMEOUT"; return 1; }
  else
    IFS= read -rsn1 k || { TUI_KEY="EOF"; return 1; }
  fi
  case "$k" in
    $'\e')
      IFS= read -rsn1 -t 0.05 rest || true
      if [[ -z "$rest" ]]; then TUI_KEY="ESC"; return 0; fi
      if [[ "$rest" == "[" || "$rest" == "O" ]]; then
        IFS= read -rsn1 -t 0.05 rest || true
        case "$rest" in
          A) TUI_KEY="UP" ;;
          B) TUI_KEY="DOWN" ;;
          C) TUI_KEY="RIGHT" ;;
          D) TUI_KEY="LEFT" ;;
          H) TUI_KEY="HOME" ;;
          F) TUI_KEY="END" ;;
          5) IFS= read -rsn1 -t 0.05 rest || true; TUI_KEY="PGUP" ;;
          6) IFS= read -rsn1 -t 0.05 rest || true; TUI_KEY="PGDN" ;;
          *) TUI_KEY="UNKNOWN" ;;
        esac
      else
        TUI_KEY="UNKNOWN"
      fi
      ;;
    $'\n'|$'\r'|"") TUI_KEY="ENTER" ;;
    ' ') TUI_KEY="SPACE" ;;
    $'\t') TUI_KEY="TAB" ;;
    *) TUI_KEY="CHAR:$k" ;;
  esac
  return 0
}

# 重绘一组行(原地刷新, 不滚动历史)
tui_render() {
  local -a lines=("$@")
  local n=${#lines[@]} i extra
  if (( TUI_ROWS_DRAWN > 0 )); then printf '\033[%dA' "$TUI_ROWS_DRAWN"; fi
  for (( i=0; i<n; i++ )); do printf '\r\033[K%s\n' "${lines[$i]}"; done
  if (( TUI_ROWS_DRAWN > n )); then
    extra=$(( TUI_ROWS_DRAWN - n ))
    for (( i=0; i<extra; i++ )); do printf '\r\033[K\n'; done
    printf '\033[%dA' "$extra"
  fi
  TUI_ROWS_DRAWN=$n
}

# 抹掉已绘制的区域, 让后续正常输出接管
tui_clear() {
  (( TUI_ROWS_DRAWN > 0 )) || return 0
  local i
  printf '\033[%dA' "$TUI_ROWS_DRAWN"
  for (( i=0; i<TUI_ROWS_DRAWN; i++ )); do printf '\r\033[K\n'; done
  printf '\033[%dA' "$TUI_ROWS_DRAWN"
  TUI_ROWS_DRAWN=0
}

count_selected() {
  local i c=0
  for i in "${!SELECTED[@]}"; do (( ${SELECTED[$i]:-0} )) && c=$((c+1)); done
  printf '%s' "$c"
}

# ---- 提问原语: TUI 激活时用方向键/单键, 否则退化为行式问答 ----

ask_confirm() { # <prompt> <y|n>  → 返回 0 表示 yes
  local prompt="$1" def="${2:-y}" ans
  if (( ! TUI_ACTIVE )); then
    if [[ "$def" == "y" ]]; then read -r -p "$prompt [Y/n]: " ans; else read -r -p "$prompt [y/N]: " ans; fi
    ans="${ans:-$def}"
    [[ "$ans" =~ ^[Yy] ]]
    return
  fi
  local suffix="[Y/n]"; [[ "$def" == "n" ]] && suffix="[y/N]"
  while true; do
    printf '\r\033[K  %s %s ' "$prompt" "$suffix"
    tui_read_key
    case "$TUI_KEY" in
      CHAR:y|CHAR:Y) printf '\r\033[K  %s %s %s\n' "$prompt" "$suffix" "y"; return 0 ;;
      CHAR:n|CHAR:N) printf '\r\033[K  %s %s %s\n' "$prompt" "$suffix" "n"; return 1 ;;
      ENTER|TIMEOUT) printf '\r\033[K  %s %s %s\n' "$prompt" "$suffix" "$def"; [[ "$def" == "y" ]]; return $? ;;
      ESC) printf '\r\033[K  %s %s %s (默认)\n' "$prompt" "$suffix" "$def"; [[ "$def" == "y" ]]; return $? ;;
    esac
  done
}

ask_text() { # <prompt> [default] → TUI_TEXT
  local prompt="$1" def="${2:-}" ans=""
  local was_tui=$TUI_ACTIVE
  (( was_tui )) && tui_end           # 文本输入需临时恢复终端常规模式
  if [[ -n "$def" ]]; then read -r -p "  $prompt [$def]: " ans; else read -r -p "  $prompt: " ans; fi
  (( was_tui )) && tui_begin
  TUI_TEXT="${ans:-$def}"
  return 0
}

ask_choice() { # <title> <prompt> <default_idx> <option...> → TUI_RESULT
  local title="$1" prompt="$2" def="${3:-0}"; shift 3
  local -a opts=("$@")
  local n=${#opts[@]}
  (( n > 0 )) || { TUI_RESULT=0; return 0; }

  if (( ! TUI_ACTIVE )); then
    say ""
    say "${C_BLD}${title}${C_RST}"
    local i
    for i in "${!opts[@]}"; do say "  $((i+1))) ${opts[$i]}"; done
    local ans
    read -r -p "$prompt [$(($def+1))]: " ans
    ans="${ans:-$((def+1))}"
    if [[ "$ans" =~ ^[0-9]+$ ]] && (( ans >= 1 && ans <= n )); then TUI_RESULT=$((ans-1)); else TUI_RESULT="$def"; fi
    return 0
  fi

  local cur="$def" tw; tw="$(tui_width)"
  while true; do
    local -a L=("" "  ${C_BLD}${title}${C_RST}" "")
    local i ptr
    for i in "${!opts[@]}"; do
      (( i == cur )) && ptr="${C_BLU}${TUI_PTR}${C_RST}" || ptr=" "
      L+=("   $ptr $(tui_fit "${opts[$i]}" $((tw-8)))")
    done
    L+=("" "  ${C_DIM}${TUI_ARROW_UP}${TUI_ARROW_DN}/jk 选择   Enter 确认   1-${n} 直选${C_RST}")
    tui_render "${L[@]}"
    tui_read_key
    case "$TUI_KEY" in
      UP|CHAR:k)   cur=$(( (cur - 1 + n) % n )) ;;
      DOWN|CHAR:j) cur=$(( (cur + 1) % n )) ;;
      HOME)        cur=0 ;;
      END)         cur=$((n-1)) ;;
      ENTER)       break ;;
      CHAR:[1-9])
        local d="${TUI_KEY#CHAR:}"
        if (( d >= 1 && d <= n )); then cur=$((d-1)); break; fi
        ;;
    esac
  done
  tui_clear
  TUI_RESULT="$cur"
  say "  ${C_BLD}${title}${C_RST}: ${opts[$cur]}"
  return 0
}

# ---- 模块多选(TUI) ----
tui_draw_modules() { # <cur>
  local cur="$1" tw i ptr mark num name
  tw="$(tui_width)"
  local -a L=("" "  ${C_BLD}请选择要安装的模块${C_RST}" "")
  for i in "${!MODULE_KEYS[@]}"; do
    (( i == cur )) && ptr="${C_BLU}${TUI_PTR}${C_RST}" || ptr=" "
    (( ${SELECTED[$i]:-0} )) && mark="${C_GRN}[x]${C_RST}" || mark="${C_DIM}[ ]${C_RST}"
    num="$(pad_disp "$((i+1))." 4)"
    name="$(pad_disp "${MODULE_NAMES[$i]}" 13)"
    L+=("   $ptr $mark $num$name")
  done
  L+=("  ${C_DIM}$(tui_rule $((tw-4)))${C_RST}")
  L+=("  ${C_BLD}说明${C_RST}: $(tui_fit "${MODULE_DESC[$cur]}" $((tw-10)))")
  L+=("  ${C_DIM}${TUI_ARROW_UP}${TUI_ARROW_DN}/jk 移动   Space 切换   a 全选   n 全不选   i 反选   1-9 直切   Enter 开始   q 退出${C_RST}")
  L+=("  ${C_DIM}已选 $(count_selected)/${#MODULE_KEYS[@]} 项${C_RST}")
  tui_render "${L[@]}"
}

menu_select_modules_tui() {
  local cur=0 i
  while true; do
    tui_draw_modules "$cur"
    if ! tui_read_key; then [[ "$TUI_KEY" == "EOF" ]] && TUI_KEY="CHAR:q"; fi
    case "$TUI_KEY" in
      UP|CHAR:k)   cur=$(( (cur - 1 + ${#MODULE_KEYS[@]}) % ${#MODULE_KEYS[@]} )) ;;
      DOWN|CHAR:j) cur=$(( (cur + 1) % ${#MODULE_KEYS[@]} )) ;;
      HOME)        cur=0 ;;
      END)         cur=$(( ${#MODULE_KEYS[@]} - 1 )) ;;
      SPACE|CHAR:x) SELECTED[$cur]=$(( 1 - ${SELECTED[$cur]:-0} )) ;;
      CHAR:a) for i in "${!SELECTED[@]}"; do SELECTED[$i]=1; done ;;
      CHAR:n) for i in "${!SELECTED[@]}"; do SELECTED[$i]=0; done ;;
      CHAR:i) for i in "${!SELECTED[@]}"; do SELECTED[$i]=$(( 1 - ${SELECTED[$i]:-0} )); done ;;
      CHAR:q|ESC) tui_clear; tui_end; say "已取消"; exit 130 ;;
      CHAR:[1-9])
        local d="${TUI_KEY#CHAR:}" idx=$(( ${TUI_KEY#CHAR:} - 1 ))
        (( idx < ${#MODULE_KEYS[@]} )) && SELECTED[$idx]=$(( 1 - ${SELECTED[$idx]:-0} ))
        ;;
      ENTER) break ;;
    esac
  done
  tui_clear
  report_module_selection
}

menu_select_modules_plain() {
  local i mark ans n idx
  while true; do
    say ""
    say "${C_BLD}请选择要安装的模块 (回车=确认, 数字=切换):${C_RST}"
    for i in "${!MODULE_KEYS[@]}"; do
      mark="${C_DIM}[ ]${C_RST}"
      (( ${SELECTED[$i]:-0} )) && mark="${C_GRN}[x]${C_RST}"
      printf '  %2d) %s %s%s%s%s\n' "$((i+1))" "$mark" "$C_BLD" "$(pad_disp "${MODULE_NAMES[$i]}" 13)" "$C_RST" "${C_DIM}${MODULE_DESC[$i]}${C_RST}"
    done
    say ""
    read -r -p "切换 (如 '7' 或 '3 4'; a=全选 n=全不选; 直接回车开始安装): " ans
    [[ -z "$ans" ]] && break
    case "$ans" in
      a) for i in "${!SELECTED[@]}"; do SELECTED[$i]=1; done; continue ;;
      n) for i in "${!SELECTED[@]}"; do SELECTED[$i]=0; done; continue ;;
      i) for i in "${!SELECTED[@]}"; do SELECTED[$i]=$(( 1 - ${SELECTED[$i]:-0} )); done; continue ;;
    esac
    for n in $ans; do
      if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= ${#MODULE_KEYS[@]} )); then
        idx=$((n-1)); SELECTED[$idx]=$(( 1 - ${SELECTED[$idx]:-0} ))
      else
        warn "无效选择: $n"
      fi
    done
  done
  report_module_selection
}

report_module_selection() {
  local i
  local -a names=()
  for i in "${!SELECTED[@]}"; do (( ${SELECTED[$i]:-0} )) && names+=("${MODULE_NAMES[$i]}"); done
  if (( ${#names[@]} == 0 )); then warn "未选择任何模块"; exit 0; fi
  say "  ${C_BLD}已选模块${C_RST}: ${names[*]}"
  say ""
}

# ---- 各模块的后续选项 ----
ask_followups() {
  local mi di ri zi gi rec a
  mi="$(idx_of mirror || true)"
  di="$(idx_of docker || true)"
  ri="$(idx_of ros2 || true)"
  zi="$(idx_of zsh || true)"
  gi="$(idx_of gitconfig || true)"

  # ---- 镜像源策略 ----
  if [[ -n "$mi" ]] && (( ${SELECTED[$mi]:-0} )); then
    ask_choice "镜像源策略" "选择镜像源策略" 0 \
      "全部候选测速取最快 (官方 + 国内)" \
      "只测国内镜像取最快" \
      "保持/恢复官方源 (不测速)" \
      "跳过换源"
    case "$TUI_RESULT" in
      0) MIRROR_MODE="auto" ;;
      1) MIRROR_MODE="cn" ;;
      2) MIRROR_MODE="official" ;;
      3) MIRROR_MODE="skip" ;;
      *) MIRROR_MODE="auto" ;;
    esac
    if [[ "$MIRROR_MODE" != "skip" && "$DISTRO_ID" == "ubuntu" && "$PKG_FAMILY" == "deb" ]]; then
      ask_confirm "同时把 apt 主源切到最快的国内镜像? (自动备份, 失败回滚)" n && MIRROR_APPLY_APT_MAIN=1
    fi
  fi

  # ---- Docker 免 sudo ----
  if [[ -n "$di" ]] && (( ${SELECTED[$di]:-0} )); then
    ask_confirm "将当前用户 $TARGET_USER 加入 docker 组以支持免 sudo?" y || DOCKER_SUDO_GROUP=0
  fi

  # ---- ROS 2 发行版 ----
  if [[ -n "$ri" ]] && (( ${SELECTED[$ri]:-0} )); then
    rec="$(ros_distro_for_system)"
    ask_choice "ROS 2 发行版" "选择 ROS 2 发行版" 0 \
      "$rec (本机 $DISTRO_ID $DISTRO_VER 推荐)" \
      "jazzy (Ubuntu 24.04 / RHEL 9)" \
      "humble (Ubuntu 22.04)" \
      "自定义 (手动输入代号)"
    case "$TUI_RESULT" in
      0) ROS_DISTRO_CHOICE="$rec" ;;
      1) ROS_DISTRO_CHOICE="jazzy" ;;
      2) ROS_DISTRO_CHOICE="humble" ;;
      3) ask_text "输入 ROS 2 发行版代号 (如 jazzy)" "$rec"; ROS_DISTRO_CHOICE="$TUI_TEXT" ;;
      *) ROS_DISTRO_CHOICE="$rec" ;;
    esac
    if [[ "$PKG_FAMILY" == "deb" ]]; then
      local supported=""
      case "${DISTRO_CODENAME}:${ROS_DISTRO_CHOICE}" in
        noble:jazzy|jammy:humble|focal:foxy|noble:humble) supported=1 ;;
      esac
      [[ -z "$supported" ]] && warn "ROS 2 ${ROS_DISTRO_CHOICE} 在 ${DISTRO_ID} ${DISTRO_CODENAME} 上可能没有官方二进制包"
    fi
  fi

  # ---- zsh / oh-my-zsh ----
  if [[ -n "$zi" ]] && (( ${SELECTED[$zi]:-0} )); then
    ask_choice "zsh 主题" "选择 zsh 主题" 0 \
      "robbyrussell (默认, 无需特殊字体)" \
      "agnoster (需 Powerline 字体)" \
      "powerlevel10k (需 Nerd Font 字体)"
    case "$TUI_RESULT" in
      1) ZSH_THEME_CHOICE="agnoster" ;;
      2) ZSH_THEME_CHOICE="powerlevel10k" ;;
      *) ZSH_THEME_CHOICE="robbyrussell" ;;
    esac
    ask_confirm "把 zsh 设为默认登录 shell (chsh)?" y || ZSH_SET_DEFAULT=0
    if [[ -f "$HOME/.zshrc" ]] && ! grep -q 'oh-my-zsh' "$HOME/.zshrc" 2>/dev/null; then
      ask_confirm "检测到已有 ~/.zshrc, 备份并替换为本脚本生成的配置?" n && ZSH_OVERWRITE_RC=1
    fi
  fi

  # ---- git 身份 ----
  if [[ -n "$gi" ]] && (( ! ${SELECTED[$gi]:-0} )); then
    ask_confirm "是否顺带配置 git 全局身份 (user.name/email)?" n && SELECTED[$gi]=1
  fi
  return 0
}

interactive_menu() {
  local i
  SELECTED=()
  for i in "${!MODULE_KEYS[@]}"; do SELECTED[$i]="${MODULE_DEFAULT[$i]}"; done

  if tui_supported; then
    tui_begin
    menu_select_modules_tui
    ask_followups
    tui_end
  else
    menu_select_modules_plain
    ask_followups
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 汇总
# ---------------------------------------------------------------------------
print_summary() {
  say ""
  say "${C_BLD}================ 安装结果汇总 ================${C_RST}"
  local i
  for i in "${!RESULT_NAMES[@]}"; do
    local state="${RESULT_STATES[$i]}"
    local tag color
    case "$state" in
      ok)   tag="OK  "; color="$C_GRN" ;;
      skip) tag="SKIP"; color="$C_DIM" ;;
      fail) tag="FAIL"; color="$C_RED" ;;
      dry)  tag="DRY "; color="$C_YEL" ;;
      *)    tag="?   "; color="$C_RST" ;;
    esac
    printf '  %s[%s]%s %s %s\n' "$color" "$tag" "$C_RST" "$(pad_disp "${RESULT_NAMES[$i]}" 14)" "${RESULT_NOTES[$i]}"
  done
  say "${C_BLD}=============================================${C_RST}"

  if (( ${#MIRROR_SUMMARY[@]} )); then
    say ""
    say "${C_BLD}镜像源选择:${C_RST}"
    local m
    for m in "${MIRROR_SUMMARY[@]}"; do say "  - $m"; done
    say "  ${C_DIM}配置位置: ~/.npmrc | ~/.config/uv/uv.toml | ~/.cargo/config.toml | /etc/docker/daemon.json${C_RST}"
  fi

  local failed=0
  for i in "${!RESULT_STATES[@]}"; do
    [[ "${RESULT_STATES[$i]}" == "fail" ]] && failed=1
  done

  say ""
  say "${C_BLD}后续步骤:${C_RST}"
  say "  1. 重新登录 (或 newgrp docker) 使 docker / dialout / zsh 默认 shell 生效"
  say "  2. 新开终端使 PATH 与 shell 集成生效, 或执行: source ~/.bashrc / exec zsh"
  say "  3. 验证:"
  say "       docker run --rm hello-world"
  say "       node -v && pnpm -v && uv --version && rustc --version"
  say "       arm-none-eabi-gcc --version && openocd --version"
  say "       source /opt/ros/<distro>/setup.bash && ros2 topic list"
  say "  4. 若 rustc 仍指向系统版本, 确认 ~/.cargo/bin 在 PATH 中更靠前"

  if (( failed )); then
    say ""
    warn "有模块安装失败, 请查看上方日志。脚本可重复执行(幂等), 失败项可单独重跑。"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 参数解析
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
envstrap.sh — 交互式 Linux 开发环境安装脚本

用法:
  ./envstrap.sh [选项]

选项:
  -a, --all          安装全部模块(非交互; ROS 2 用系统推荐发行版)
      --only LIST    只安装指定模块, 逗号分隔
                     可用: base,mirror,docker,node,python,rust,embedded,ros2,zsh,gitconfig,extra
                     例: --only node,python,mirror  只装 web 工具链并测速换源
      --ros DISTRO   指定 ROS 2 发行版(如 jazzy / humble / lyrical)
      --mirror MODE  镜像源策略: auto(默认,全部候选测速取最快) | cn(仅国内) |
                     official(恢复官方) | skip(跳过)
      --apt-mirror URL   切换 Ubuntu apt 主源(留空则测速选择; 自动备份+失败回滚)
      --zsh-theme NAME   zsh 主题: robbyrussell(默认) | agnoster | powerlevel10k
      --zsh-overwrite-rc 允许备份并覆盖已有的 ~/.zshrc
      --no-chsh      不把 zsh 设为默认登录 shell
      --no-docker-group   不把当前用户加入 docker 组
      --dry-run      只打印将执行的命令, 不做任何修改
      --no-tui       禁用方向键 TUI, 使用行式数字菜单(脚本/CI 调用)
  -y, --yes          非交互确认(默认值全部接受)
  -l, --list         列出模块
  -h, --help         显示帮助

环境变量:
  ENVSTRAP_NO_PROFILE=1  绝不修改 ~/.bashrc / ~/.zshrc / uv.toml / pip.conf /
                          cargo config (用 dotfiles 工具管理的用户推荐); 需要添加的
                          行会打印出来由你自行放入配置

示例:
  ./envstrap.sh                            # 交互式(推荐)
  ./envstrap.sh --all --mirror auto        # 全量 + 自动测速换源
  ./envstrap.sh --only mirror              # 只测速换源
  ./envstrap.sh --only node,python,rust    # 只装 web / rust 工具链
  ./envstrap.sh --only zsh --zsh-theme powerlevel10k
  ./envstrap.sh --dry-run --all            # 预演

支持系统: Ubuntu/Debian (apt), Fedora/RHEL (dnf)
EOF
}

ONLY_LIST=""

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -a|--all) INSTALL_ALL=1 ;;
      --only) ONLY_LIST="${2:-}"; shift ;;
      --only=*) ONLY_LIST="${1#*=}" ;;
      --ros) ROS_DISTRO_CHOICE="${2:-}"; shift ;;
      --ros=*) ROS_DISTRO_CHOICE="${1#*=}" ;;
      --mirror) MIRROR_MODE="${2:-auto}"; shift ;;
      --mirror=*) MIRROR_MODE="${1#*=}" ;;
      --apt-mirror) MIRROR_APPLY_APT_MAIN=1; MIRROR_APT_URL="${2:-}"; shift ;;
      --apt-mirror=*) MIRROR_APPLY_APT_MAIN=1; MIRROR_APT_URL="${1#*=}" ;;
      --zsh-theme) ZSH_THEME_CHOICE="${2:-robbyrussell}"; shift ;;
      --zsh-theme=*) ZSH_THEME_CHOICE="${1#*=}" ;;
      --zsh-overwrite-rc) ZSH_OVERWRITE_RC=1 ;;
      --no-chsh) ZSH_SET_DEFAULT=0 ;;
      --no-docker-group) DOCKER_SUDO_GROUP=0 ;;
      --dry-run) DRY_RUN=1 ;;
      --no-tui) NO_TUI=1 ;;
      -y|--yes) ASSUME_YES=1 ;;
      -l|--list)
        local i
        for i in "${!MODULE_KEYS[@]}"; do
          printf '%-10s %s\n' "${MODULE_KEYS[$i]}" "${MODULE_NAMES[$i]}"
        done
        exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) err "未知参数: $1"; usage; exit 2 ;;
    esac
    shift
  done
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"
  detect_distro

  say "${C_BLD}Linux 开发环境安装脚本${C_RST}"
  say "  发行版: ${DISTRO_ID} ${DISTRO_VER} (${PKG_FAMILY})"
  say "  用户:   ${TARGET_USER}"
  (( DRY_RUN )) && say "  ${C_YEL}DRY-RUN 模式: 不会做任何修改${C_RST}"

  # 决定要跑的模块
  if (( INSTALL_ALL )); then
    SELECTED=()
    local i gi; gi="$(idx_of gitconfig || true)"
    for i in "${!MODULE_KEYS[@]}"; do
      SELECTED[$i]=1
    done
    # --all 不包含 gitconfig (非交互无法询问身份)
    [[ -n "$gi" ]] && SELECTED[$gi]=0
    [[ -n "$ONLY_LIST" ]] && warn "--all 与 --only 同时给出, 以 --only 为准"
  fi

  if [[ -n "$ONLY_LIST" ]]; then
    SELECTED=()
    local i
    for i in "${!MODULE_KEYS[@]}"; do SELECTED[$i]=0; done
    local key found
    IFS=',' read -ra _keys <<< "$ONLY_LIST"
    for key in "${_keys[@]}"; do
      key="$(echo "$key" | tr -d '[:space:]')"
      found=0
      for i in "${!MODULE_KEYS[@]}"; do
        if [[ "${MODULE_KEYS[$i]}" == "$key" ]]; then
          SELECTED[$i]=1; found=1; break
        fi
      done
      (( found )) || warn "未知模块名: $key"
    done
  fi

  # 交互选择
  if (( ${#SELECTED[@]} == 0 )); then
    if [[ -t 0 ]]; then
      interactive_menu
    else
      err "非交互环境请使用 --all 或 --only <模块列表>"
      exit 2
    fi
  fi

  # 依据最终选中的模块申请 sudo 凭据(必须在选择之后, 否则无从得知该不该要 root)
  local need_sudo=0 i
  for i in "${!MODULE_KEYS[@]}"; do
    (( ${SELECTED[$i]:-0} )) || continue
    (( ${MODULE_SUDO[$i]:-0} )) && need_sudo=1
  done
  if (( need_sudo && ! DRY_RUN )) && ! sudo_ok; then
    info "所选模块需要 sudo 权限, 请先验证:"
    sudo -v || { err "无法获取 sudo 权限"; exit 1; }
    # 后台保活, 避免连续安装期间反复询问
    ( while true; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
    SUDO_KEEPALIVE_PID=$!
    trap '[[ -n "${SUDO_KEEPALIVE_PID:-}" ]] && kill "$SUDO_KEEPALIVE_PID" 2>/dev/null' EXIT
  elif (( ! need_sudo )); then
    info "所选模块不需要 root 权限, 跳过 sudo 验证"
  fi

  # 执行
  local state note
  for i in "${!MODULE_KEYS[@]}"; do
    (( ${SELECTED[$i]:-0} )) || continue
    name="${MODULE_NAMES[$i]}"
    if (( DRY_RUN )); then
      note="(dry-run)"
    else
      note=""
    fi
    printf '\n%s==> %s%s\n' "$C_BLD" "$name" "$C_RST"
    if "${MODULE_FUNCS[$i]}"; then
      state="ok"
      (( DRY_RUN )) && state="dry"
    else
      state="fail"
      warn "模块 [$name] 失败, 继续后续模块"
    fi
    record "$name" "$state" "$note"
  done

  if (( ${#RESULT_NAMES[@]} == 0 )); then
    warn "没有选择任何模块"
    exit 0
  fi

  print_summary
}

main "$@"
