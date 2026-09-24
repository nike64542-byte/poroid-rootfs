# 7 发行版扩展设计

- 日期：2026-09-24
- 状态：待评审（brainstorming 四节已逐节口头批准）
- 涉及仓库：nike64542-byte/poroid-rootfs（主）、nike64542-byte/poroid-apk（同步）

## 1. 背景与目标

poroid-rootfs 现有 Kali（OpenRC）、Debian（OpenRC）、Ubuntu（systemd）三个
arm64 guest 镜像，APK 向导已可三选一（`f69c8c5`）。本轮新增 7 个发行版，
两仓同步扩展，使 Release 共 10 个 `*-rootfs.squashfs` 资产、APK 向导可选
10 项。成功标准：每个镜像 CI 构建绿、资产上线、镜像内容探针通过；端到端
启动由用户在设备上以 Fedora/Gentoo 两代表先行实测到 `Ready!` 标记。

## 2. 范围决策（用户已确认）

| 问题 | 决策 |
|---|---|
| Linux Mint / EndeavourOS 无 arm64 | **跳过**，只做 7 个（Gentoo/Fedora/Rocky/Alma/openSUSE/Arch/Manjaro） |
| 是否同步改 APK | **rootfs + APK 同步扩展**到 10 项 |
| 落地节奏 | **7 个同时做**（不分批），验证阶段用两代表冒烟 |

In-scope：构建管线、分发/CI、Release 资产、APK 选择链路、README。
Out-of-scope：CI 内自动启动台架（与现有 3 镜像保持对等，不做）、
Mint/EndeavourOS 的 amd64+TCG 方案（明确拒绝）。

## 3. 构建层设计（build-rootfs/）

### 3.1 结构

每个新发行版一个 `Dockerfile.rootfs-<name>`，三阶段与现有三份一致：
stage-1 跨编译 aarch64 静态 agent（照抄，接受重复，不抽共享）；
stage-2 `--platform=linux/arm64` 装包与配置；stage-3 `scratch` 导出 squashfs。

| 发行版 | 基础源（stage-2） | 机制 | init / 共享层 | 构建脚本 | 包管理器 |
|---|---|---|---|---|---|
| Fedora 42 | `fedora:42` | 容器内装包→rsync 导出（ubuntu 同款） | systemd / `files-systemd/` | `build-rootfs-dnf.sh` | dnf |
| Rocky 9 | `rockylinux:9` | 同上 | systemd | 同上（`DISTRO=rocky`） | dnf |
| Alma 9 | `almalinux:9` | 同上 | systemd | 同上（`DISTRO=alma`） | dnf |
| openSUSE Leap 15.6 | `opensuse/leap:15.6` | 同上 | systemd | `build-rootfs-zypper.sh` | zypper |
| Arch Linux | Arch Linux ARM 官方 rootfs tarball，解包到 `/work/rootfs` + chroot 装包（binfmt/qemu 兜底） | tarball+chroot | systemd | `build-rootfs-pacman.sh` | pacman |
| Manjaro | ALARM 底 + `pacman.conf` 切 Manjaro ARM 仓库 | 同上（`DISTRO=manjaro`） | systemd | 同上 | pacman |
| Gentoo | `gentoo/stage3`（无 arm64 则 stage3 tarball 指针抓取降级） | 容器内 `emerge --getbinpkg` | OpenRC / 复用 `files/` | `build-rootfs-gentoo.sh` | portage(binpkg) |

说明：官方 arch 仓库无 aarch64，必须 Arch Linux ARM（ALARM）；Manjaro 身份
= ALARM 底 + Manjaro ARM 仓库（写入 README）；四个 build 脚本族内以
`DISTRO` 参数化，脚本流程遵循现有约定：装包 → hostname/用户/ssh 配置 →
拷共享 overlay → rsync 到 `/work/rootfs`（排除项与 build-rootfs-ubuntu.sh 一致）。

### 3.2 关键决策

1. 共享层重命名 `files-ubuntu-systemd/` → `files-systemd/`（7 个发行版共用；
   `Dockerfile.rootfs-ubuntu`、`build-rootfs-ubuntu.sh` 引用同步改，内容不动）。
2. 包集合对齐现有 minimal 集（podman、sudo、dhcp 客户端、iproute 等）；ssh：
   systemd 系用 openssh-server（对齐 ubuntu），Gentoo（OpenRC）用 dropbear
   （对齐 `files/`）。实现时逐一对照 `files*/podroid-network.sh` 实际调用的
   二进制做包名映射（dnf/zypper/pacman/emerge 各族）。
3. Gentoo 强制 binpkg：`EMERGE_DEFAULT_OPTS="--getbinpkg -y"`，脚本第一行
   fail-fast 校验 binhost 覆盖关键包，缺包立即失败——禁止 QEMU 下源码编译。
4. 产出资产名：`{fedora,rocky,alma,opensuse,arch,manjaro,gentoo}-rootfs.squashfs`。

## 4. 分发与 CI 层设计

### 4.1 build.sh

- `build_distro_rootfs()` 分发表增 7 项；目标名与资产名一一对应。
- `rootfs`（默认全部）与 usage 字符串更新为 10 发行版。

### 4.2 .github/workflows/build.yml

1. `inputs.distro` choice 增加 7 项。选项全表：initramfs / kali / debian /
   ubuntu / fedora / rocky / alma / opensuse / arch / manjaro / gentoo / all。
