# 网络部署示例

本文提供 Network 页面对应的常见部署方式。开始前请先阅读 [网络配置](../network-settings.md)，理解监听地址、BFF 上游与 Public URL 的区别。

示例中的 `example.com`、IP、证书路径和进程启动方式需要替换为自己的部署值。

## 本机开发

| 项目 | 值 |
|---|---|
| S3 监听 | `127.0.0.1:9000` |
| Admin 监听 | `127.0.0.1:9001` |
| BFF 上游 | `http://127.0.0.1:9000` |
| Public URL | `http://127.0.0.1:9000` |
| Virtual Hosted Addressing | 关闭 |
| Trusted Proxies | 没有代理时留空；需要 BFF 转发真实客户端信息时，信任 BFF 的实际连接地址 |

浏览器访问 `http://127.0.0.1:9001`。此配置面向本机，不能直接供其他电脑使用。

## 局域网直连

假设 ZigFS 与 Admin 部署在 `192.0.2.10`，浏览器运行在另一台机器上：

| 项目 | 值 |
|---|---|
| S3 监听 | `0.0.0.0:9000` |
| Admin 监听 | `0.0.0.0:9001` |
| BFF 上游 | `http://127.0.0.1:9000`，仅限两个进程同机 |
| Public URL | `http://192.0.2.10:9000` |
| Virtual Hosted Addressing | 关闭 |

浏览器访问 `http://192.0.2.10:9001`。开放所需网络端口。两个进程分开部署时，把 BFF 上游替换为 BFF 能访问的 ZigFS 地址。

## 单层 HTTPS 反向代理

示例拓扑：

```text
浏览器/S3 客户端
  ├─ https://s3.example.com    → Nginx → 127.0.0.1:9000 ZigFS
  └─ https://admin.example.com → Nginx → 127.0.0.1:9001 BFF → ZigFS
```

配置 Public URL 为 `https://s3.example.com`，先使用 Path-style。在该同机拓扑中，将 `127.0.0.1` 加入可信代理；如果连接使用 IPv6，还需添加实际观察到的 `::1`。

下面是 Nginx 的最小相关配置示例。它假设 Nginx 直接接收客户端连接，没有更外层的代理；证书已经准备好。

```nginx
server {
    listen 443 ssl;
    server_name s3.example.com;
    ssl_certificate     /etc/nginx/certs/s3/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/s3/privkey.pem;

    client_max_body_size 0;
    location / {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_request_buffering off;
        proxy_buffering off;
        proxy_read_timeout 900s;
        proxy_send_timeout 900s;
    }
}

server {
    listen 443 ssl;
    server_name admin.example.com;
    ssl_certificate     /etc/nginx/certs/admin/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/admin/privkey.pem;

    location / {
        proxy_pass http://127.0.0.1:9001;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_read_timeout 1000s;
    }
}
```

S3 请求的 Host、路径和查询参数参与签名校验。不要添加 S3 路径前缀或改写已签名的 URL。保留 `$http_host` 也会保留客户端指定的非默认端口。

示例覆盖客户端提交的转发头；不要把它直接套用到多层代理后方，否则 `$remote_addr` 将是更外层代理的地址。

### 开启虚拟主机寻址

1. 为 `s3.example.com` 和 `*.s3.example.com` 配置解析。
2. 准备覆盖这些域名的证书。
3. 将 S3 的 `server_name` 扩展为：

   ```nginx
   server_name s3.example.com *.s3.example.com;
   ```

4. 确认代理继续保留原始 Host。
5. 在 Network 开启 Virtual Hosted Addressing 并保存。
6. 使用不含点的测试 Bucket 获取新链接，确认形如 `https://photos.s3.example.com/image.jpg`，并实际上传下载。

## 多层代理

每一跳都必须保持 IP 和协议列表对齐。例如：

```text
X-Forwarded-For: 198.51.100.7, 10.0.0.2
X-Forwarded-Proto: https, http
```

如果 TCP 对端和 `10.0.0.2` 都可信，ZigFS 会将客户端识别为 `198.51.100.7`，将安全传输状态识别为 `true`。如果 `10.0.0.2` 不可信，则在该节点停止，使用其对应的 `http`。

边缘代理应覆盖外部客户端提交的转发信息；内部可信代理追加实际观察到的节点和协议。BFF 已执行追加操作。请核对负载均衡器的实际输出，当前实现不会把单个 `https` 自动套用到整条多节点链。

## 容器和远程部署

- 在容器内使用 `0.0.0.0` 或适合该环境的地址监听；`127.0.0.1` 只能访问当前容器。
- BFF 上游可以使用内部服务名，例如 `http://zigfs:9000`。
- Public URL 必须是浏览器可达地址，不能填写只在容器网络内解析的服务名。
- 可信代理填写 ZigFS 实际看到的代理来源，可能是容器网段或网关地址。
- 持久化 ZigFS 数据根目录，以及 BFF 的独立配置目录。
- 改监听端口后，同步调整容器端口映射、服务发现、健康检查及代理上游。ZigFS 不会修改这些部署资源。

BFF 独立配置示例：

```bash
export ZIGFS_ADMIN_LISTEN=0.0.0.0:9001
export ZIGFS_ENDPOINT=http://zigfs:9000
export ZIGFS_ADMIN_CONFIG=/var/lib/zigfs-admin/listener.json
```

保存文件存在时，其中的监听地址和上游候选值优先于上述两个地址环境变量。

## 上线检查

1. 从 BFF 主机检查 ZigFS 的 `/health/ready`。
2. 从用户所在网络打开 Admin 并登录。
3. 检查页面显示的当前地址、待生效地址和 Public URL。
4. 上传并下载一个测试对象，确认生成链接使用正确域名和协议。
5. 使用代理访问后，确认审计记录中的客户端 IP 符合预期。
6. 如使用 IP/HTTPS 条件策略，分别测试允许和拒绝请求。
7. 重启服务，确认配置保留；若改过端口，确认重启提示已消失。

以上 Nginx 配置是部署参考，未替代针对实际 DNS、证书、代理版本和网络环境的验收。
