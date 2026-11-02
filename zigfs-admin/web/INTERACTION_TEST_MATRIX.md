# Admin 权限交互测试矩阵

统一类型入口：`pnpm run typecheck`；生产构建入口：`pnpm run build`。当前项目尚未引入浏览器测试 runner，因此以下矩阵由后续 Playwright/浏览器验收执行，不能用 TypeScript 编译代替。

| 编号 | 场景 | 浏览器操作 | 关键断言 | 状态 |
| --- | --- | --- | --- | --- |
| W01 | User/Group/Policy/Key 创建、编辑、删除 | 依次打开四个页面，创建一条测试数据，编辑后删除；重复名提交一次 | 列表和关联选择器刷新；失败保留草稿并显示顶部中央 toast | 待验收 |
| W02 | 401/403/409/存储错误 | 让会话过期；用受限主体访问；提交重复名称；模拟 BFF/FS 错误 | 401 清理会话；403/409 不伪造成功；冲突详情可见 | 待验收 |
| W03 | 权限变更后缓存失效 | 在一个页面修改策略/组关联，再回到用户、Key 和策略列表 | 写 API 派发 `zigfs:permissions-changed`；下一次请求重新取服务端状态 | 待验收 |
| W04 | Bucket Policy/公共访问/对象版本标签 | 编辑 Bucket Policy 和公共访问配置；对两个版本设置不同标签并读取 | 读写结果与后端 IAM 一致，版本标签不串版本 | 待验收 |
| W05 | 身份联邦 Role/Organization/STS 会话撤销 | 从“身份联邦与 STS”进入角色/组织页面；创建带 SessionTags 的会话；撤销后刷新列表并访问 S3 | Role 不出现在 User/Group 编辑器中；角色主体和标签生效；撤销后列表及会话访问立即失效 | 待验收 |
| W06 | 秘密、日期、窄屏和键盘 | 创建 Key 查看 secret；打开日期时间控件；缩窄窗口并只用键盘操作 Dialog | Secret 只显示一次；日期按时区显示；Dialog 可键盘操作且 toast 位于顶部中央 | 待验收 |

## 验收记录

浏览器验证由人工执行，完成一项后填写日期、浏览器/窗口尺寸、结果和截图或录屏路径；未填写证据不得勾选最终完成门槛。

| 编号 | 日期 | 环境 | 结果 | 证据 |
| --- | --- | --- | --- | --- |
| W01 | — | — | 待验收 | — |
| W02 | — | — | 待验收 | — |
| W03 | — | — | 待验收 | — |
| W04 | — | — | 待验收 | — |
| W05 | — | — | 待验收 | — |
| W06 | — | — | 待验收 | — |

## W07 OIDC Provider 配置（待人工验收）

- [ ] 打开 OIDC Settings，创建完整 Provider，保存后左侧出现条目；刷新仍存在。
- [ ] 点击条目进入编辑，Secret 为空并提示保留；修改显示名、开关、Scopes 和高级 Claim 字段后保存，重新选择核对值。
- [ ] 重复 ID、不存在的 Role Policy、无效 URL 和缺少 openid 显示顶部中央错误 toast，草稿不丢失。
- [ ] 删除有确认框；取消保留、确认后移出列表；列表加载失败可 Retry。
- [ ] 普通用户无法访问配置页或直接调用 Provider API。
- [ ] Validate 调用 ZigFS 检查 Discovery/JWKS，成功不代表 Client Secret 已验证；失败通过顶部居中 toast 显示。


## W08 OIDC 登录与会话（待人工验收）

- [ ] 登录页只显示启用的 Provider；点击后跳转 IdP，成功回到 Admin。
- [ ] 取消授权、错误回调、过期 state 均回到登录页，顶部居中 toast 提示，不泄露 code/token。
- [ ] 外部身份仅能看到策略允许的数据；同名本地 User 不合并、不继承 root 权限。
- [ ] 退出后刷新不能恢复会话；Provider 编辑/停用后旧会话在后续请求中失效。
- [ ] Dynamic Redirect 使用配置的 Public Console URL 来源，生成固定 callback；不受浏览器 Host 影响。
- [ ] 深色主题、键盘操作和窄屏下 Provider 配置与登录按钮可用。

