"""Static catalog inventory; does not execute CLI requests or tests. Run at repo root."""
import json, re
from pathlib import Path
root = Path('zigfs-cli')
model = json.loads((root / 'src/models/s3.json').read_text())
cli = (root / 'src/cli.zig').read_text()
base = set(re.findall('\\.path = "([^"]+)"', cli))
new = dict(re.findall('\\.path = "([^"]+)", \\.operation = "([^"]+)"', (root / 'src/catalog.zig').read_text()))
workflows = set(re.findall('\\.path = "([^"]+)"', (root / 'src/workflows.zig').read_text()))
routes = json.loads((root / 'src/models/management-routes.json').read_text())
assert len({r['command'] for r in routes}) == len(routes), 'duplicate management command'
assert not base & new.keys(), 'duplicate S3 command'
assert not workflows & (base | new.keys()), 'duplicate workflow command'
lines = ['# CLI 命令注册清单（运行验证另列）', '', '最新运行证据见 [2026-11-18 集中验证](../docs/zigfs-zc-cli-validation.md)。下方待验证表示尚未完成逐操作全部分支验收；历史实现交付说明不替代该报告。', '', '由 `python3 zigfs-cli/scripts/generate_coverage.py` 静态生成；仅核对注册表，不能替代运行验证。', '', '单机 S3 与旧协议共 **100** 项；保留原有已验收路径，新增字段及命令均待验证。多机复制和云端可选 API 不注册。', '', '完整请求字段来自 `src/models/s3.json`；默认通过 `s3api OP ALIAS --input-json FILE` 提交，复杂字段不要求每个高层入口都有独立短选项。', '', '| S3 operation | s3api 入口 | 高层映射 / 已有路径 | 批量接入状态 |', '|---|---|---|---|']
for op in sorted(model['operations']):
    assert 's3api ' + op in base | new.keys(), op
    high = [p for p, mapped in new.items() if mapped == op and (not p.startswith('s3api '))]
    lines.append(f'| `{op}` | `s3api {op}` | ' + ('、'.join(('`' + p + '`' for p in high)) or '使用 s3api 原始入口；已有便利入口另见 README') + ' | 新路径/扩展字段待验证 |')
lines += ['', '## Management 路由', '', '独立管理端点、Bearer 会话；具体请求 JSON 见 `docs/api/zigfs-management-v1.openapi.yaml` 和各命令 `--help`。源代码新增、OpenAPI 尚未描述的请求，由服务端校验；不宣称拥有完整本地 schema。', '', '| CLI 入口 | HTTP | 位置参数（ALIAS 后） | 状态 |', '|---|---|---|---|']
for route in sorted(routes, key=lambda r: r['command']):
    lines.append(f"| `{route['command']}` | `{route['method']} {route['path']}` | {', '.join(route['parameters']) or '—'} | 待验证 |")
compat = dict(re.findall(r'\.path = "([^"]+)", \.operation = "([^"]+)"', (root / 'src/compat_catalog.zig').read_text()))
lines += ['', '## 高层兼容与便利入口', '', '| 命令 | 分派目标 | 状态 |', '|---|---|---|']
for command, target in sorted(compat.items()):
    lines.append(f'| `{command}` | `{target}` | 已接入；具体分支/边界见缺口登记，待验证 |')
lines += [
    '', '## 本次接入边界', '',
    '- 集中审查 R01–R08 已补写逻辑、待验证：ListBuckets 分页、历史删除参数与部分失败汇总、扫描资源预算与过滤、工作流参数校验、原错误保留及帮助更新。详见 [集中静态审查清单](../docs/zigfs-zc-cli-static-review.md)。',
    '- 字段处理补全（待验证）：新旧请求共享元数据 header-map 提取；模型化响应保留 data.metadata；生命周期编辑与文件往返保留 TransitionDefaultMinimumObjectSize。旧 Rules-only 导入仍由服务端决定未指定设置的缺省值。',
    '- 最新逐项状态见 [缺口补全登记](../docs/zigfs-zc-cli-gap-audit.md)。注册数量不证明所有分支或参数组合已实现。',
    '- 接续补全：retention bypass 请求字段、mirror 连接覆盖参数、模型/管理 JSON stdin、KMS create/status 便利参数、OIDC 保留现值更新、管理动作帮助；全部待验证。',
    '- OIDC update 无 CAS，须串行写入；上游 KMS tag/列表分页/restart/roundtrip、Access Key provider 聚合过滤不属于当前已接入契约。用户专属密钥使用 admin user access-key list。',
    '- 本轮缺口补全仅修改逻辑、生成模型/清单和格式化；没有编译、测试、CLI 请求或服务端联调。现有二进制未重建。',
    '- watch 已接入真实成功对象事件的游标长轮询，需新版服务端及 admin:* Bearer 权限；4096 条 / 8 MiB 内存回放，重启或游标过期明确失败。不是持久化队列，不承诺无损或 exactly-once。',
    '- mirror --watch 为周期性完整比较/同步；include/exclude 过滤同样保护目标删除。默认不删除，覆盖须 --overwrite --yes，删除须 --remove --yes。远端扫描须 --fallback。',
    '- tree 输出分层结构，--level 截断标记 view_truncated；find 支持 * / ? GLOB、POSIX ERE 和相对时间过滤。du 优先管理快照，支持服务范围、版本和未完成分片扫描。',
    '- 本地同步根目录须存在，拒绝符号链接和不安全名称。扫描最多 100000 项 / 64 MiB；树最多 200000 节点。',
    '- 同实例比较 size+ETag，本地与远端保守复制；不把 ETag 当通用内容哈希。版本化移动须明确 --version-id；清桶与同步不锁并发写入。',
    '- 配置便利语法与原始 s3api JSON 并存；tag remove 按键保留其他标签，event 按 ID 增删，生命周期导出可直接导入。S3 配置读改写无 CAS，需串行修改。',
    '- IAM 成员/策略修改携带 expected_updated_at；OIDC 机密使用配置文件。KMS 计划删除仅支持服务端的 7 天窗口，立即删除需额外确认。',
    '- 扩展 SSE/校验/条件字段通过 s3api 完整 JSON；自动分片恢复、stdout 下载、行截取与扩展字段的部分组合仍显式拒绝。',
    '- SHA256 可自动计算；其他上传校验算法需提供校验值。SSE-C 密钥/MD5 使用 Base64；日期头使用 HTTP 日期，XML 时间使用 ISO 8601。',
    '- Select 按帧校验 CRC 并输出 Records，错误或缺少 End 不发布文件；服务端集成行为待验证。',
    '- 对象归档、报表、ABAC、加速、网站等客户端接入不等于服务端实现；501 不算通过。多机、云专属 API 和缺少独立契约的 service-account/MFA/IAM archive 不在本轮范围。',
    '',
]
(root / 'CLI-COVERAGE.md').write_text('\n'.join(lines))
print(f"Static catalog: {len(model['operations'])} S3 operations, {len(routes)} management routes, {len(workflows)} workflow entries")
