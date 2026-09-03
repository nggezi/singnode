# sing-box OpenWrt 一键安装脚本

在 OpenWrt / ImmortalWrt / iStoreOS 等泛 OpenWrt 系列系统上，一键把 sing-box 装到路由器本体，创建一个 `shadowsocks 2022-blake3-aes-256-gcm` 服务端节点，放行 WAN 入站端口，并输出标准 `ss://` 链接。

## 用法

上传 `singbox.sh` 到路由器后执行：

```sh
sh singbox.sh            # 安装
sh singbox.sh uninstall  # 卸载
```

脚本需要 root（OpenWrt 默认就是 root），依赖 `uci`、`tar`、`base64`，均为基础组件。若系统没有 curl，脚本会自动尝试 `opkg/apk install curl`，都没有则给出提示。

## 流程

1. 探测机器架构（`uname -m` → sing-box 官方资产名，支持 amd64/386/arm64/armv5-7/mips/mipsle/mips64/loong64/ppc64le 等，OpenWrt 常见的 mipsel 软浮点路由器会自动选 `mipsle-softfloat`）。
2. 探测机器所在网络（优先 IP 地理库判断国内/国外；失败时按 GitHub 可达性兜底）。
3. 解析 sing-box 最新稳定版号，从 GitHub 或镜像站（国内默认走镜像，多个镜像自动回退）下载对应架构压缩包；架构识别失败可用 `SINGBOX_ARCH` 覆盖。
4. 首次安装生成随机端口（10000–65000）和 32 字节随机 Key，持久化到 `/etc/sing-box/node.state`；之后安装/更新均复用，链接不因重装改变。
5. 写 `/etc/sing-box/config.json`（监听 `::`，shadowsocks 2022-blake3-aes-256-gcm），注册 procd 服务并开机自启。
6. 通过 uci 添加防火墙通信规则（源 WAN、tcp+udp、目标端口，fw4/fw3 兼容），重启防火墙。路由器公网 IP 在本身时即为"放行入站"，无需端口映射。
7. 探测公网 IPv4，打印标准 `ss://` 链接与客户端信息。

## 可选参数

```sh
# 服务器有域名时用域名生成链接
SINGBOX_DOMAIN=ss.example.com sh singbox.sh

# 架构自动识别失败时手动指定（值参考官方资产名）
SINGBOX_ARCH=armv7 sh singbox.sh

# 手动指定 GitHub 加速镜像（默认内置 ghfast.top / gh-proxy.com / ghproxy.net / gh.llkk.cc / mirror.ghproxy.com）
GH_MIRROR=https://gh-proxy.com sh singbox.sh

# 固定安装指定版本（默认自动取 GitHub 最新稳定版）
SINGBOX_VERSION=1.13.14 sh singbox.sh
```

## 卸载行为

卸载会停止并移除服务、删除二进制与配置、删除防火墙通信规则。**端口和 Key 凭据文件 `/etc/sing-box/node.state` 会保留**，所以再次安装会得到完全相同的节点与链接；确认不再使用时手动删除即可：

```sh
rm -f /etc/sing-box/node.state
```

## 维护

```sh
/etc/init.d/sing-box restart   # 重启服务
/etc/init.d/sing-box status    # 查看状态
logread | grep sing-box        # 查看日志
```

配置文件在 `/etc/sing-box/config.json`，可直接编辑后执行 `/etc/init.d/sing-box restart`。

## 说明与限制

- 脚本面向"路由器本体在公网（有公网 IPv4，无需端口映射）"的用法；若在运营商 CGNAT 之后，外网无法直连，需要内网穿透/端口映射，脚本会给出提示。
- 默认监听 `::`（IPv4/IPv6 双栈），链接按 IPv4 生成。想走 IPv6 或域名时设 `SINGBOX_DOMAIN`。
- 2022-blake3 系列要求客户端使用原版 sing-box 系客户端或支持 shadowsocks 2022 的客户端（如 NekoBox / sing-box 内核），旧式 SS 客户端不兼容。
- mips/mipsel 路由器默认选软浮点资产；若你的设备确实带 FPU 且运行报非法指令，可用 `SINGBOX_ARCH=mipsle` 等强制重装。
