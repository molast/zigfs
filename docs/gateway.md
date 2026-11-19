# 内置 HTTPS 网关

本文描述当前源码中的功能，需要重新构建 ZigFS 与 Admin 镜像；已发布的 `v0.1.0-alpha.7` 不包含此功能和网关审计接口。

## 工作方式

独立 Go module `pkg/gateway` 由 Admin 进程嵌入，提供独立 HTTPS 监听器，按域名将后台请求交给现有 BFF，将 S3 请求流式代理到 `ZIGFS_ENDPOINT`。网关默认关闭，设置入口为 **系统设置 → 网络 → HTTPS 网关**，需要 ZigFS `admin:*` 权限。

配置和证书保存在 Admin 的独立目录，默认是 `ZIGFS_ADMIN_CONFIG` 所在目录下的 `gateway/`，可用 `ZIGFS_GATEWAY_CONFIG_DIR` 指定。不读取 ZigFS 数据目录，不改变对象鉴权逻辑。

S3 入口保留 Host、原始转义路径和查询参数，不经过后台登录、不重定向 OPTIONS、不硬编码 CORS 来源。`/_admin` 管理路径不能通过外部 S3 网关访问。第一版使用路径式 S3 寻址，应用时关闭 Virtual Hosted Addressing。

## 首次设置

1. 构建包含此功能的 ZigFS 和 Admin 镜像，并更新 Compose。
2. 为 Admin 映射 HTTPS 端口，例如 `8443:8443`。仓库 Compose 默认发布该端口，但仅在网关启用后监听。原 HTTP `9001` 是配置和恢复入口。
3. 在局域网 DNS 或客户端 hosts 中，将 `admin.zigfs.home.arpa` 与 `s3.zigfs.home.arpa` 指向服务器内网 IP。
4. 从 HTTP 后台进入网关设置，填写内部监听 `:8443`、两个域名、外部端口 `8443`。
5. 选择本地 CA 自动签发，或粘贴覆盖两个域名的 PEM 证书链和匹配的未加密私钥。
6. 点击“保存并准备 HTTPS”。候选入口立即启动，此时 S3 Public URL 尚未改变。
7. 本地 CA 模式下载 CA 公共证书，通过可信渠道核对指纹，并在实际使用的设备上安装信任。
8. 点击“检测服务端与上游”，再点击“从当前浏览器验证”。后者验证两个入口及候选配置 ID，不发送后台 Cookie，不跟随重定向。
9. 验证通过后点击“启用配置”。示例切换为 `https://s3.zigfs.home.arpa:8443`。
10. 打开 `https://admin.zigfs.home.arpa:8443`，重新登录并测试上传、下载、删除。后台 Cookie 不跨域共享。

服务端检查成功不代表客户端 DNS 或信任正确。导入私有 CA 证书时，服务端自身的系统信任也可能影响服务端检查；应提供完整链并正确配置信任。浏览器验证失败不会自动推断具体原因，需要检查 DNS、信任、端口映射及代理重定向。

## 证书信任与生命周期

- macOS：将 CA 导入系统钥匙串，并对 SSL 设置为信任。
- Windows：导入受信任的根证书颁发机构。
- iOS：安装证书描述文件后，还需在证书信任设置中启用完全信任。
- Android、Firefox、Java 和 CLI 工具可能使用独立证书存储，请按对应客户端配置 CA。
- 不使用忽略证书错误或关闭 TLS 校验作为正式配置。

CA 默认有效期 5 年，站点证书 90 天。服务启动及每小时检查本地站点证书，剩余不足 30 天时续签，CA 不变。导入证书不自动续签，到期前需重新导入。同域名更换导入证书或切换 CA 信任时，先在不同监听端口准备候选配置，避免准备阶段替换当前连接所用证书。页面显示到期日期；不会自动替换本地 CA 或静默降级为 HTTP。

私钥仅保存在权限为 `0600` 的状态文件中，目录权限为 `0700`。状态接口不返回密钥；CA 下载只含公共证书。备份 `/app/config` 时必须保护其中的私钥。丢失该目录会丢失 CA 信任连续性。

## Docker 与 1Panel

