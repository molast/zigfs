# Event Destinations — Webhook 与 MQTT 配置

控制台配置分组下的 Event Destinations 提供搜索、刷新、添加、编辑和删除；添加弹窗按 Kafka、MQTT、Webhook、NATS、Pulsar 的顺序以两列卡片展示；Webhook 和 MQTT 可点击，其余类型禁用。列表包含名称、类型、状态、来源、操作。状态“已配置”表示配置已经保存，不表示目标可达或正在推送。来源为 Console，暂不支持环境变量管理目标。

已接入 Bucket 事件订阅和后台持久化队列，详见 [Bucket 事件订阅与投递](bucket-event-subscriptions.md)。保存配置不检测连通性；实际事件投递时才连接目标并读取证书。Kafka、NATS、Pulsar 暂未实现配置或投递能力。

## 表单字段

| 字段 | 行为 |
| --- | --- |
| Name | 必填，1–128 个大写字母、数字或下划线；名称唯一，创建后不可改名或更换类型 |
| Webhook Endpoint | 必填，HTTP/HTTPS 地址，最多 4096 字节；不允许 URL 用户名/密码或 fragment |
| Webhook Auth Token | 可选，最多 4096 字节；加密保存，响应中不返回原值 |
| Webhook Queue Limit | 新增表单不预填；留空时采用默认 100000，填写时范围为 1–4294967295；当前只保存配置 |
| Webhook Queue Directory | 可选，data 下的相对目录，例如 events/WEBHOOK_1 |
| Webhook Client Certificate / Key | 可选，须成对填写；均为 data 下的文件路径，不是 PEM 内容 |
| Webhook Client CA | 可选，data 下的 CA 证书路径 |
| Webhook Skip TLS Verify | true/false，默认 false；显式发送时控制证书链和主机名验证 |
| Comment | 可选，最多 1024 UTF-8 字节 |

目录和证书路径最多 1024 字节，不允许绝对路径、反斜杠、冒号、`.` 或 `..` 路径段。字段不接受控制字符。表单提交时按顺序仅标记首个错误，使用顶部 Toast 提示。长表单内部滚动，底部操作固定。

## 接口及持久化

管理接口：`GET/POST /_admin/v1/event-destinations`、`PUT/DELETE /_admin/v1/event-destinations/{name}`。BFF 将 `/_admin/v1` 映射为 `/api/v1`，转发当前用户身份。要求 `admin:*` 管理权限。

POST 创建；PUT 替换单个目标配置，不覆盖其他目标。最多 100 个目标。同名创建返回 409；更新/删除不存在的目标返回 404；参数无效返回 400；存储故障返回 503。字段与请求示例见 OpenAPI 的 EventDestination。

GET/POST/PUT 响应将 `auth_token` 置为空串，通过 `has_auth_token` 表示是否设置。编辑时空 token 加 `has_auth_token=true` 保留原 token；新 token 替换原值；空 token 加 false 明确清除。UI 的“移除已保存的令牌”仅在保存表单后生效。

ZigFS 使用部署主密钥通过 AES-256-GCM 加密整个配置，并原子写入 `data/.zigfs/config/event-destinations.enc`。重启后从文件恢复；备份时需同时保留部署主密钥。BFF 不访问数据目录。发送适配器会消费 TLS 配置；队列上限、目录及重连间隔通过统一目标策略接口提供，由公共事件运行时负责自动排队与重试。

验证：`python3 conformance/event_destinations.py` 使用临时目录和测试身份验证 CRUD、配置校验、Token 脱敏/保留/清除、重启恢复和非管理员拒绝；不会调用 Webhook 目标。

## MQTT 表单

按界面顺序：Name、Broker、Topic、QoS、Username、Password、Reconnect Interval、Keep Alive Interval、Queue Directory、Queue Limit、TLS Policy、TLS CA、TLS Client Certificate、TLS Client Key、Trust Leaf As CA、WebSocket Path Allowlist、Comment。

- Broker 和 Topic 必填。Broker 支持 `tcp://`、`tls://`、`ssl://`、`mqtt://`、`mqtts://`、`ws://`、`wss://`；禁止 URL 中的账号密码或 fragment。发布 Topic 不允许 `+`、`#` 通配符。
- QoS 为 0、1、2，留空默认 0。新增数值/间隔输入不预填；队列上限留空使用 100000，重连间隔留空使用 `5s`，保活间隔留空使用 `15s`。
- 间隔为整数加 `ms`、`s`、`m` 或 `h`，例如 `30s`；重连须大于零，保活允许 `0s`。MQTT CONNECT 会带上保活秒数（毫秒向上取整，上限 65535 秒）；重连间隔作为统一重试策略提供。当前适配器每次发送建立一次有期限的短会话，不在后台维持连接。
- TLS Policy：空值或 `strict` 验证证书链及主机名、最低 TLS 1.2；`compat` 验证证书并使用 TLS 库默认协议范围；`insecure` 显式跳过证书及主机名验证。发送时拒绝其他策略。Trust Leaf As CA 默认 false，配置的 CA 文件必须具有 CA:TRUE；设为 true 允许将叶证书作为显式信任锚（必须提供 CA 文件）。
- 证书/密钥须成对填写，所有本地目录和证书文件均相对 data；保存时不读取文件。WebSocket Path Allowlist 使用逗号分隔的 `/` 开头路径，例如 `/mqtt,/ws`。
- MQTT 密码随整个配置加密保存。返回 `password=""` 和 `has_password`；编辑保留、替换及清除行为与 Webhook Token 一致。
- Webhook/MQTT 共享列表及 CRUD 接口。保存一种类型时不改动另一种类型的配置。

