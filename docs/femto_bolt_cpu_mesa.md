# Femto Bolt：Docker USB 节点、CPU Mesa 与维护

适用环境：`ros1` 容器，Ubuntu 20.04 x86_64、ROS Noetic。CPU Mesa 的硬件验证使用旧包中的 Orbbec SDK 2.7.6；迁移到当前新版 `orbbec_camera` 后需要重新进行硬件验证。
CPU 组合固定为 Mesa 25.2.8 / LLVM 15.0.7 / libdrm 2.4.125。
以下命令除“宿主机”标注外均在容器内执行；挂载命名空间操作需要当前容器已有的 privileged 权限，并以 root 启动相机。

## 1. 区分 USB 访问和深度计算两个问题

链路为：

```text
宿主机 USB 设备 → 容器 /dev/bus/usb 节点 → libusb / Orbbec SDK
    → 原始 ToF 数据 → 深度引擎（EGL/OpenGL，由 llvmpipe 在 CPU 执行）
    → 深度图 → 点云 → ROS topic / 可选显示
```

`lsusb` 有设备并不代表容器内存在相应的字符设备文件。
`privileged` 放开访问限制，但不保证热插拔后宿主机的新设备节点自动进入容器的 `/dev`。
宿主机 udev rules 管的是宿主机的节点与权限，不会自动同步另一挂载命名空间。

设备可以打开后，`eglInitialize 0x3001`、`Depth engine ... retCode204` 属于另一个阶段。
这里的深度引擎生成深度数据；即使没有 RViz 或 RGB 窗口也需要它。
只关闭显示不能跳过这一步。

## 2. 给现有容器补 USB 节点，不重建容器

**本节所有命令均在宿主机执行。假设容器名为 `ros1`。**

这一操作只需要查出设备路径、主设备号和次设备号，再拼成一条 `mknod` 命令。

### 2.1 查相机对应的设备路径

```bash
lsusb -d 2bc5:066b
```

假设输出为：

```text
Bus 004 Device 003: ID 2bc5:066b Orbbec Orbbec Femto Bolt 3D Camera
```

由 `Bus 004` 和 `Device 003` 可得本次路径：

```text
/dev/bus/usb/004/003
```

如果列出了多个相机，先确定目标设备。`2bc5:066b` 是厂商号和产品号，用于查找相机，不是后面 `mknod` 要填的主次设备号。

### 2.2 查主设备号和次设备号

```bash
ls -l /dev/bus/usb/004/003
```

假设输出为：

```text
crw-rw-r-- 1 root root 189, 386 Nov 7 09:22 /dev/bus/usb/004/003
```

从这一行直接读取参数，数字已经是十进制，不需要转换：

| 参数 | 示例值 | 从哪里得到 |
| --- | --- | --- |
| 容器名 | `ros1` | 自己的容器名称 |
| 节点路径 | `/dev/bus/usb/004/003` | 上一步的 USB 总线号和设备号 |
| 设备类型 | `c` | `ls -l` 输出的第一个字符，表示字符设备 |
| 主设备号 | `189` | `ls -l` 中逗号前的数字 |
| 次设备号 | `386` | `ls -l` 中逗号后的数字 |

主设备号 `189` 与总线号 `004` 不是一回事；次设备号 `386` 也不是设备号 `003`。应按 `ls -l` 的实际输出填写。

### 2.3 把这些参数填入添加命令

先检查容器中是否缺少这个节点：

```bash
docker exec -u 0 ros1 ls -l /dev/bus/usb/004/003
```

如果提示 `No such file or directory`，先创建父目录，再添加节点：

```bash
docker exec -u 0 ros1 mkdir -p /dev/bus/usb/004
docker exec -u 0 ros1 mknod -m 660 /dev/bus/usb/004/003 c 189 386
```

第二条命令可按下面的结构理解：

```text
docker exec -u 0 容器名 mknod -m 660 节点路径 设备类型 主设备号 次设备号
```

`mknod` 创建设备访问入口，`-m 660` 设置文件权限。本指南让相机进程以 root 运行；以普通用户运行时还需要配置相应用户组。