当前 Compose 增加：

```yaml
services:
  admin:
    ports:
      - "9001:9001"
      - "${ZIGFS_GATEWAY_PORT:-8443}:8443"
    volumes:
      - zigfs-admin-config:/app/config
    environment:
      ZIGFS_GATEWAY_CONFIG_DIR: /app/config/gateway
volumes:
  zigfs-admin-config:
```

如宿主机 443 空闲，可设 `ZIGFS_GATEWAY_PORT=443`，页面外部端口填 `443`，内部监听仍为 `:8443`。NAS / 1Panel 已占用 443 时使用其他端口。

Admin 新启动入口准备配置目录权限后，以 `10001:10001` 运行。显式指定容器 `user:` 时由部署者保证目录可写。新增配置卷前，应备份原容器 `/app/config` 中需要保留的监听配置；新空卷不会自动复制旧容器的可写层。

网关不能替用户配置 DNS、Docker 端口映射、防火墙或公网入口。它不使用 NAS 自动生成的带登录跳转的应用链接。

## 应用失败与恢复

准备、应用和撤销使用配置修订号，过期页面提交会被拒绝。修改 Public URL 前，网关落盘记录“修改前 / 修改后”的网络状态。响应丢失或重启后可重试，只有实际状态仍匹配预期才会继续，不覆盖其他管理员的修改。

- 准备失败：旧监听器和当前 Public URL 保持可用。
- 应用待完成：点击重试或回滚；先查看状态，避免手动覆盖其它网络设置。
- 端口占用、证书损坏、过期：使用 HTTP 9001 恢复入口修复。
- 停用：必须指定不依赖该网关的后续 S3 Public URL，先更新地址再停止网关。
- 修改域名或停用后，已有预签名链接不会重写，应重新获取。

网关只信任直连来源，清除客户端伪造的转发头。若需 IAM 的 HTTPS / 客户端 IP 条件，在 ZigFS Trusted Proxies 配置实际网关来源。第一版不解析网关前方多层代理的可信链，不会自动信任整个容器网段。

## 审计与验证

变更前向 ZigFS 提交受 `admin:*` 保护的操作请求报告，提交失败则不执行本地变更；操作结束后报告 succeeded / failed。报告是 Admin 声明的部署操作结果，不代表 ZigFS 自身执行代理配置；结果报告失败会在 Admin 日志中明确记录，先前请求报告仍可追踪。Public URL 变更另外使用原有网络配置审计。

CA 生成和证书导入归入 Prepare 操作。报告不包含证书正文或密钥。完整 API 见 [网关接口](api/gateway.openapi.yaml)。

验证入口：Go 网关与 Handler 测试、Web `scripts/gateway.test.mjs`、i18n 检查、生产构建及 Zig 单元 / 契约测试。真实 NAS、客户端 CA 信任安装和 DNS 设置应在目标部署环境中另外验收。

## macOS 本机 Local DNS

直接运行 Admin 时，macOS 上自动启动 `127.0.0.1:15353` 的 UDP/TCP DNS。
仅回答当前生效或候选网关中、位于 `zigfs.home.arpa` 下的两个域名，A 记录为
配置中的“域名解析目标 IP”（旧配置默认 `127.0.0.1`），TTL 为 5 秒；AAAA 返回空结果，不转发其他域名。监听冲突会显示在
网关设置的本机状态中，不影响原有 HTTP 入口。Admin 退出时 DNS 同步退出。

1. 配置域名 `admin.zigfs.home.arpa`、`s3.zigfs.home.arpa`，本机监听与外部端口均用
   `443`，选择本地 CA，点击准备入口。
2. 在“本机访问配置”下载 `zigfs-local-setup.sh`，在运行 Admin 的 Mac 上执行：
   `bash ~/Downloads/zigfs-local-setup.sh install`。
3. 助手通过 sudo 请求授权，将专用解析器写入 `/etc/resolver/zigfs.home.arpa`，
   并把此实例的公共 CA 安装到系统钥匙串。不会修改 hosts 或全局 DNS。
   已存在且不属于此助手的解析器配置不会被覆盖。
