# Nitro Sandbox Demo

基于 Firecracker **v1.18.0** 的 Nitro Sandbox 功能（v1.18.0 由
[#6393](https://github.com/firecracker-microvm/firecracker/pull/6393) 引入，文档见
[docs/nitro-sandboxes](https://github.com/firecracker-microvm/firecracker/blob/firecracker-v1.18/docs/nitro-sandboxes/README.md)）。

Nitro Sandbox 不走 KVM：Firecracker 改为驱动 Nitro Enclaves 驱动 `/dev/nitro_enclaves`，
由 Nitro Hypervisor 从父实例里切出一台隔离虚机，而 API、jailer、virtio 设备模型保持原样，
新增一个 `PUT /enclave` 配置端点。代码和报错里一律把 sandbox 叫 "enclave"，
和 AWS Nitro Enclaves 产品不是一回事。

逐个脚本的代码解读（关键实现、为什么这么写、踩过的坑）见 **[SCRIPTS.md](SCRIPTS.md)**。

---

## 这个 repo 演示什么

| | Demo A（Direct 模式） | Demo B（Confidential 模式） |
|---|---|---|
| 场景 | 批量拉起沙箱跑不可信代码 | 跑需要保密的工作负载 |
| 父实例能否读沙箱内存 | **能**（读写） | **不能** |
| attestation | 无 | 有（NSM / PCR） |
| guest 是否需要 DMB virtio 驱动 | 不需要 | 需要 |
| entropy 设备 | 允许 | 被 Nitro 拒绝 |
| 启动镜像 | 普通内核 + ext4 rootfs | 预先构建的 EIF |

---

## 验证状态

全部在 **c7g.2xlarge（aarch64, 8 vCPU, 15 GiB）+ AL2023 + kernel 6.18.56-126.188.amzn2023** 上实测。

| 内容 | 状态 |
|---|---|
| `00_build_guest.sh` 构建 guest 内核 + rootfs | ✅ 通过 |
| Demo A 全流程（`N=3`，隔离检查 + 启动耗时） | ✅ 3/3 成功，P50 2.10s |
| Demo A 的 IMDS 拦截有判别力（`LEAK_IMDS=1` 对照） | ✅ 已验证 |
| Confidential 模式启动 + DMB 协商 | ✅ 已验证 |
| Confidential 内存隔离（`demo_b_memtest.sh`，含 Direct 对照组） | ✅ 已验证 |
| Confidential 模式拒绝 entropy 设备 | ✅ `NE_ERR_DEVICE_DISALLOWED` |
| Direct 模式拒绝 `dmb_size_mib` | ✅ 已验证 |
| guest 里拿到 `/dev/nsm` | ✅ 已验证（需用 AL2023 内核 + initramfs） |
| Demo B 的 vsock 通路 + KMS 代理链路 | ✅ 已验证（TLS 打通到真实 KMS 端点） |
| Demo B 完整 KMS attestation 解密（`setup`/`run`/`negative`） | ❌ 卡在 EIF 工具链，见[下文](#demo-b-为什么没完全打通) |

---

## 环境要求

- **实例**：Nitro 架构、支持 Nitro Enclaves、**≥ 4 vCPU**，启动时必须带
  `--enclave-options Enabled=true`（**创建后无法再改**，忘了只能重建实例）。
- **OS**：Amazon Linux 2023。
- **内核**：≥ `6.18.51-120.162.amzn2023`，即 AL2023 的 `kernel6.18` 包。
  AMI 默认是 6.1，**必须手动装 kernel6.18 并重启**。
- **架构**：aarch64 和 x86_64 都支持，脚本会自动选对内核镜像格式
  （x86_64 必须用 EFI-stub 的 `bzImage`，aarch64 用 `vmlinux-`）。
- **磁盘**：建议 40 GiB。内核 + rootfs 主镜像约 350 MB，每个沙箱另有一份 rootfs 副本。
- **IAM**：Demo A 不需要。Demo B 需要实例角色有
  `kms:CreateKey` / `Encrypt` / `Decrypt` / `PutKeyPolicy` / `ScheduleKeyDeletion`。

---

## Step-by-step：从零启动一台实例跑完

下面的命令按顺序执行即可。`<...>` 的地方替换成你自己的值。

### Step 1 — 启动实例

```bash
REGION=us-east-2

# AL2023 arm64 最新 AMI（x86_64 把 arm64 换成 x86_64，机型换成 c6i/c7i 系列）
AMI=$(aws ssm get-parameter --region $REGION \
  --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64 \
  --query Parameter.Value --output text)
echo "AMI=$AMI"

aws ec2 run-instances --region $REGION \
  --image-id "$AMI" \
  --instance-type c7g.2xlarge \
  --enclave-options Enabled=true \
  --key-name <你的 keypair> \
  --subnet-id <subnet-xxxx> \
  --security-group-ids <sg-xxxx> \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":40,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=nitro-sandbox-demo}]'
  # Demo B 还要加：--iam-instance-profile Name=<带 KMS 权限的 instance profile>
```

> `--enclave-options Enabled=true` 是关键，漏了后面 `/dev/nitro_enclaves` 不会出现，
> 而且无法对已有实例补加。

### Step 2 — 装 kernel6.18 并重启

```bash
ssh -i <你的key.pem> ec2-user@<实例IP>

sudo dnf install -y kernel6.18
sudo reboot
```

重启后回来确认（这两项都必须对，否则不要往下走）：

```bash
uname -r                      # 期望 6.18.x-...amzn2023，不是 6.1.x
ls -l /dev/nitro_enclaves     # 期望存在，crw-rw----
```

### Step 3 — 放置脚本

```bash
# 方式一：从本地拷
scp -i <你的key.pem> -r nitro_sandbox_demo ec2-user@<实例IP>:~/

# 方式二：实例上 git clone
# git clone <你的repo地址> ~/nitro_sandbox_demo

cd ~/nitro_sandbox_demo
```

### Step 4 — 宿主机准备 stage1，然后重启

`MEMPOOL` 是**从父实例划走**给沙箱用的内存，要按机型调整：至少给父实例留 2 GiB，
脚本会检查，太大会直接拒绝并给出建议值。15 GiB 的 c7g.2xlarge 用 10G 合适。

`SLOTS` 是并发沙箱上限（一个沙箱占一个 PCIe slot），**必须是 8 的倍数**。

```bash
sudo MEMPOOL=10G SLOTS=32 bash nitro_sandbox_parent_setup.sh stage1
sudo reboot
```

### Step 5 — 宿主机准备 stage2（装 Firecracker）

```bash
cd ~/nitro_sandbox_demo
sudo bash nitro_sandbox_parent_setup.sh stage2
```

确认：

```bash
firecracker --version                                        # 期望 v1.18.0
cat /proc/cmdline | tr ' ' '\n' | grep nitro_enclaves        # 期望 nitro_enclaves.mempool=10G
echo $(( $(sudo cat /sys/class/misc/nitro_enclaves/mem_pool/free) / 1048576 )) MiB   # 期望接近 10240
```

### Step 6 — 装 Demo A 需要的 nftables

```bash
sudo dnf install -y nftables
```

（`squashfs-tools` 和 `e2fsprogs` 由 `00_build_guest.sh` 自己装，不用管。）

### Step 7 — 构建 guest 内核和 rootfs

```bash
sudo bash 00_build_guest.sh
```

期望输出结尾：

```
== 校验产物 ==
rootfs.ext4: ext4 文件系统正常
rootfs.ext4: /opt/runner.py 已注入
完成：/opt/sb/kernel.img (6.18.56)  /opt/sb/rootfs.ext4
```

> 改动 `guest/` 下任何文件后都**必须重跑这一步**，否则沙箱里跑的还是旧代码。

### Step 8 — 跑 Demo A

```bash
sudo N=3 bash demo_a_direct.sh
```

期望输出：

```
sb-00 ready=2.10s rc=0 host_creds_visible: False peer_disk_visible: False
      nic: eth0 172.16.0.2/30 gw_reachable: True egress_ok: True
      imds_reachable: False (timeout) hostname: ubuntu-fc-uvm
...
== 启动到可用：P50=2.10s  max=2.15s  成功 3/3
== IMDS drop 规则命中计数 ==
  ip saddr 172.16.0.0/16 ip daddr 169.254.0.0/16 counter packets 9 bytes 540 drop
```

怎么读这个结果：

- `host_creds_visible` / `peer_disk_visible` 为 `False` — 看不到宿主机凭证、看不到邻居沙箱的盘。
- `gw_reachable` / `egress_ok` 为 `True` — **沙箱确实有真实网络**。这一条很重要：
  如果沙箱压根没网，`imds_reachable: False` 就什么都证明不了。
- `imds_reachable` 为 `False`，且 nft drop 规则有命中计数 — 说明是**被拦住**，不是没网。

想确认这项检查真的有判别力，去掉拦截规则再跑一次，应该变成 `True`：

```bash
sudo N=2 LEAK_IMDS=1 bash demo_a_direct.sh
```

> 实测 `LEAK_IMDS=1` 时沙箱能**完整取到父实例 IAM 角色的临时凭证**
> （IMDSv2 token 200 OK → 角色名 → 1574 字节凭证文档，含 `SecretAccessKey`）。
> IMDS 的 hop limit 挡不住，因为宿主机 NAT 转发后 PUT token 照样成功。
> **所以那条 drop 规则是必需项，不是可选项。**

`N` 的上限受两处限制：`SLOTS`（PCIe slot 预算）和 `/run` 的大小 ——
沙箱的 rootfs 副本放在 `/run`（tmpfs，通常是内存的一半），每份实占约 285 MB
并随 guest 写入增长，所以这台机器上 `N` 别超过 10 左右。

### Step 9 — 跑 Demo B 的内存隔离验证

这一步不需要 EIF、不需要 KMS，现在就能跑：

```bash
sudo bash demo_b_memtest.sh 512
```

期望输出：

```
=== [A] Confidential 模式（无 direct_mode）===
  -> holder_running: True
  -> 没找到 >=64MiB 的可读映射
  => canary 命中 0 处；父实例读不到 guest 内存

=== [B] Direct 模式（对照组）===
  -> 映射 0xffff70200000-0xffff90200000 rw-s 512 MiB /dev/nitro_enclaves
     读成功 512 MiB / 读失败 0 MiB
  => canary 命中 8195 处；父实例读到了 guest 内存
```

做法是在 guest 里起一个常驻进程把 canary 字符串持有在内存里，然后父实例解析
`/proc/<fc_pid>/maps` 并直接 `pread` `/proc/<fc_pid>/mem` 去搜。
Confidential 模式下 guest RAM **根本没被映射进父进程**；Direct 模式作为对照组能
完整读出来 —— 对照组读得到，才说明这个测法有判别力。

### Step 10 — 清理

```bash
sudo bash demo_a_direct.sh cleanup     # tap 设备 / nft 表 / ip_forward / /run/sb
```

确认宿主机恢复原状：

```bash
ip -br link show | grep -c sbtap                              # 0
sudo nft list tables                                          # 空
cat /proc/sys/net/ipv4/ip_forward                             # 0
sudo cat /sys/class/misc/nitro_enclaves/pcie_slots_in_use     # 0
```

---

## 可选：让 guest 里出现 `/dev/nsm`

做 attestation 相关实验才需要。Firecracker CI 的内核没开 `CONFIG_NSM`，
但宿主机的 AL2023 `kernel6.18` 有 `CONFIG_NSM=m`，而且官方文档明确说这个内核
可以直接当 guest 内核用（DMB 补丁也带）。它的 `virtio_pci` / `nsm` 都是模块，
所以要配一个 initramfs：

```bash
sudo dracut --no-hostonly --force \
  --add-drivers "virtio_pci virtio_blk virtio_net vmw_vsock_virtio_transport vsock nsm" \
  /opt/sb/sb-initrd.img "$(uname -r)"
```

然后在 vm.json 里：

```json
"boot-source": {
  "kernel_image_path": "/boot/vmlinuz-<内核版本>",
  "initrd_path": "/opt/sb/sb-initrd.img",
  "boot_args": "panic=1 initcall_blacklist=i8042_init console=ttyS0 rd.driver.pre=virtio_pci,virtio_blk,vmw_vsock_virtio_transport,nsm"
}
```

实测 guest 里 `/dev/nsm` 是字符设备 `10:260`，`/proc/misc` 里能看到 `260 nsm`。

> 注意 `virtio_console` 在这个内核里**不是模块**，写进 `--add-drivers` 会让 dracut
> 整个失败；更坑的是失败后仍会留下一个不完整的 initramfs 文件，容易误以为成功。

---

## Demo B 为什么没完全打通

`setup` / `run` / `negative` 需要一个**预先构建好、且带 sandbox 能力标志的 EIF**，
目前没有公开工具能产出。两句官方文档
（[features.md](https://github.com/firecracker-microvm/firecracker/blob/firecracker-v1.18/docs/nitro-sandboxes/features.md)）
把路堵死了：

1. > Firecracker does not report the measurements of an EIF it builds.

   让 Firecracker 自动组装 EIF（给它一个内核路径）这条路拿不到可用的 PCR，
   KMS key policy 里 `kms:RecipientAttestation:ImageSha384` 没有已知值可匹配。
   另外 `debug_mode: true` 会把 PCR 锁成全 0，调试用的跑法本身也无法 attest。

2. > An EIF built for Nitro Enclaves lacks the sandbox capability flags, so it fails at `InstanceStart`.

   也就是 **`nitro-cli build-enclave` 产出的 EIF 用不了**。EIF 头部声明的能力标志必须
   和 Firecracker 从 enclave 配置推出来的完全一致（`cpu_overcommit` / `cpu_accounting` /
   `hotplug_mode` / 多节点 `numa_nodes`）。

次要的：`kmstool_enclave_cli` 不在任何 rpm 包里，要从 aws-nitro-enclaves-sdk-c 源码编译，
再塞进 EIF 的 initrd。

代码按正确设计保留，有了 EIF 构建手段就能直接用。不依赖 attestation 的部分
（内存隔离、entropy 被拒、`/dev/nsm`、vsock 与 KMS 代理链路）都已经验证过了。

---

## 文件清单

| 文件 | 作用 |
|---|---|
| `README.md` | 本文件：环境要求 + 操作步骤 |
| `SCRIPTS.md` | 逐个脚本的代码解读和踩坑记录 |
| `nitro_sandbox_parent_setup.sh` | 宿主机准备（stage1 内存池 / stage2 slot + 装 Firecracker） |
| `00_build_guest.sh` | 下载 CI 内核 + Ubuntu rootfs，注入执行器，打成 ext4 |
| `demo_a_direct.sh` | Demo A 外层：资源预检 + tap/nft 网络 + 清理 |
| `demo_a_pool.py` | Demo A 编排器：并发拉 N 个沙箱、下发代码、汇总、销毁 |
| `evil.py` | 下发进沙箱的被测代码（隔离与网络探测） |
| `demo_b_memtest.sh` | Confidential vs Direct 的内存隔离 A/B 验证 |
| `demo_b_confidential.sh` | Demo B：KMS attestation（受 EIF 工具链限制，暂不可跑） |
| `kms_uds_proxy.py` | 把 guest 发起的 vsock 连接转发到 KMS（替代用不了的 `vsock-proxy`） |
| `guest/runner.py` | 沙箱内 vsock 代码执行器（端口 5000） |
| `guest/secure_runner.py` | Demo B 在沙箱内向 KMS 解密（端口 5001） |
| `guest/sb-runner.service` | 执行器开机自启 |
| `guest/sb-net.service` / `sb-net-setup.sh` | 沙箱内补默认路由 |

---

## 环境变量

**`nitro_sandbox_parent_setup.sh`**

| 变量 | 默认 | 说明 |
|---|---|---|
| `MEMPOOL` | `48G` | 划给沙箱的内存。**小机型必须调小**，脚本会校验 |
| `SLOTS` | `32` | 并发沙箱上限，必须是 8 的倍数 |
| `FC_REL` | `v1.18.0` | Firecracker 版本，Nitro Sandbox 需要 ≥ v1.18.0 |

**`00_build_guest.sh`**

| 变量 | 默认 | 说明 |
|---|---|---|
| `CI_PREFIX` | 自动取最新 | 固定某次 CI 构建，如 `firecracker-ci/20261105-6ea6634994fa-0/` |

**`demo_a_direct.sh`**

| 变量 | 默认 | 说明 |
|---|---|---|
| `N` / `VCPU` / `MEM` | `8` / `1` / `1024` | 沙箱数量与规格 |
| `DEBUG` | `0` | `1` 打开 enclave debug_mode，guest 串口输出进 `/run/sb/<i>/fc.log` |
| `KEEP` | `0` | `1` 跑完保留沙箱和网络（之后用 `cleanup` 子命令清理） |
| `LEAK_IMDS` | `0` | `1` 不下发 IMDS 拦截规则，用来演示只做 NAT 会泄漏凭证 |
| `UPLINK` | 默认路由网卡 | 指定出口网卡 |

---

## 排查

| 现象 | 看哪里 |
|---|---|
| `/dev/nitro_enclaves` 不存在 | 实例没开 `--enclave-options`（无法补加），或内核还是 6.1 |
| 内存池为 0 | `stage1` 后没重启，或 `MEMPOOL` 超过物理内存 |
| 沙箱起不来 | `/run/sb/<i>/fc.log`；加 `DEBUG=1` 看 guest 串口全部输出 |
| `Failed to open the API socket` | 残留的 `api.sock`，Firecracker 不复用，删掉重来 |
| guest 不应答 | 先确认 `fc.log` 里有 `Started sb-runner.service`；再查是不是 EOF 分帧问题 |
| 网络不通 | `sudo nft -a list table ip firecracker` 看各条规则的 counter 命中 |
| slot / 内存不够 | `pcie_slots_in_use`、`mem_pool/free` |
| 进沙箱手工看 | `ssh -i /opt/sb/sb.id_rsa root@172.16.<i>.2` |
| 看 rootfs 镜像内容 | `sudo mount -o ro,loop /opt/sb/rootfs.ext4 /mnt/x` |

留现场调试：`sudo N=1 KEEP=1 DEBUG=1 bash demo_a_direct.sh`，
看完用 `sudo bash demo_a_direct.sh cleanup` 收。

---

## 三个最容易踩的坑

1. **CI 工件前缀不能按 Firecracker 版本号拼。** `spec.ccfc.min` 桶里带版本号的前缀
   （`firecracker-ci/v1.x/`）只发布到 **v1.15** 为止，v1.16 以后改用日期戳前缀
   `firecracker-ci/YYYYMMDD-<hash>-N/`。而且 Confidential 模式要 6.18 线内核
   （带 DMB 补丁），6.1 线没有。
2. **sandbox 走 UEFI 引导。** x86_64 必须用 EFI-stub 的 `bzImage`，KVM microVM 常用的
   `vmlinux` 启不了 sandbox。注意通用的 `docs/getting-started.md` 两个架构都用
   `vmlinux-`，照搬会把 x86_64 弄坏。
3. **Firecracker 的 vsock 不支持半关闭。** 宿主机 `shutdown(SHUT_WR)` 会被转成同时带
   `SHUTDOWN_RCV` + `SHUTDOWN_SEND` 的双向 shutdown，guest 的应答发不回来。
   host ↔ guest 之间要用长度前缀分帧，不要用 EOF 分帧。

更多细节见 [SCRIPTS.md](SCRIPTS.md)。
