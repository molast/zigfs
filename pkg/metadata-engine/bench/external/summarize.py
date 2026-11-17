"""Render completed cross-engine results as record counts, seconds and memory."""
import argparse
import json
import os
import statistics
from pathlib import Path

NAMES = {
    'zig': 'Zig（默认同步）',
    'zig-fullsync': 'Zig（更强落盘）',
    'bbolt': 'bbolt（独立提交）',
    'bbolt-batch': 'bbolt（合并更新）',
    'pebble': 'Pebble',
    'badger': 'Badger（同步写）',
}
ORDER = ['zig-fullsync', 'pebble', 'bbolt', 'bbolt-batch', 'zig', 'badger']


def seconds(run, phase, records):
    metric = run['metrics'][phase]
    if 'elapsed_ms' in metric:
        return metric['elapsed_ms'] / 1000
    return records / metric['qps']


def render(paths, output, predictions=None):
    prediction_map = {(c["records"], c["engine"]): c for c in (predictions or {}).get("cases", [])}
    reports = [(path, json.loads(path.read_text())) for path in paths]
    reports.sort(key=lambda item: item[1]['records'])
    for _, report in reports:
        if report['payload_bytes'] != 256 or report['workers'] != 8:
            raise ValueError('overview expects 256-byte payloads and 8 workers')
        expected = {(engine, iteration + 1) for engine in report['engines']
                    for iteration in range(report['rounds'])}
        actual = {(r['engine'], r['round']) for r in report['runs']}
        missing = expected - actual
        covered = all((report['records'], engine) in prediction_map for engine, _ in missing)
        if not actual.issubset(expected) or not covered or len(actual) != len(report['runs']):
            raise ValueError('unaccounted incomplete or duplicate cases')
        if not all(r['verified'] and r['returncode'] == 0 for r in report['runs']):
            raise ValueError('unverified case')
    lines = [
        '# 元数据引擎性能对比：数据量、耗时与内存', '',
        '**看表即可：同样数量的数据，写完花几秒、全部更新花几秒、整轮花多久、最高占多少内存。**', '',
        '每条值 256 字节，首次每批写 32 条，更新用 8 个并发任务、每次一条。每轮都是新库，',
        '实测均逐条验证重开后的键和值。预计超过 10 分钟的项目按要求跳过，用预测标明，不能视为实测。', '',
        '## 已完成的规模', '',
        '| 数据量 | 完成实测的配置数 | 预测未跑 | 中止未完成 |',
        '| --- | ---: | ---: | ---: |',
    ]
    for _, report in reports:
        measured = len({r['engine'] for r in report['runs']})
        cases = [c for (count, _), c in prediction_map.items() if count == report['records']]
        predicted = sum(c['status'] == 'predicted' for c in cases)
        stopped = sum(c['status'] == 'stopped' for c in cases)
        lines.append(f"| {report['records']:,} 条 | {measured} | {predicted} | {stopped} |")
    lines += [
        '', '同一引擎可能有两种配置：Zig 默认/更强落盘，bbolt 独立提交/合并更新。',
        '**1 万条取三轮中间值；新增实测为单轮，数据校验全部通过。预测项没有完成数据校验，也没有内存结果。**', '',
        '## 先看懂两种比较范围', '',
        '- **Zig 更强落盘、Pebble、bbolt 两种模式**：都请求刷新设备缓存，优先在这些行之间比较写入耗时。',
        '- **Zig 默认同步、Badger 同步写**：也等待各自同步操作，但系统调用和设备刷新要求不同。',
        '  这两行是各自配置下的实测，不应直接认定为相同断电保证下的速度优势。', '',
        '不需要记住同步术语；具体实现见[技术明细](EXTERNAL-COMPARISON-DETAILS.md)。',
    ]
    for path, report in reports:
        count = report['records']
        title = f'{count // 10000} 万条'
        lines += ['', f'## {title}：时间和内存', '',
                  '| 引擎 / 模式 | 结果类型 | 首次写完 | 全部更新一遍 | 整轮测试用时 | 峰值内存 |',
                  '| --- | --- | ---: | ---: | ---: | ---: |']
        groups = {}
        for name in ORDER:
            runs = [r for r in report['runs'] if r['engine'] == name]
            if not runs:
                case = prediction_map.get((count, name))
                if case is None:
                    continue
                if case['status'] == 'predicted':
                    minutes = case['predicted_seconds_reference'] / 60
                    lines.append(f'| {NAMES[name]} | **预测，未跑** | — | — | **约 {minutes:.1f} 分钟** | 未测 |')
                else:
                    elapsed = case['observed_elapsed_at_least_seconds'] / 60
                    lines.append(f'| {NAMES[name]} | **中止，未完成** | — | — | 已运行至少 {elapsed:.1f} 分钟；总时间未知 | 无完整结果 |')
                continue
            groups[name] = runs
            insert = statistics.median(seconds(r, 'durable_insert', count) for r in runs)
            update = statistics.median(seconds(r, 'concurrent_overwrite', count) for r in runs)
            total = statistics.median(r['elapsed_seconds'] for r in runs)
            memory = statistics.median(r['peak_rss_bytes'] / 1048576 for r in runs)
            lines.append(f'| {NAMES[name]} | 实测（{len(runs)} 轮） | {insert:,.3f} 秒 | {update:,.3f} 秒 | {total:,.3f} 秒 | {memory:,.2f} MiB |')
        lines += ['', '读取和重新打开的时间：', '',
                  '| 引擎 / 模式 | 逐条读取全部数据 | 分页读完全部数据 | 正常关闭后重开 |',
                  '| --- | ---: | ---: | ---: |']
        for name, runs in groups.items():
            read = statistics.median(seconds(r, 'warm_get', count) for r in runs)
            page = statistics.median(r['metrics']['prefix_pages']['elapsed_ms'] / 1000 for r in runs)
            reopen = statistics.median(r['metrics']['reopen']['elapsed_ms'] / 1000 for r in runs)
            lines.append(f'| {NAMES[name]} | {read:,.4f} 秒 | {page:,.4f} 秒 | {reopen:,.4f} 秒 |')
        link = os.path.relpath(path.resolve(), output.parent.resolve())
        lines += ['', f'[这组全部原始结果]({link})。']
    if predictions:
        lines += [
            '', '## 预测怎么来的？', '',
            '**每项最多实测 10 分钟；预测只用于节省长测时间，不作为引擎排名依据。**', '',
            '- Pebble 100 万条：10 万条实测整轮约 80.7 秒，按数据量十倍估算约 13.4 分钟。',
            '- bbolt 合并更新的 10 万条：已运行至少 570 秒（9.5 分钟）仍未完成，按新限制停止。',
            '  不知道总时间，也未完成重开校验；不能把 570 秒写成完整实测时间。',
            '- bbolt 合并更新的 100 万条：以这 570 秒乘十，作为约 95 分钟的粗略规划参考。',
            '- bbolt 独立提交：1 万条时比合并模式约慢 1.56 倍；沿用这个比例，',
            '  估算 10 万条约 14.9 分钟、100 万条约 148.7 分钟。', '',
            '以上假设耗时随数据量近似线性、两种提交模式的比例不变；实际可能偏离很大，',
            '尤其 bbolt 的依据包含一次未完成测试。这些不是统计置信区间或严格时间下限。',
            '**不预测首次写入/更新各阶段时间、内存、磁盘占用，也不将预测项标为校验通过。**', '',
            '[预测依据与中止记录](results/external-predictions.json)',
        ]
    lines += [
        '', '## 这些数字分别表示什么？', '',
        '- **首次写完**：将所有新记录写入空库，每批 32 条提交，不是每条单独同步。',
        '- **全部更新一遍**：每条记录都更新一次，每次一条，8 并发；不能与批量插入当成相同写法。',
        '- **整轮用时**：进程启动、写入、读取、更新、分页、全量扫描、关闭重开、逐条校验和退出。',
        '  不含编译及外层临时库清理；本次补测未额外手动创建快照，后台维护仍按引擎默认机制运行。',
        '- **峰值内存**：整个数据库进程最高占用，包含索引、缓存、扫描结果及临时副本，不是净数据量。',
        '  1 GiB = 1024 MiB；100 万条 256 字节的值本身约 244 MiB。各引擎缓存预算没有统一。',
        '- **读取**：热缓存读取，没有并发写者，不包含 HTTP/S3；不能代表冷磁盘速度。',
        '- **重开**：正常关闭后的启动，不是断电恢复；部分引擎会在关闭时先刷盘。', '',
        'bbolt 两种模式的初次插入方法相同，只在更新阶段是否合并请求上不同；首次写入耗时的',
        '差别属于不同轮次波动。三轮结果各列独立取中间值，不应直接相加还原某一轮总时间。', '',
        '## 与旧报告的区别', '',
        '此前 10 万/100 万条只有 Zig 自身测试，且包含额外手动快照、第二次重开和脚本清理；',
        '**本页实测改用新补测的统一对照流程，超过时限的项目单独标为预测或中止**，',
        '因此整轮时间和峰值内存可能不同。旧数据没有删除，',
        '仍见[性能优化记录](PERFORMANCE.md)。不要将不同流程的数字直接解读为性能回退或提升。', '',
        '本地环境为 Apple M2 Pro、16 GiB 内存、macOS，Zig ReleaseFast 与 Go 优化构建。',
        '没有清除系统缓存，也没有运行真实断电、冷缓存、长期压实/GC 或 NAS 实机测试。',
        '普通 KV 对照不等于移植完整 MetadataRepository 后的性能。', '',
        '[环境与版本](results/external-environment.json) · [技术明细](EXTERNAL-COMPARISON-DETAILS.md)',
        '· [压测源码与复现步骤](external/README.md)', '',
    ]
    output.write_text('\n'.join(lines))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('results', nargs='+', type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--predictions', type=Path)
    args = parser.parse_args()
    predictions = json.loads(args.predictions.read_text()) if args.predictions else None
    render(args.results, args.output, predictions)


if __name__ == '__main__':
    main()