不要把示例的 `004/003` 和 `189 386` 固定照抄到自己的机器。将第 2.1、2.2 步查出的实际值填进去即可。命令含义见 [mknod 手册](https://man7.org/linux/man-pages/man1/mknod.1.html)。

如果节点已经存在，先比较宿主机和容器中的 `ls -l` 输出。主次设备号正确时不用重复添加；不正确时，确认该路径是容器独立的过期节点后再处理。若整个 USB 目录已经绑定到宿主机，删除节点可能同时影响宿主机，不要直接执行 `rm`。

### 2.4 验证能否访问

```bash
docker exec -u 0 ros1 ls -l /dev/bus/usb/004/003
docker exec -u 0 ros1 python3 -c \
  'import os; fd=os.open("/dev/bus/usb/004/003", os.O_RDWR); os.close(fd); print("USB node open OK")'
```

预期看到 `USB node open OK`。这说明节点可读写打开；相机能否成功采集，还要继续验证 SDK 和深度引擎。若 SDK 报占用，检查其他 Viewer、Python 程序和 ROS 相机节点。

### 2.5 为什么 lsusb 有设备，还需要补节点

`lsusb` 能枚举设备，不代表对应的 `/dev/bus/usb/...` 文件在容器中存在。宿主机 udev rules 管理宿主机的设备文件，不会自动把节点同步到容器的独立 `/dev`。

`mknod` 不安装驱动，也不绕过 Docker 的设备访问限制。如果创建节点或打开节点报 `Operation not permitted`，继续检查容器权限。

### 2.6 重新插拔与长期配置

相机重新插拔后，再做一次 `lsusb` 和 `ls -l`，根据新结果补节点。容器重启后也应复查。旧路径和次设备号可能失效或被其他 USB 设备复用。

今后创建容器时，可把整个 USB 总线目录绑定进去，让热插拔产生的节点随宿主机出现：

```yaml
# 合并到自己的 Compose service。
privileged: true
volumes:
  - /dev/bus/usb:/dev/bus/usb
```

已有 privileged 容器可以先按本节添加节点继续工作。修改 Compose 挂载配置通常需要后续重新创建容器才会生效。

## 3. 使用普通 roslaunch 参数选择 CPU Mesa

正常 source ROS 工作空间，然后执行：

```bash
source /opt/ros/noetic/setup.bash
source /path/to/engineer3_ws/devel/setup.bash
roslaunch orbbec_camera femto_bolt.launch use_cpu_mesa:=true \
  depth_width:=512 depth_height:=512 depth_fps:=30 \
  ir_width:=512 ir_height:=512 ir_fps:=30
```

- `use_cpu_mesa:=false` 是默认值，节点按原方式启动。
- `use_cpu_mesa:=true` 让这个相机节点通过包内 `scripts/with_cpu_mesa.sh` 启动。
- `cpu_mesa_prefix:=/opt/orbbec-mesa-cpu/25.2.8` 选择独立库目录。
- `ORBBEC_MESA_PREFIX` 环境变量可设置该参数的默认值。

这是 **launch 启动参数**。EGL 库和驱动必须在 SDK 加载前选择，不能用运行中的 `rosparam set` 切换。
在自己的父 launch 中 include 此文件时，显式传入这两个 arg 即可。

内部实现只影响相机节点：设置独立 `LD_LIBRARY_PATH` / EGL vendor JSON，启用 llvmpipe，
再通过 `unshare --mount --propagation private` 给它一个看不到 `/dev/dri` 的挂载命名空间。
这样 SDK 枚举到软件 EGL 设备。只设置 `LIBGL_ALWAYS_SOFTWARE=1` 时，本次 SDK 仍会选择物理显卡，因此不够。
外部容器进程仍能访问 GPU，USB 目录保持可见。

普通非 ROS 程序也可复用这个加载器：

```bash
ORBBEC_MESA_PREFIX=/opt/orbbec-mesa-cpu/25.2.8 \
  "$(rospack find orbbec_camera)/scripts/with_cpu_mesa.sh" \
  python3 your_program.py
```

这不会自动给任意第三方程序新增 `--cpu-mesa` 参数。若要它原生接受该参数，需在导入 SDK 前解析参数并重新启动进程；
本次已经实现的是 ROS launch 的启动参数。

## 4. 构建过程与已淘汰的方案

1. 原系统 Mesa 21.2.6 无法初始化当前 Intel 显卡的 EGL。
2. 旧软件 Mesa 可以生成深度，但多线程停流时崩溃；单线程仅约 0.7 fps，因此淘汰。
3. 单独构建 CPU-only Mesa 25.2.8，不覆盖系统 Mesa。
4. LLVM 12 虽然通过构建配置，但实际深度计算出现 LLVM `Broken function`，因此淘汰。
5. 最终使用 LLVM 15.0.7、libdrm 2.4.125、Meson 1.7.2。Python 3.8 的 `removeprefix` 兼容修改只用于生成构建文件。

成功构建的关键配置：

```text
prefix=/opt/orbbec-mesa-cpu/25.2.8, libdir=lib, buildtype=release
gallium-drivers=llvmpipe, vulkan-drivers=[], platforms=[]
egl=enabled, egl-native-platform=surfaceless, glvnd=enabled, glx=disabled
llvm=enabled, shared-llvm=enabled, llvm-orcjit=false
gbm=enabled, gles1=disabled, gles2=enabled
gallium-va=disabled, gallium-vdpau=disabled, video-codecs=[]
```

完整配置、固定源码 SHA256 和 Python 兼容修改在 `scripts/build_cpu_mesa.sh` 中。
该脚本用 `mktemp` 建临时目录，并在成功或失败退出时自动删除；仅显式设置 `ORBBEC_KEEP_BUILD=1` 才保留。
它拒绝覆盖已经安装好的同名版本。

## 5. 日常维护、验证和重建

### 运行需要保留什么

| 内容 | 用途 |
| --- | --- |
| `/opt/orbbec-mesa-cpu/25.2.8`，约 22 MB | CPU Mesa 及 EGL 配置 |
| `libllvm15` 包，约 111 MB | llvmpipe 运行时动态链接 |
| ROS 包内的 launch、`scripts/with_cpu_mesa.sh` | 参数选择和加载器 |
| 系统已有的 GLVND/EGL、C++ 等依赖 | 动态链接基础依赖 |

源码目录、Ninja 产物、LLVM 开发包、旧 LLVM 工具、下载的 deb/tar 文件都不参与日常运行。
清理时不执行全局 `apt autoremove`，避免影响容器原有软件。
`libllvm15` 已标记为手动安装，以免被误判为无用依赖。

版本与库校验清单保存在 `/opt/orbbec-cpu-egl/runtime-packages.txt` 和 `runtime-sha256.txt`，
原文件备份和成功日志也在该目录。清理后应以本文和包内脚本为准，旧 `/tmp` 路径不再作为维护入口。

### 验证相机

先确保设备可访问且未被其他相机进程占用，再在已 source ROS 环境的容器 shell 中执行：

```bash
timeout --signal=INT --kill-after=15s 120s \
  python3 "$(rospack find orbbec_camera)/scripts/check_cpu_mesa.py"
```

使用独立的本机 ROS master 端口 11411；被占用时拒绝运行。
检查 512×512 有效深度帧、两轮取消订阅/重新订阅和退出。验证日志默认 `/tmp/orbbec-cpu-mesa-validation.log`，可用 `--log` 改路径。
测试结束不留下相机进程；这是短时功能验证，不是长期稳定性保证。

### 固定版本并升级

日常无需重新编译。容器 restart 会保留 `/opt`；删除容器则会丢失未写入镜像或持久卷的文件。
部署时应把运行库和 `libllvm15` 固化到镜像，ROS 包也需包含本次 launch 与加载器。
迁移机器时需保持架构、glibc 等基础 ABI 兼容，不能任意复制宿主机的新显卡驱动库到旧容器。

升级用新目录，不覆盖旧目录；通过 `cpu_mesa_prefix` 测试新版本，检查正常采集、停流、重新订阅后再切换默认值。
回退只需把这个参数改回旧目录。更改源码版本时必须同步审查源码 SHA256、构建选项及兼容修改。

### 重新构建固定版本

清理后的容器只保留运行库，重建前需要重新安装开发依赖。以下仍以 Ubuntu 20.04 x86_64 为例。
首先按 LLVM 官方说明安装 `llvm-15-dev`。当前保留了官方签名 key 和 focal-15 源定义：

```bash
apt-get -o Dir::Etc::sourcelist=/opt/orbbec-cpu-egl/llvm15.list \
  -o Dir::Etc::sourceparts=- update
apt-get -o Dir::Etc::sourcelist=/opt/orbbec-cpu-egl/llvm15.list \
  -o Dir::Etc::sourceparts=- install -y --no-install-recommends llvm-15-dev
```

新容器没有这些记录文件时，先从 `https://apt.llvm.org/` 获取签名 key、按官方方式配置
`https://apt.llvm.org/focal/ llvm-toolchain-focal-15 main`；不要直接运行与 Ubuntu 版本不匹配的安装命令。
本次保留的 `.list` 使用的 key 已移到 `/opt/orbbec-cpu-egl/llvm-snapshot.gpg`。

然后选一个未使用的绝对路径构建：

```bash
bash "$(rospack find orbbec_camera)/scripts/build_cpu_mesa.sh" \
  /opt/orbbec-mesa-cpu/25.2.8-rebuild
python3 "$(rospack find orbbec_camera)/scripts/check_cpu_mesa.py" \
  --prefix /opt/orbbec-mesa-cpu/25.2.8-rebuild
```

构建脚本会下载并校验固定源码，安装构建工具；`ORBBEC_SOURCE_CACHE=/path` 可复用已有的两个源码 tar。
下载慢时给容器配置可达的代理，或在宿主机下载并复制源码；不要把只监听宿主机 loopback 的代理地址直接用于桥接容器。
`ORBBEC_BUILD_JOBS` 可控制并行编译数，默认 8。
验证通过后再按精确包清单清理开发依赖，保留 `libllvm15`；不要删除整个 `/tmp`。

参考：[Mesa 独立安装](https://docs.mesa3d.org/install.html)、
[llvmpipe CPU 实现](https://docs.mesa3d.org/drivers/llvmpipe.html)、
[LLVM 官方包](https://apt.llvm.org/)。

## 6. 旧包的验证记录（2026-11-07，Orbbec SDK 2.7.6）

- 已通过 `use_cpu_mesa:=true` 与自定义 `cpu_mesa_prefix` 实际采集验证。
- 已用新的构建脚本从空目录重建同一版本，并验证自动删除临时构建目录。
- 删除了旧构建目录、失败的硬件 Mesa 前缀、临时验证版本、下载包及 26 个新增开发依赖。
- 容器删除的文件逻辑大小约 684 MiB，卸载包标注大小约 750 MiB，合计约 1.40 GiB；宿主机临时下载另删除约 204 MiB。
- 清理后保留的正式版本在 512×512 配置下两轮各取得 40 帧有效深度图，按帧时间戳计算均为 30.00 fps；停流、重新订阅、退出正常。
- `/tmp` 中与本次工作无关的编辑器缓存等文件未删除；未执行 Docker 全局 prune 或全局 apt autoremove。
- 精确删除清单保存在 `/opt/orbbec-cpu-egl/cleanup-report.json`。

如需迁移前备份，在宿主机把运行前缀和维护记录复制到持久目录：

```bash
mkdir -p ./femto-cpu-mesa-backup
docker cp ros1:/opt/orbbec-mesa-cpu/25.2.8 ./femto-cpu-mesa-backup/
docker cp ros1:/opt/orbbec-cpu-egl ./femto-cpu-mesa-backup/
```

ROS 包中的脚本与 launch 已保存在宿主机挂载的工作空间。恢复到同平台的新容器时，还需按运行依赖记录安装 `libllvm15` 和基础 EGL/GLVND 库；备份前缀本身不包含 LLVM 运行库。