2. 并行矩阵：新增 `resolve` job，把输入解析为 JSON 数组（单选→单项数组，
   all→10 发行版全表），`build` job 用
   `strategy.matrix.distro: ${{ fromJSON(needs.resolve.outputs.list) }}`。
   initramfs 独立 job 与矩阵并行。动机：all 从串行约 2.5h 变并行约 15min，
   单发行版失败不拖垮整批。产物/artifact 命名已 per-distro，天然隔离；
   并行 release 上传各写各的资产名，无 clobber 冲突。
3. 修复 upload 缺陷（本次事故根因）：
   - 资产匹配 glob `out/*-rootfs.squashfs` 改为 `out/*rootfs*.squashfs`
     （旧 glob 匹配不到版本化副本 `ubuntu-rootfs-24.04.squashfs`）；
   - 去掉 `|| true`，上传失败让 job 变红可见；
   - 版本化文件名生成步骤的 distro 表补 7 项。

### 4.3 README

- 10 发行版支持矩阵（架构/init/包管理器/资产名）。
- 明确 Linux Mint、EndeavourOS 不支持及原因（官方无 arm64）。
- 构建用法 `./build.sh <distro>`；Manjaro 混合身份、Gentoo binpkg 两条附注。

## 5. APK 层设计（poroid-apk）

1. `SystemImageRepository.Distro` 增 7 枚举项，asset 按 §3.2 命名表。
   `presetUrl` / `rootfsUrl()` / `rootfsFile()` / `distro()` / `setDistro()`
   零改动（数据驱动；`KEY_DISTRO` 存枚举名，旧值天然兼容，无迁移）。
2. `SetupScreen` 三 chip 排布改 `FlowRow`（自动换行，需
   `@OptIn(ExperimentalLayoutApi::class)`），chip 样式逐字保留
   （`PodroidTokens.Radius.Chip` / `PodroidChipColors()` / Bold），标签走
   `distroLabelRes()`。`SetupViewModel` 零改动。
3. strings 新增 7 项（en/zh）：`distro_fedora` "Fedora Linux"、`distro_rocky`
   "Rocky Linux"、`distro_alma` "AlmaLinux"、`distro_opensuse`
   "openSUSE Leap"、`distro_arch` "Arch Linux"、`distro_manjaro` "Manjaro"、
   `distro_gentoo` "Gentoo Linux"；`DistroUi.distroLabelRes()` 补 7 分支。
4. `SettingsScreen` / `QemuEngine` / `SettingsViewModel` / 重置语义零改动：
   单 VM 单 rootfs 文件不变式自动保持。
5. `DistroTest` 扩展：7 新枚举 asset 断言；10 项 `presetUrl(d) ==
   ROOTFS_BASE_URL + asset` 参数化；`ROOTFS_URL_DEFAULT == presetUrl(KALI)`
   与旧值回退用例保留。

## 6. 测试与验证

| 层 | 手段 | 通过标准 |
|---|---|---|
| 脚本静态 | 4 个 build 脚本与 build.sh `bash -n`；workflow 先 dispatch fedora 单发行版 | 语法 0 错；矩阵展开为 `["fedora"]` |
| CI 构建 | fedora 绿后矩阵跑其余 6 个 | 7 job 全绿，`out/<name>-rootfs.squashfs` + 版本化副本均产出 |
| Release 资产 | API 拉资产表核对存在性/size/版本化副本 | upload 修复生效，7 新资产 + 版本化副本齐全 |
| 镜像内容探针 | PySquashfsImage 离线断言：`/sbin/init`、podroid 服务文件（systemd unit 或 OpenRC+runlevels）、podman、`/etc/passwd` 用户、无构建垃圾 | 7/7 通过 |
| APK | DistroTest 扩展 + push CI（unit + assemble） | CI 绿 |
| 端到端 | 不新增 CI 启动台架；用户设备实测 | 先 Fedora + Gentoo 两代表到 `Ready!`，再铺开其余 5 个 |

## 7. 落地顺序

1. 共享层重命名及引用更新（ubuntu 现状保持可构建）。
2. 4 个 build 脚本 + 7 个 Dockerfile（Gentoo fail-fast 置脚本首行）。
3. build.sh 分发表 + README。
4. workflow：resolve 矩阵 + upload 修复 + 版本化表。
5. APK：enum / 标签 / FlowRow / 测试。
6. rootfs push → fedora 冒烟 → 其余 6 → 资产核对。
7. APK push → CI 绿 → 交付用户两代表实测。

交付物：两仓各 1 个 commit（rootfs：7 Dockerfile、4 脚本、目录重命名、
build.sh、build.yml、README；APK：SystemImageRepository、DistroUi、
SetupScreen、strings×2、DistroTest）；Release 新增 7 资产及版本化副本。

## 8. 风险与缓解

| 风险 | 缓解 |
|---|---|
| Gentoo arm64 binpkg 覆盖不足 | 脚本首行 fail-fast；真缺包则备选为缺包 stage3 定制 tarball 推 Release |
| `gentoo/stage3` 无 arm64 镜像 | 设计已预留 stage3 tarball 指针抓取降级路径 |
| Manjaro 混合身份（ALARM+Manjaro 仓库） | 可接受，README 说明 |
| 动态矩阵 fromJSON 结构性改动 | fedora 单发行版先行冒烟验证矩阵展开 |
| 10 镜像 × QEMU 构建资源竞争 | 矩阵并行可接受变慢；job 互不阻塞 |
| 端到端启动未在 CI 覆盖 | 与现状对等；两代表设备实测先行 |

## 9. 回滚

每仓单 commit，`git revert` 即回滚；矩阵下单发行版失败不影响其余 job；
已上传资产可用 Release API 单独删除。