协议链路已由 `conformance/oidc_login.py` 自动验证；上述浏览器项目仍需人工确认，不以编译或 HTTP 测试代替。


## W09 OIDC 扩展能力（待人工验收）

- [ ] 登录后 shadcn/ui 用户菜单显示配置 Claim 对应的名称/邮箱；缺失名称时回退内部名称。
- [ ] IdP 发放 Refresh Token 后，保持页面打开跨过 ID Token 到期时间，仍可请求；IdP 修改的名称/邮箱在续期后更新。
- [ ] IdP 撤销 Refresh Token 或改变 sub，续期失败回到登录页并以顶部居中 toast 提示。
- [ ] 退出先清除 ZigFS Cookie，再跳转支持的 IdP 注销页；IdP 后通道退出后当前页面下次请求失效。
- [ ] 环境管理 Provider 有来源说明；字段/Save/Delete 不可用，Add Provider 仍可创建其他条目。
- [ ] 用户菜单键盘导航、窄屏和深浅主题正常。

## W10 Monitoring / Running Status（待人工验收）

- [ ] 菜单显示 Monitoring，System Setting 仍是最后一项；Monitoring 打开 Running Status。
- [ ] Refresh 禁止重复请求，30 秒自动刷新；离开页面后停止刷新。
- [ ] 健康、恢复、资源统计、存储占用及扫描分片与服务端响应一致；缺失容量、磁盘统计显示 Not reported，不显示虚构的 0 或健康状态。
- [ ] 单个接口失败时其区域变为 Unknown/不可用，其他成功区域仍展示，顶部居中 toast 提示失败来源；重试恢复。
- [ ] Server List 与 Diagnostic Details 可通过鼠标和键盘展开/收起。
- [ ] 窄屏下卡片堆叠，长地址可换行；深浅主题下均可阅读。

- [ ] Storage Usage and Scanner 显示真实文件系统 Used/Available/Total、百分比、Last Completed Scan、Scanner Status、Scan Duration；逻辑对象字节不用于物理容量百分比。
- [ ] 诊断五行按 Peer Health、Storage Readiness、Usage Freshness、Listing and Metacache、Workload Admission 排列；不适用/未上报状态不能显示 Healthy。
- [ ] 扫描失败时显示 Failed/Needs attention，保留上一次成功时间；重启后没有扫描记录时不显示伪造时间。

## W11 System Setting（待人工验收）

- [ ] 鼠标和键盘可切换常规、网络、安全、存储、日志和关于 ZigFS 六个分类，选中状态与内容一致。
- [ ] 配置值与 Settings/System API 响应一致；字段只读，未上报的信息明确标注，不提供无接口支持的保存操作。
- [ ] 刷新期间按钮禁用；部分接口失败以顶部中央 toast 提示，成功部分仍可查看，刷新可重试。
- [ ] 桌面左侧分类固定，右侧内容独立滚动，底部刷新操作始终可见。
- [ ] 窄屏布局无横向溢出，深浅主题下字段、说明和选中状态清晰可读。

### W11 补充：网络、日志、存储和关于

- [ ] 网络页按 S3 API、管理控制台、公网访问、可信代理分组；浏览器访问入口不被标注为服务器监听地址，未上报配置不显示示例值。
- [ ] 日志页可通过键盘切换日志配置、审计日志、日志管理；返回分类后内容正常，未接入的写入操作有明确说明。
- [ ] 存储页容量环、容量表与 Storage API 的 physical_used/available/total 一致；缺失容量不显示 0%，扫描失败不显示成功。
- [ ] 关于页显示实际版本与 Apache 2.0 许可证；CPU、内存、构建信息未上报时不显示虚构数据。
- [ ] 四个内容页在窄屏与深浅主题下可读；左侧分类不随右侧内容滚动，底部刷新按钮始终可用。
