# 个人 Xray 管理脚本

一个面向自用服务器的 Bash 菜单脚本。支持同时部署 VLESS + Reality（TCP 443）、Hysteria2（UDP 443）和 Shadowsocks 2022（自选端口），并管理 Xray、Nginx、acme.sh、OpenList。

## 使用前

- 使用自己的域名，DNS A/AAAA 记录指向服务器；Reality 和 HY2 共用该域名。若域名托管于 Cloudflare，应使用“仅 DNS”记录，不能开启代理模式。
- 放行 TCP 443、UDP 443，以及 SS 所选端口的 TCP/UDP；选择 HTTP 证书验证时还需放行 TCP 80。
- 以 root 身份运行；支持 Debian/Ubuntu、RHEL/Fedora/CentOS 8+、Alpine，服务管理支持 systemd 和 OpenRC。实际可用架构取决于上游当期是否发布对应的 Xray/OpenList 二进制，以及发行版是否提供 Nginx、qrencode 等依赖。脚本会在下载前检查。
- Cloudflare DNS 验证需要具有该域名 DNS 编辑权限的 API Token。Token 只在交互时读取，acme.sh 会保存续期所需凭据，请保护 `/root/.acme.sh`。

```bash
sudo bash xray-manager.sh
```

仓库发布后也可以在服务器上直接获取：

```bash
curl -fsSL https://raw.githubusercontent.com/xhtus/seeword/main/xray-manager.sh -o xray-manager.sh
sudo bash xray-manager.sh
```

安装时脚本会复制自身到 `/usr/local/bin/xray-manager`，之后可直接运行 `sudo xray-manager`。也可使用 `reality`、`hy2`、`ss`、`update`、`info`、`status`、`uninstall`、`uninstall-reality`、`uninstall-hy2`、`uninstall-ss`、`reload` 子命令。

## 菜单

1. 一键安装 Reality：输入自己的域名/SNI，选择 HTTP 80 或 Cloudflare DNS 申请 Let's Encrypt 证书。Xray 占用 TCP 443，未通过 Reality 认证的 HTTPS 请求回落到本机 Nginx，再反代 OpenList。
2. 一键安装 HY2：同一域名及证书，Xray 占用 UDP 443。若未安装 Reality，Nginx 直接监听 TCP 443。
3. 一键安装 SS：自选端口，自动生成 16 字节随机密钥，使用 `2022-blake3-aes-128-gcm`。
4. 更新 Xray：从 XTLS 官方最新正式版更新内核及归档自带的 `geoip.dat`、`geosite.dat`。
5. 查看当前配置及服务状态：显示分享链接、二维码和 OpenList 登录信息。
6. 一键卸载：删除本脚本安装的 Xray/OpenList 服务、数据、Nginx 站点和证书；不会卸载系统已有的 Nginx 包。
7. 只卸载 Reality：保留 HY2 和 SS。若 HY2 仍在，Nginx 接管 TCP 443，域名继续显示 OpenList。
8. 只卸载 HY2：保留 Reality 和 SS。
9. 只卸载 SS：保留 Reality 和 HY2。

独立卸载最后一个使用域名的协议时，脚本也会移除该域名专属的 Nginx 站点、证书和 OpenList 数据；SS 如已安装会继续运行。独立卸载最后一个协议后保留管理脚本与 Xray 内核，方便再次安装；选项 6 才会卸载整个管理环境。

## 文件

| 内容 | 路径 |
| --- | --- |
| Xray 配置 | `/etc/xray/config.json` |
| 管理状态和凭据 | `/etc/xray-manager/state.json`（仅 root 可读） |
| 证书 | `/etc/nginx/zs/<域名首段>/` |
| Nginx 站点 | `/etc/nginx/conf.d/xray-manager.conf` |
| OpenList | `/opt/openlist/` |
| Xray 地理数据 | `/usr/local/share/xray/` |

例如 `a.bd.de` 的证书放在 `/etc/nginx/zs/a/`。若另一个域名的首段也为 `a`，脚本会拒绝覆盖已有证书。

## 说明

- 证书由 acme.sh 自动续期，成功续期后重载 Nginx 和 Xray。HTTP 验证使用 Nginx 的 ACME webroot，续期时无需停服务；DNS 验证由 Cloudflare API 自动更新 TXT 记录。
- OpenList 的管理员用户名为 `admin`，密码在首次安装时随机生成并保存。请按需修改 OpenList 配置和存储内容，避免公开敏感文件。
- 同一服务器已有监听 TCP 443、UDP 443、OpenList 5244、Nginx 8443 的服务时，安装会拒绝占用端口。
- 分享链接是否被具体客户端支持取决于客户端版本；HY2 请使用支持 Hysteria2 的客户端。
- 未在真实 VPS 上执行证书申请或网络连通性测试。建议先在一台新服务器试运行。

## 上游文档

- [Xray 安装与平台支持](https://xtls.github.io/en/document/install)
- [Xray Reality](https://xtls.github.io/en/config/transports/reality.html)
- [Xray Hysteria](https://xtls.github.io/en/config/inbounds/hysteria.html)
- [Xray Shadowsocks](https://xtls.github.io/en/config/inbounds/shadowsocks.html)
- [acme.sh](https://github.com/acmesh-official/acme.sh)
- [OpenList 手动安装](https://pages.doc.oplist.org/guide/installation/manual)