## 统一事件投递接口

`zigfs/src/ports/event_delivery.zig` 定义协议无关的 `Event` 和 `Sender.send(allocator, io, event)`。事件包含稳定 ID、payload 和 content type；适配器实例绑定单个目标的协议配置及凭据。所有协议返回同一组错误，暂时性超时、不可用和限流通过统一 `retryable` 函数分类。

`zigfs/src/application/event_dispatcher.zig` 提供统一入口 `Dispatcher.deliver(destination_name, event)`，按目标名称查找已注册的 Sender。不同类型的目标通过同一入口调用，业务层无需判断 Webhook 或 MQTT。不存在的目标返回 DestinationNotRegistered，禁止将未实现的发送视为成功。

Webhook 和 MQTT 已实现 Sender，`backend/event_targets.zig` 是唯一的协议选择与装配位置；后续 Kafka 等只需增加适配器并在该处注册。稳定事件 ID 和统一 payload 由事件生成层提供，重试保留 ID 以便去重；队列、退避、重试策略留在公共调度层，不能散落到各业务操作中。适配器报告“按其协议/QoS 已接受”，不等同于最终消费完成。

服务启动后自动运行事件投递任务。`Targets.init` 只构建适配器和绑定表、不连接网络；`Targets.deliver` 是实际发送入口。配置保存不调用 Sender，不检测目标连接。注册表与适配器借用配置字符串和 data 目录句柄，调用方须保持其有效，释放或热更新前等待在途调用结束。

## 已实现的发送逻辑

### Webhook

- 通过统一 Sender 执行 HTTP/HTTPS POST，发送公共事件的 JSON payload。
- `Content-Type: application/json`、`X-ZigFS-Event-ID` 使用稳定事件 ID；Auth Token 作为完整 Authorization 头值，例如 `Bearer token`，不会擅自添加认证前缀。
- 2xx 表示接收成功；401/403 为认证失败，408/504 为超时，429 为限流，其他 5xx 为暂时不可用，其他状态为拒绝。禁止自动跟随重定向，避免目标变更或凭据转发。
- 支持自定义 CA、客户端证书/密钥、跳过证书验证；文件在显式发送时从 data 下解析，拒绝经符号链接逃逸目录。
- 连接和请求均有超时（默认 10 秒，可由组合层设置为 1–60 秒）。响应只保留有界内容，较大的成功响应不会被误判为失败。

### MQTT

- MQTT 3.1.1，支持 TCP、TLS、WS、WSS；`mqtt/tcp` 映射到明文 TCP，`mqtts/ssl/tls` 映射到 TLS。默认端口为 1883/8883，WS/WSS 为 80/443。
- CONNECT 带独立 client ID、clean session、用户名/密码和配置的 keep-alive。每次调用都建立有截止时间的会话，完成后断开，避免隐藏的后台消息或重连。
- QoS 0 在数据写出后返回；QoS 1 等待正确的 PUBACK；QoS 2 完成 PUBREC → PUBREL → PUBCOMP，并处理重复 PUBREC。认证拒绝、错误包 ID、异常报文和超时不会返回成功。
- WS/WSS 实现标准 Upgrade 校验、mqtt 子协议、客户端掩码、二进制分片及 Ping/Pong；只发送到 Broker URL 的路径，配置白名单时必须精确匹配，不进行路径回退。
- 支持自定义 CA、mTLS、TLS Policy 和 Trust Leaf As CA；收到的帧和 MQTT 确认报文均有大小上限。
- 单条事件 payload 上限 1 MiB。QoS 2 的确认语义局限于本次 MQTT 会话，不能代替跨调用/跨重启的业务去重；重试保持事件 ID，消费者仍需按 ID 去重。

### 后续业务事件接入

事件生成层按 Bucket 订阅筛选事件和目标，然后调用 `Targets.deliver(allocator, io, destination_name, event)`，不需要区分 Webhook/MQTT。公共队列层可通过 `Targets.policy(name)` 获得队列上限、目录和重试间隔，通过 `event_delivery.retryable(error)` 判断是否可重试。已订阅的真实业务事件由公共运行时持久化排队并自动投递；目标绑定、故障恢复和事件来源范围见 Bucket 事件文档。

测试命令：

```sh
cd zigfs && zig build event-delivery-probe
cd .. && python3 conformance/event_delivery.py
```

该测试仅使用临时目录、临时证书和本机模拟服务，验证 HTTP 状态、TLS/mTLS、MQTT QoS 0/1/2、WS/WSS、认证错误、超时和确认异常，不读取现有目标或业务订阅。测试 runner 不包含在正常 server 构建/安装中。
