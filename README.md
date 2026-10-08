# setup-dev.sh

交互式 Linux 开发环境安装脚本，面向 **Web 全栈 / ROS 2 / Rust / STM32 嵌入式** 的开发者。

一台新装的 Ubuntu/Debian 或 Fedora/RHEL 上跑一次，把常用工具链、镜像源、shell 环境配好。

```bash
./setup-dev.sh                     # 交互式 TUI（推荐）
./setup-dev.sh --dry-run --all     # 预演，不改任何东西
```

## 特性

- **纯 bash TUI**：方向键多选模块、`Space` 切换、`a`/`n`/`i` 全选/全不选/反选；单选与是/否同样用 TUI（是/否**不用回车**）。零外部依赖——不需要 `whiptail`/`dialog`/`gum`（新机器上装这些本身就是鸡生蛋问题）。
- **终端不支持时自动降级**为行式菜单：非 TTY、`TERM` 为空或 `dumb`、终端高度 < 20 行，或显式 `--no-tui`。
- **双发行版**：自动识别 `apt` 系与 `dnf` 系；ROS 2 发行版按官方 REP-2000 推荐（noble→jazzy、jammy→humble、RHEL9→jazzy、RHEL10→lyrical）。
- **镜像源实测选优**：对候选源真实下载一段数据测速，选最快的写进配置，而不是按 ping 猜。
- **幂等 + 失败不中断**：重复执行不会重复安装/重复写配置；单个模块失败只记录并继续，最后给出汇总表。
- **可预演**：`--dry-run` 保证零写入（连 sudo 都不会请求）。

## 模块

| 模块 | 内容 |
|---|---|
| `base` | 编译器/cmake/git/curl/patch、`python3`、UTF-8 locale |
| `mirror` | npm/pnpm、PyPI(uv/pip)、cargo、rustup、Docker、ROS 2、GitHub 加速、apt 主源 |
| `docker` | Docker CE 官方源 + buildx/compose，免 sudo（可选），日志轮转 |
| `node` | fnm 管理 Node LTS + pnpm（用户级，无需 sudo） |
| `python` | uv 用户级安装 + `python3-venv` |
| `rust` | rustup 装到 `~/.cargo`（不碰系统 rust），clippy/rustfmt/rust-src、嵌入式 target |
| `embedded` | `arm-none-eabi-gcc`、openocd、probe-rs、ST-Link/J-Link/CMSIS-DAP/串口 udev 免 root |
| `ros2` | `ros-<distro>-desktop` + colcon/rosdep（体积大，默认不选） |
| `zsh` | zsh + oh-my-zsh + autosuggestions/syntax-highlighting/completions，可设为默认 shell |
| `gitconfig` | git 全局 `user.name`/`user.email` 与常用选项 |
| `extra` | jq/rg/fd/tmux/htop/clangd/valgrind/minicom/can-utils 等 |

## 换源策略

| 生态 | 写入位置 |
|---|---|
| npm / pnpm | `~/.npmrc`（并调用 `npm/pnpm config set`） |
| PyPI / uv / pip | `~/.config/uv/uv.toml`、`~/.config/pip/pip.conf`、`UV_DEFAULT_INDEX` |
| cargo | `~/.cargo/config.toml`（sparse index source replacement） |
| rustup | `RUSTUP_DIST_SERVER` / `RUSTUP_UPDATE_ROOT` |
| Docker | `/etc/docker/daemon.json` 的 `registry-mirrors`（按延迟取最快的 3 个，与日志轮转配置**合并**而非覆盖） |
| ROS 2 | apt 源替换，`apt update` 失败会**自动回滚** |
| GitHub | 加速前缀，用于 oh-my-zsh 与插件 clone |
| apt 主源 | 仅 Ubuntu，需显式确认，同样自动回滚 |

模式：`auto`（默认，官方+国内一起测速）/ `cn`（只测国内）/ `official`（恢复官方）/ `skip`。

## 用法

```bash
./setup-dev.sh                              # 交互式
./setup-dev.sh --all --mirror auto          # 全量 + 自动换源
./setup-dev.sh --only mirror                # 只测速换源
./setup-dev.sh --only node,python,rust      # 只装部分工具链
./setup-dev.sh --only zsh --zsh-theme powerlevel10k
./setup-dev.sh --apt-mirror                 # 附加：把 apt 主源切到最快国内镜像
./setup-dev.sh --dry-run --all              # 预演
./setup-dev.sh --list                       # 列出模块
```

主要选项：`--all` `--only LIST` `--ros DISTRO` `--mirror MODE` `--apt-mirror URL`
`--zsh-theme NAME` `--zsh-overwrite-rc` `--no-chsh` `--no-docker-group` `--dry-run` `--no-tui` `-y` `-l` `-h`

环境变量：`SETUP_DEV_NO_PROFILE=1` 时**绝不修改** `~/.bashrc`、`~/.zshrc`、`uv.toml`、`pip.conf`、cargo 配置，只打印需要手动添加的行（适合用 chezmoi/stow 等 dotfiles 工具管理配置的人）。

## 安全设计

- shell 集成只维护**一个带标记的块**，内容由状态文件 `~/.config/setup-dev-shell/profile-lines` 生成，因此换源改值会**原地更新**而不是不断追加；块外你自己的配置不会被覆盖（同名环境变量在块外已手动设置时会跳过并提示，`PATH` 类追加语义变量例外）。
- 改动前留存 `.bak.setupdev` 备份；`--dry-run` 与 `SETUP_DEV_NO_PROFILE=1` 都不会写入。
- Docker `registry-mirrors` 属于第三方通道，存在投毒风险，仅建议开发机使用（脚本会告警）。

## 平台支持与已知限制

- 已验证环境：Ubuntu 24.04（apt 路径）。
- **Fedora/RHEL 的 dnf 路径按官方文档编写，尚未在 Fedora 机器上实测**，首次使用请留意包名差异（如 `arm-none-eabi-gcc-cs`、EPEL/CRB 细节）。
- ROS 2 的 rpm 仓库没有公共镜像，故 **rpm 侧不支持换源**，只有 apt 侧可以。
- Docker 镜像按**延迟**排序而非实测拉取吞吐；公共镜像列表会变动，失效项会被自动排除。想重新挑一次：`./setup-dev.sh --only mirror`。
- apt 主源切换只支持 Ubuntu（Debian 的 security 仓库路径不同，刻意跳过）。
- 需要 bash 4.4+（Ubuntu 20.04+/Debian 10+/Fedora 均满足）。

## 授权

按需自用；第三方镜像源与 Docker registry-mirrors 的合规性由使用者自行确认。
