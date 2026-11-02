# OIDC 登录与 S3 临时凭证

## 配置

部署管理员在 Identity → OIDC Settings 创建 Provider。普通 User/Group 不绑定 Role；Provider 的 Role Policy 是现有 Policy 名称列表。ZigFS 加密保存 Provider、待完成登录与会话，BFF 不接触数据目录。

1. 在 IdP 创建支持 Authorization Code、S256 PKCE、受支持签名算法的 ID Token 的机密客户端。
2. 填写 Discovery URL（`https://issuer/.well-known/openid-configuration`）、Client ID、Client Secret、包含 `openid` 的 Scopes。
3. 静态 Redirect URI 填写完整 `https://console.example/api/v1/auth/oidc/callback`，并在 IdP 注册。
4. Dynamic Redirect 模式填写可信 Public Console URL；ZigFS 从该地址的 origin 生成相同固定 callback，不信任请求 Host 或转发头。
5. 设置固定 Role Policy，或使用 Claim Name / Groups Claim / Roles Claim 映射已有策略。支持点分隔嵌套字段、字符串/字符串数组、前缀过滤与去重。固定策略优先；空映射或未知策略拒绝登录。
6. Validate 检查 Discovery 和 JWKS 可访问性，不证明 Client Secret 正确；需实际完成登录。

远端 IdP 必须 HTTPS；仅 loopback 允许 HTTP。Token endpoint 支持 `client_secret_post` 和 `client_secret_basic`。生产 BFF 应使用 TLS；反向代理部署时须检查返回的 Cookie 安全属性及 HTTPS 配置。

## 会话与授权

登录验证 state、nonce、PKCE、issuer、audience/azp、签名、exp/iat/nbf。登录 state 五分钟过期且只使用一次。浏览器 ID Token 必须包含本客户端 audience；Other Audiences 仅用于 WebIdentity。

外部主体由 Provider ID、issuer、sub 生成独立 ID，使用 `oidc-<hash>` 内部名称，不按 email 或用户名合并本地 User。`username_claim` / `email_claim` 支持点分隔路径；登录与续期时读取签名 JWT 的资料，账号菜单展示名称和邮箱。资料仅用于展示，不参与主体匹配或授予权限。

会话当前到期时间取 JWT 到期与管理会话绝对期限的较小值。IdP 返回 Refresh Token 时将其加密保存；网页每 30 秒检查，临近到期时续期并同步资料/策略，支持 IdP 轮换 Refresh Token。续期必须维持同一个 issuer、sub、客户端 audience 和已出现的 nonce，失败撤销本地会话；不能超过最初登录时的管理会话绝对期限。需要时在 Scopes 中增加 `offline_access` 并按 IdP 要求授权。退出先撤销本地会话，再通过 Discovery 的 `end_session_endpoint` 和 `id_token_hint` 跳转 IdP。Provider 编辑、停用、删除及同 ID 重建均使旧会话/临时凭证失效。每次授权重新加载策略文档，显式 Deny 优先；Session Policy 只能缩小权限。

## S3 STS

向 S3 endpoint 的 `/` 发送未签名 `application/x-www-form-urlencoded` POST：

```text
Action=AssumeRoleWithWebIdentity
Version=2011-06-15
RoleArn=arn:aws:iam::000000000000:role/oidc/<provider_id>
RoleSessionName=my-session
WebIdentityToken=<JWT>
DurationSeconds=3600
```

RoleArn 在此选择 OIDC Provider，不引用普通 User 或本地 Role CRUD。支持该操作的全部请求参数：`RoleArn`、`RoleSessionName`、`WebIdentityToken`、`DurationSeconds`、`Policy`、`PolicyArns.member.N.arn`、`ProviderId`（以及协议 Action/Version）。

