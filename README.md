# Seeword · 管理脚本

> 给自用服务器准备的 Bash 菜单脚本：快速部署并统一管理 **VLESS + Reality**、**Hysteria2（HY2）**、**Shadowsocks 2022**，以及 Xray、Nginx、证书与 OpenList。

## 快速开始

常规系统（有 curl）：

```bash
curl -fsSL https://raw.githubusercontent.com/xhtus/seeword/main/install.sh | sudo bash
```

极精简系统（无 curl，用 wget）：

```bash
wget -qO- https://raw.githubusercontent.com/xhtus/seeword/main/install.sh | sudo bash
```

- 需要 root 权限；安装完成后自动进入菜单。
- 主程序位于 `/usr/local/bin/seeword`，之后运行 `sudo seeword` 即可打开菜单。
- 也支持子命令直达，例如 `sudo seeword reality`。
- 装好后若依赖缺失，运行 `sudo seeword fixenv` 修复环境，再运行 `sudo seeword deps` 安装全部依赖。

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
- Reality 支持多用户：`adduser` / `deluser` / `users` 增删查用户。
- 443 端口智能处理：Reality 占用 TCP 443 时，本机 Nginx 的 443 站点自动让位；未通过 Reality 认证的 HTTPS 请求回落到 Nginx，展示默认页面（已安装 OpenList 则反代到 OpenList）。
- OpenList 独立安装：不再随 Reality/HY2 自动安装；如需用它做 SNI 伪装站，在主菜单单独安装，可随时独立卸载。
- 证书按完整域名独立存放，每个域名独立记录验证方式（HTTP/DNS），acme.sh 自动续期。
- 工具箱：一键体检、流量统计、备份/恢复、BBR、重载服务、内核更新。
- 更稳：关键操作带并发锁与日志，菜单步骤失败会安全返回，不会直接退出整个脚本。

### 菜单

| 选项 | 说明                                                                 |
| ---- | -------------------------------------------------------------------- |
| 1. 一键安装 Reality | 输入域名/SNI 与 TCP 端口（默认 443），优先 TCP 80 验证申请 Let's Encrypt 证书；80 被占用时自动改用 Cloudflare DNS API。 |
| 2. 一键安装 HY2     | 输入域名与 UDP 端口（默认 443）。                                     |
| 3. 一键安装 SS2022  | 自选端口，自动生成 16 字节随机密钥，使用 `2022-blake3-aes-128-gcm`。   |
| 4. 安装 OpenList    | SNI 伪装站，可选；安装后 Nginx 自动反代到 OpenList，否则展示 Nginx 默认页面。 |
| 5. 查看配置与状态   | 分享链接、二维码、OpenList 登录信息、服务状态。                       |
| 6. 更多工具         | 更新内核与地理数据、BBR、Reality 用户管理（添加/删除/查看）、流量统计、一键体检、备份/恢复、重载服务。 |
| 7. 卸载管理         | 二级菜单：彻底全卸载，或单独卸载 Reality / HY2 / SS2022 / OpenList。   |

### 常用子命令

```bash
sudo seeword menu                 # 打开菜单
sudo seeword reality              # 一键安装 Reality
sudo seeword hy2                  # 一键安装 HY2
sudo seeword ss                   # 一键安装 SS2022
sudo seeword openlist             # 单独安装 OpenList（SNI 伪装，可选）
sudo seeword info                 # 查看配置、分享链接与状态
sudo seeword status               # 查看服务状态
sudo seeword update               # 更新 Xray 内核与地理数据（已是最新则跳过）
sudo seeword doctor               # 一键体检
sudo seeword traffic              # 流量统计（Xray 启动后累计，重启后清零）
sudo seeword adduser [备注]             # Reality 添加用户；直接给备注则一步完成并显示链接和二维码
sudo seeword deluser [编号或备注]    # Reality 删除用户；直接给编号或备注则一步完成
sudo seeword users                      # 查看 Reality 用户列表
sudo seeword backup [输出路径]     # 备份配置
sudo seeword restore <备份文件>    # 恢复配置
sudo seeword bbr                  # 一键开启 BBR
sudo seeword deps                 # 安装全部依赖（curl/jq/openssl/unzip/tar/qrencode/ss/cron/nginx）
sudo seeword fixenv               # 修复极精简系统环境（软件源/DNS/网络），解决依赖装不上
sudo seeword reload               # 重载服务
sudo seeword uninstall            # 一键全卸载
sudo seeword uninstall-reality    # 只卸载 Reality
sudo seeword uninstall-hy2        # 只卸载 HY2
sudo seeword uninstall-ss         # 只卸载 SS2022
sudo seeword uninstall-openlist   # 只卸载 OpenList
```

卸载是分级的：单独卸载某协议会保留其他协议；当某域名不再被任何协议使用时清理其证书；没有剩余协议时清理 Web 栈。OpenList 是独立组件，不再随协议卸载而移除，可在卸载菜单单独卸载。只有“一键全卸载”是彻底清除：删除 Xray、Nginx（含软件包与配置）、OpenList、acme.sh、全部证书、配置、账号数据与运行日志，服务器上不再保留本脚本的任何痕迹。

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

- 申请证书时优先 TCP 80 的 HTTP 验证；若 80 端口被占用，自动改用 Cloudflare DNS API 验证（需提供 API Token）。验证方式记录在各域名证书目录的 `method` 文件中，续期沿用。
- 证书由 acme.sh 自动续期，成功后重载 Nginx 与 Xray。
- HTTP 验证使用 Nginx ACME webroot，续期无需停服务；DNS 验证通过 Cloudflare API 自动更新 TXT 记录。

## 注意事项

- OpenList 管理员为 `admin`，密码首次安装时随机生成并保存；请及时修改并妥善保管，避免公开敏感文件。OpenList 需在主菜单单独安装，不再随 Reality/HY2 自动安装。
- 若所选端口或 Nginx 8443 已被占用，安装会拒绝以避免冲突；单独安装 OpenList 时若 5244 被占用同样会拒绝。
- 客户端兼容性取决于客户端版本；HY2 请使用支持 Hysteria2 的客户端。
- “一键全卸载”会卸载 Nginx 软件包并删除 `/root/.acme.sh`（含其管理的全部证书），执行前请确认服务器上没有其他服务依赖它们。
- `fixenv` 会在 apt 源缺失时写入 Debian/Ubuntu 官方源（自动备份原文件）、在 DNS 失效时写入公共 DNS，属于系统级修改，执行前请确认。
- 证书申请与公网连通性尚未在真实 VPS 验证，建议先在新服务器试运行。

## 上游文档

- [XTLS/Xray-install 中文说明](https://github.com/XTLS/Xray-install/blob/main/README_zh-Hans.md)
- [XTLS/Xray-core 官方仓库](https://github.com/XTLS/Xray-core)
- [XTLS/Xray 官方文档源代码](https://github.com/XTLS/Xray-docs-next)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- [OpenList 官方仓库](https://github.com/OpenListTeam/OpenList)
