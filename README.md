# VPS IPv6 /64 AnyIP 自动配置脚本

这是一个用于 Debian/Ubuntu VPS 的自动化网络配置工具。
它可以自动识别 IPv6 /64 网段，开启 AnyIP (路由欺骗) 和 NDP 代理，让你能够使用网段内的海量 IP。

## 功能特点
- 🚀 **自动识别**：精准提取 IPv6 /64 前缀
- 🛡️ **AnyIP 技术**：将整个 /64 网段路由到本地，无需手动绑定 IP
- 📡 **NDP 代理**：自动安装并配置 ndppd，解决链路层断流问题
- 💾 **持久化**：配置写入 Systemd 服务，重启依然有效

## 使用方法 (Root 用户)

直接在终端执行以下命令即可：

```bash
bash <(curl -sL https://raw.githubusercontent.com/NX2406/vps-tools/main/ipv6_magic.sh)