可选 `Policy` 和最多 10 个同账户托管策略 ARN 合成会话限制策略，不能扩大继承权限；托管策略 ARN 使用 `arn:aws:iam::000000000000:policy/<name>`，必须存在，序号连续且不可重复。行内策略与 ARN 文本合计最多 2048 字节。`ProviderId` 如提供必须与 JWT issuer 一致；这里只接收 OIDC JWT，不接收 OAuth opaque access token。未知参数明确拒绝。请求期限为 900–43200 秒，实际凭证期限还受 JWT/会话限制；剩余不足 60 秒拒绝签发。XML 返回 AK/SK/SessionToken，用于实际 SigV4 S3 请求；缺少 SessionToken 拒绝访问。响应补齐 `SubjectFromWebIdentityToken`（原始 sub）、`Provider`（issuer）、`Audience`、`AssumedRoleUser` 和 `PackedPolicySize`。后者表示展开后的会话限制策略占本地 128 KiB 上限的百分比，不模拟 AWS 的私有压缩格式。

也可调用 BFF `POST /api/v1/auth/oidc/web-identity`，JSON 字段为 `provider_id`、`web_identity_token`、可选 `duration_seconds`（60–3600）、`session_policy`。密钥仅在签发响应返回，禁止记录响应或 JWT。

## 验证与范围

```sh
cd zigfs && zig build test
cd zigfs-admin/server && go test ./...
# 在仓库根目录，使用已构建的 BFF：
/usr/bin/python3 conformance/oidc_login.py --admin-bin /tmp/zigfs-admin-oidc-qa
python3 conformance/oidc_providers.py --admin-bin /tmp/zigfs-admin-oidc-qa
corepack pnpm --dir zigfs-admin/web run build
```

自动链路覆盖模拟 IdP、浏览器 Cookie 协议、RS256/JWKS 轮换、错误 JWT/nonce/state、重放、退出撤销、重启、Provider 重建、策略变化及真实 SigV4 S3 请求。浏览器布局与人工交互仍按 `zigfs-admin/web/INTERACTION_TEST_MATRIX.md` 的 W07/W08/W09 验收。

## 签名算法

支持 RS256/RS384/RS512、PS256/PS384/PS512（RSA 2048/3072/4096 位）、ES256（P-256）、ES384（P-384）和 EdDSA（Ed25519）。严格绑定 alg/kty/crv，检查 JWK use/key_ops，拒绝 none、对称 HMAC、未知 crit/b64 和密钥类型混淆。ES512/P-521、Ed448 不在当前支持集合；不会降级为其他算法。

## IdP 后通道全局退出

在 IdP 注册 `https://console.example/api/v1/auth/oidc/<provider_id>/backchannel-logout`。IdP 以表单 POST `logout_token`；ZigFS 验证签名、issuer、aud、iat（五分钟窗口）、jti、标准 backchannel-logout event，禁止 nonce，并按 sid/sub 撤销匹配会话及依赖的 S3 临时凭证。jti 重放记录加密持久化。IdP 未提供 end_session_endpoint 或未启用后通道通知时，仍可退出本地会话，跨应用注销须由 IdP 配置支持。不依赖 iframe 前通道退出。

## 环境变量导入

`ZIGFS_OIDC_PROVIDERS` 为 Provider JSON 数组，字段与管理 API 一致，例如：

```sh
export ZIGFS_OIDC_PROVIDERS='[{"provider_id":"corporate","configuration_url":"https://id.example/.well-known/openid-configuration","client_id":"zigfs","client_secret":"<secret>","redirect_uri":"https://console.example/api/v1/auth/oidc/callback","role_policy":"readonly","scopes":"openid,profile,email,offline_access"}]'
```

仅 ZigFS 在启动时导入并加密保存，BFF 不读取此变量。环境管理条目在网页中只读，PATCH/DELETE 返回 409；与网页创建的同 ID 条目冲突会使启动失败，不覆盖原配置。配置相同的重启保留会话；配置变更、移除或取消变量会使对应旧会话失效。非法 JSON、重复 ID、缺失策略均拒绝启动。请使用部署密钥配置，不要将真实 Secret 写入仓库。

范围是 OIDC 及 `AssumeRoleWithWebIdentity`，不表示实现所有 AWS STS 操作、AWS 跨账户资源或 OAuth opaque token 验证。资料来自登录/刷新返回的签名 ID Token，不额外调用 UserInfo。
