# Seeword · 个人 Xray 管理脚本

> 给自用服务器准备的 Bash 菜单脚本：快速部署并统一管理 **VLESS + Reality**、**Hysteria2（HY2）**、**Shadowsocks 2022**，以及 Xray、Nginx、证书与 OpenList。

## 快速开始

```bash
curl -fsSL https://raw.githubusercontent.com/xhtus/seeword/main/install.sh | sudo bash
```

- 需要 root 权限；安装完成后自动进入菜单。
- 主程序位于 `/usr/local/bin/xray-manager`，之后运行 `sudo xray-manager` 即可打开菜单。
- 也支持子命令直达，例如 `sudo xray-manager reality`。

## 安装前准备

| 事项   | 说明                                                                                                  |
| ------ | ----------------------------------------------------------------------------------------------------- |
| 域名   | 自有域名，DNS A/AAAA 指向服务器；Reality 与 HY2 可共用也可分开。Cloudflare 托管请用“仅 DNS”，不要开启代理。 |
| 端口   | Reality TCP（默认 443）、HY2 UDP（默认 443）、SS 自选 TCP/UDP；HTTP 证书验证需要 TCP 80。脚本会自动尝试放行（ufw / firewalld / iptables）。 |
| 系统   | Debian/Ubuntu、RHEL/Fedora/CentOS 8+、Alpine；服务管理支持 systemd 与 OpenRC。                          |
| 依赖   | Nginx、qrencode 等由系统包安装；Xray/OpenList 从官方 release 下载并校验 `.dgst`。可用架构以官方发布为准，下载前会检查。 |
| DNS 验证 | Cloudflare DNS 验证需要具备该域名 DNS 编辑权限的 API Token；Token 只在交互时读取，续期凭据由 acme.sh 保存，请保护好 `/root/.acme.sh`。 |

## 功能一览

- 多协议共存：Reality、HY2、SS2022 可按需组合安装。
- Reality 支持多用户：`adduser` / `deluser` 增删用户。
- 443 端口智能处理：Reality 占用 TCP 443 时，本机 Nginx 的 443 站点自动让位；未通过 Reality 认证的 HTTPS 请求回落到 Nginx，再反代 OpenList。
- 证书按完整域名独立存放，每个域名独立记录验证方式（HTTP/DNS），acme.sh 自动续期。
- 工具箱：一键体检、流量统计、备份/恢复、BBR、重载服务、内核更新。
- 更稳：关键操作带并发锁与日志，菜单步骤失败会安全返回，不会直接退出整个脚本。

### 菜单

| 选项 | 说明                                                                 |
| ---- | -------------------------------------------------------------------- |
| 1. 一键安装 Reality | 输入域名/SNI 与 TCP 端口（默认 443），选择 HTTP-80 或 Cloudflare DNS 申请 Let's Encrypt 证书。 |
| 2. 一键安装 HY2     | 输入域名与 UDP 端口（默认 443）。                                     |
| 3. 一键安装 SS2022  | 自选端口，自动生成 16 字节随机密钥，使用 `2022-blake3-aes-128-gcm`。   |
| 4. 查看配置与状态   | 分享链接、二维码、OpenList 登录信息、服务状态。                       |
| 5. 更多工具         | 更新内核与地理数据、BBR、Reality 用户管理、流量统计、一键体检、备份/恢复、重载服务。 |
| 6. 卸载管理         | 二级菜单：彻底全卸载，或单独卸载 Reality / HY2 / SS2022。              |

### 常用子命令

```bash
sudo xray-manager menu                 # 打开菜单
sudo xray-manager reality              # 一键安装 Reality
sudo xray-manager hy2                  # 一键安装 HY2
sudo xray-manager ss                   # 一键安装 SS2022
sudo xray-manager info                 # 查看配置、分享链接与状态
sudo xray-manager status               # 查看服务状态
sudo xray-manager update               # 更新 Xray 内核与地理数据（已是最新则跳过）
sudo xray-manager doctor               # 一键体检
sudo xray-manager traffic              # 流量统计（Xray 启动后累计，重启后清零）
sudo xray-manager adduser              # Reality 添加用户
sudo xray-manager deluser              # Reality 删除用户
sudo xray-manager backup [输出路径]     # 备份配置
sudo xray-manager restore <备份文件>    # 恢复配置
sudo xray-manager bbr                  # 一键开启 BBR
sudo xray-manager reload               # 重载服务
sudo xray-manager uninstall            # 一键全卸载
sudo xray-manager uninstall-reality    # 只卸载 Reality
sudo xray-manager uninstall-hy2        # 只卸载 HY2
sudo xray-manager uninstall-ss         # 只卸载 SS2022
```

卸载是分级的：单独卸载某协议会保留其他协议；当某域名不再被任何协议使用时清理其证书；没有剩余协议时清理 Web 栈。只有“一键全卸载”是彻底清除：删除 Xray、Nginx（含软件包与配置）、OpenList、acme.sh、全部证书、配置、账号数据与运行日志，服务器上不再保留本脚本的任何痕迹。

## 文件位置

| 内容 | 路径 |
| ---- | ---- |
| Xray 配置 | `/etc/xray/config.json` |
| 管理状态与凭据（仅 root 可读） | `/etc/xray-manager/state.json` |
| 证书（按完整域名存放） | `/etc/nginx/zs/<完整域名>/` |
| Nginx 站点 | `/etc/nginx/conf.d/xray-manager.conf` |
| OpenList 数据 | `/opt/openlist/` |
| Xray 地理数据 | `/usr/local/share/xray/` |
| 运行日志 | `/var/log/xray-manager.log` |

例如 `a.bc.de` 的证书在 `/etc/nginx/zs/a.bc.de/`，该目录下的 `method` 文件记录其验证方式。

## 证书与续期

- 证书由 acme.sh 自动续期，成功后重载 Nginx 与 Xray。
- HTTP 验证使用 Nginx ACME webroot，续期无需停服务；DNS 验证通过 Cloudflare API 自动更新 TXT 记录。

## 注意事项

- OpenList 管理员为 `admin`，密码首次安装时随机生成并保存；请及时修改并妥善保管，避免公开敏感文件。
- 若所选端口、OpenList 5244 或 Nginx 8443 已被占用，安装会拒绝以避免冲突。
- 客户端兼容性取决于客户端版本；HY2 请使用支持 Hysteria2 的客户端。
- “一键全卸载”会卸载 Nginx 软件包并删除 `/root/.acme.sh`（含其管理的全部证书），执行前请确认服务器上没有其他服务依赖它们。
- 证书申请与公网连通性尚未在真实 VPS 验证，建议先在新服务器试运行。

## 上游文档

- [XTLS/Xray-install 中文说明](https://github.com/XTLS/Xray-install/blob/main/README_zh-Hans.md)
- [XTLS/Xray-core 官方仓库](https://github.com/XTLS/Xray-core)
- [XTLS/Xray 官方文档源代码](https://github.com/XTLS/Xray-docs-next)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- [OpenList 官方仓库](https://github.com/OpenListTeam/OpenList)