4. 重启浏览器，刷新本机状态，然后执行浏览器验证及应用。系统解析器已配置
   不等于浏览器证书已受信任；使用独立 DNS/信任库的客户端需单独检查。
5. 卸载：使用同一份助手运行 `bash ~/Downloads/zigfs-local-setup.sh uninstall`，
   删除对应 CA 证书及本助手创建的解析器。CA 删除失败时保留解析器并返回错误。

助手下载需要已登录的管理员权限，仅包含公共 CA，不含私钥。请保留对应助手用于
卸载；更换 CA 前先卸载旧配置。HTTPS 监听需覆盖回环 IPv4（例如 `:443`）；
域名设置为其他后缀、导入证书模式以及非 macOS 系统不支持此 macOS 助手。Windows 使用下述专用助手。
本功能不是 mDNS 广播或局域网服务发现，仅为当前 Mac 提供分域 DNS。

## Windows 本机配置助手

Windows 直接运行 Admin 时，网关页显示“本机访问配置（Windows）”。Windows
使用受管理的 hosts 记录，不启动 macOS 的 `127.0.0.1:15353` DNS 服务。

1. 使用 `admin.zigfs.home.arpa` 与 `s3.zigfs.home.arpa`，选择本地 CA，保存并准备 HTTPS。
2. 下载 `zigfs-local-setup.ps1`，在运行 Admin 的同一台 Windows 电脑上打开 PowerShell：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File "$env:USERPROFILE\Downloads\zigfs-local-setup.ps1" -Action install
   ```

3. 审阅脚本并接受 UAC 提权。助手将两个域名映射到配置的“域名解析目标 IP”（默认 `127.0.0.1`），导入当前 CA 到
   `LocalMachine\Root`，并刷新 DNS 缓存。`Bypass` 仅作用于本次 PowerShell 进程，
   不修改机器的全局脚本执行策略。
4. 重启浏览器，在页面刷新配置状态，然后执行浏览器验证和启用。hosts 已配置不代表
   所有客户端都信任证书；独立证书库的客户端仍需自行配置信任。
5. 卸载时用同一助手执行 `-Action uninstall`。仅删除 ZigFS 标记区块与此 CA 的证书。
   不修改其他 hosts 记录；已有同名域名冲突、其他 CA 管理的区块或损坏的区块会拒绝操作。

助手在 hosts 同目录保留 `hosts.zigfs.backup`，写入采用临时文件替换并保留原有 ACL。
只包含公共 CA，不包含私钥。安装/卸载需要本机管理员权限，服务本身不执行提权。
如下载目录不同，调整命令中的文件路径。此助手用于 Windows 本机部署，不能在另一台
访问电脑上使用 `127.0.0.1` 访问远端服务。Windows 网关状态目录应位于当前用户私有
配置目录或具有等效受限 ACL 的路径；POSIX `0600` 不能代替 Windows ACL。


## 配置域名解析目标 IP

在“系统设置 → 网络 → HTTPS 网关”设置“域名解析目标 IP”：

- 本机回环访问：`127.0.0.1`（默认，兼容旧配置）。
- 局域网访问：填写运行 HTTPS 网关的主机 IPv4，例如 `192.168.1.20`。

该字段不修改 `ZIGFS_ENDPOINT`、监听地址、防火墙或路由器 DNS。当前支持单个
IPv4 单播地址，不支持域名、IPv6、通配监听地址或广播/组播地址。
保存并准备后，内置 DNS 立即使用候选地址（TTL 5 秒）；撤销候选配置恢复生效地址。
浏览器验证成功后才启用候选配置。Mac 助手仍将专用解析器接入本机 DNS 服务，
DNS 回答采用这里的目标 IP；修改 IP 后无须重新安装相同 CA 的 Mac 助手。
Windows 需要重新下载并运行配置助手，以更新 hosts 中的目标 IP。

内置 DNS 仍仅监听回环地址 `127.0.0.1:15353`，不会因目标 IP 改为局域网地址而
自动成为局域网 DNS。其他设备需配置 hosts 或使用局域网 DNS，并信任网关的 CA。
域名应指向实际提供这些证书和候选配置的网关；指向另一个不相关服务器会验证失败。
