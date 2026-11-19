# HTTPS 网关验证记录

验证范围：当前工作区源码；尚未发布镜像，也未在用户 NAS 上验收。

## 自动检查

- `zig build test`、`zig build`：通过。覆盖新增网关审计报告、非法枚举拒绝及网络配置条件更新冲突。
- `go test ./...`：通过。
- `（pkg/gateway）go test -race ./...；（server）go test -race ./internal/handler`：通过。
- Web `npm run build`（执行与 pnpm 相同的 tsc/Vite 脚本）、`npm run test:i18n`、`node --test scripts/gateway.test.mjs`：通过。
- Compose 配置检查及 OpenAPI YAML 解析：通过。
- `sh conformance/admin_entrypoint.sh zigfs-admin-gateway-qa`：通过。验证配置卷权限修复、已有文件保留、私有文件权限和 UID/GID 10001 降权。

Go 测试验证：未知 Host / SNI 拒绝、管理命名空间隔离、签名原始路径与查询参数保留、CORS 来源透传、Range、请求取消、证书 SAN/有效期校验、续签保持 CA、导入证书、端口冲突恢复、修订号冲突、应用响应丢失后的重启恢复、并发网络变更保护、管理权限与 CSRF、HTTPS 会话 Secure Cookie。

## 浏览器与真实服务联调

使用独立的临时数据目录和端口 19000 / 19001 / 19443，不修改已有 Compose 服务。Chrome 自动化脚本在 `web/scripts/gateway.browser.mjs`。

通过流程：登录 → 网络设置 → 生成本地 CA 与候选入口 → 服务端 TLS / 上游检测 → 未信任 CA 的浏览器验证失败且应用按钮禁用 → 客户端验证成功 → 确认应用 → Public URL 更新 → 停用并恢复原地址。

使用包含中文、空格、加号、百分号和重复斜杠的对象名，通过真实 ZigFS 预签名 URL 完成 PUT / GET / HEAD / DELETE，浏览器跨域预检通过。已检查明暗主题截图，无页面脚本异常。

测试没有修改系统 DNS 或根证书存储。Chrome 使用临时域名映射；未信任证书测试保留默认 TLS 校验。成功交互分支使用单独的 `ignoreHTTPSErrors` 测试上下文，**这不能代替实际设备安装 CA 的验收**。证书链验证由 Go HTTPS 客户端和服务端检测使用真实 CA 校验覆盖。

## 尚需部署验收

- 用户 NAS 的域名解析、端口可达、CA 安装及大文件实际网络吞吐。
- 新版本完整镜像发布及 AMD64/ARM64 发布流水线。已交叉编译 Linux ARM64 Admin 并构建独立运行时验证镜像，但没有发布到镜像仓库。
- 导入证书使用者的实际信任链、长时间续签运行和跨设备信任迁移。

## 独立包与页面补齐（2026-11-19）

- 网关迁移到 `pkg/gateway`，无 Admin/Gin 依赖；独立 module 的
  `GOWORK=off go test -race ./...` 通过。
- Admin workspace 模式 `go test ./...` 通过；Linux ARM64 交叉编译通过。
- DNS TCP/UDP 测试改用隔离随机端口，避免占用实际本机服务的 15353。
- 新增 8 MiB 分块上传、首块到达后再发送剩余数据的握手测试，验证不整文件缓冲；
  下载在上游完成前可读、响应 trailer 和上游断连 XML/CORS 响应测试通过。
- 页面增加保存/验证/启用步骤、当前与候选入口区别、证书临期提示。
  修复配置加载完成前编辑被旧配置覆盖的问题；草稿修改时禁止启用旧候选配置。
- Chrome 自动化通过：准备、服务端检测、未信任失败、禁用启用按钮、验证后启用、
  草稿修改使启用禁用、签名 PUT/GET/HEAD/DELETE、停用恢复和明暗主题截图。
  沿用上述测试证书信任边界，不将测试上下文绕过证书错误视为设备信任验收。
- Web npm build、i18n 及 gateway 测试通过。pnpm 仍因本机缺失原生执行文件失败，
  npm 调用的是相同 tsc/Vite 构建脚本。
- Admin `GOWORK=off go test ./...`（vendor 路径）及 Linux AMD64 编译通过。
- 将独立网关测试程序交叉编译为 Linux ARM64，在无外部网络的 Ubuntu 24.04
  容器中执行通过；macOS 安装助手测试在 Linux 按平台跳过。
- 根目录 Docker 构建上下文已成功加载，完整镜像构建在下载 Go/Node 基础层时
  进度缓慢，约 6 分钟后停止；本轮未完成完整镜像构建，未发布任何镜像。

## 完整协议与故障恢复验收（2026-11-19，后续补齐）

新增 `conformance/gateway_https.py`，原生进程与 Linux Admin 容器模式均通过。
客户端连接回环地址并保留 TLS SNI 与 Host：未知 CA 必须失败，加载实例公共 CA
后必须成功，无 `verify=false` 或跳过 TLS 校验。覆盖两个 HTTPS 域名、默认及
桶自定义 CORS、中文/空格/+/%/编码斜杠/重复斜杠路径、零字节对象、Range、HEAD、
条件请求、复制、XML 错误、分片上传完成、指定版本删除、导入证书链、错误 SAN
拒绝、候选回滚、进程/容器重建保持 CA，以及停用恢复原 Public URL。

Linux 模式使用当前源码交叉编译的 ARM64 Admin 和已有基础运行时构建的隔离镜像
`zigfs-admin:gateway-runtime-check`，数据平面为宿主机隔离 ZigFS 进程。
这验证了 Linux 网关实际运行及持久卷行为，不等同于完整多阶段发布镜像构建。
配置卷权限、私有文件保留及 UID/GID 10001 降权测试通过。

新增 Go 故障测试通过：上游地址已写入但最终落盘失败后的重启协调（不重复写入）、
候选保存失败保留旧状态与路由、证书自动续签时活动下载不中断、实际 SAN 信息隔离。
`pkg/gateway` race 测试、Admin 全量测试、Web 构建/i18n/gateway 测试通过。

另在当前 Mac 已安装的系统 DNS/CA 配置下，真实 Chrome 使用正常 TLS 校验，
只读访问 Admin 与 S3 两个 `:443` 探测入口均为 200，协议 TLS 1.3，签发者
ZigFS Local CA；未更改 hosts 或钥匙串。测试浏览器禁用外部代理以直接访问本机。

完整多阶段构建曾再次尝试 Docker Hub，并尝试 mirror.gcr.io 公共缓存；基础层
下载持续缓慢，完整发布镜像仍未验收或发布。新增 Linux CI 全协议检查尚待远程运行。
长期网络吞吐和跨设备信任迁移保留为运维验收项，不能用短时测试替代。

本轮浏览器新增断言通过：实际证书 SAN、站点指纹和续签说明可见；明暗主题截图
保存在本地忽略目录 `.script/gateway-qa/gateway-certificate-*.png`。
完整源码镜像的 Docker Hub 构建下载与公开缓存下载最终停止，避免继续占用带宽；
已完成的 Linux runtime 验收镜像仍保留本地。用户原有本机服务未停止或替换。

## Windows 配置助手

- `.ps1` 下载沿用每次请求的 ZigFS 管理员权限检查；拒绝未授权下载测试通过。
- 公共 CA 导出、域名注入拒绝、CA/域名匹配、UTF-8/UTF-16 hosts 状态测试通过。
- Admin 全量 Go 回归、Web npm build/i18n 通过；Windows AMD64 Admin 与网关测试
  程序交叉编译通过。pnpm 原生执行文件问题仍存在，未影响等价 npm 构建。
- 浏览器通过拦截平台状态验证 Windows 标题、下载入口、两条 PowerShell 命令，
  不显示误导性的“本地 DNS 未运行”；实际鉴权下载确认无私钥和未替换模板内容。
- Windows CI 已加入原生语法解析及安装/卸载/重复安装/冲突拒绝回归，测试使用
  临时 hosts 文件与测试用户证书库，并清理测试 CA。macOS 本机不执行这些 Windows
  专用测试；真实 UAC、Windows 系统 hosts ACL 和系统根证书库仍需 Windows 验收。
