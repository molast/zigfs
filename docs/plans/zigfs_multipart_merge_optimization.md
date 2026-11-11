# ZigFS Multipart 分片合并优化设计

> 目标：参考 RustFS 与 MinIO 的对象发布思路，优化 ZigFS 超大文件（例如
> 100GB、数千个 Part）的
> `CompleteMultipartUpload`，避免完成上传时重复读取、校验并复制全部分片。
>
> 适用范围：ZigFS 单机版当前设计；为未来多盘/纠删码扩展保留演进空间。
>
> 重要说明：RustFS 和 MinIO
> 的具体实现随版本、存储后端和纠删码配置而变化。本文借鉴其架构原则，不将某个实现细节视为所有场景都适用。

## 1. 设计结论

建议将"Multipart 完成"与"将数据物理拼成一个连续文件"解耦：

-   **CompleteMultipartUpload 负责验证、提交和发布一个逻辑对象。**
-   上传时每个 Part 已进行流式校验，并将 Part 元数据持久化。
-   Complete 阶段只扫描/验证 Part 元数据，不重新读取全部 Part 计算
    checksum。
-   优先通过数据文件
    rename（同一文件系统内）或构建对象的块映射元数据，发布对象。
-   正式对象可以逻辑上表现为一个文件，底层由多个不可变数据 extent/Part
    构成。
-   真正的连续文件物理合并作为可选后台 Compaction，不阻塞上传完成。
-   只有对象元数据与数据引用可靠提交后，才清理 Multipart 临时状态。

这可使 Complete 的工作量从"与对象总字节数 O(total bytes) 相关"转向"与
Part 数量 O(number of parts) 及元数据持久化相关"。需要注意，扫描几千条
Meta 仍不是瞬间完成，但远小于读取并复制 100GB 的成本。

## 2. RustFS / MinIO 可借鉴的共同原则

两者作为 S3 兼容对象存储，Multipart Complete
的关键不应是无条件创建一个新连续文件，而是：

1.  验证 Upload ID 和客户端提交的 Part 列表。
2.  确认 Part 编号、状态、尺寸、ETag/checksum 及提交顺序。
3.  将已上传数据纳入正式对象的数据布局。
4.  提交正式对象元数据，使对象对读取端可见。
5.  清理未提交的 Part、上传状态及临时元数据。

在纠删码或分布式数据布局中，正式对象可能仍由多个物理 shard
构成；"一个对象"不意味着"一个连续的磁盘文件"。不同版本和配置的具体发布路径有所差异，应以对应版本源码为准。

## 3. ZigFS 推荐存储布局

### 3.1 Multipart 临时数据

``` text
data/
└── multipart/
    └── <upload-id>/
        ├── upload.meta
        ├── parts/
        │   ├── part-000001.data
        │   ├── part-000002.data
        │   └── ...
        └── parts-meta/
            ├── part-000001.meta
            ├── part-000002.meta
            └── ...
```

`upload.meta` 建议保存：

-   upload_id
-   bucket_id / object_key
-   状态（Initiated / Uploading / Completing / Completed / Aborted）
-   创建时间、最后活动时间
-   预期 Part 数量（如已知）
-   checksum 方案
-   并发/租约或版本字段（防止重复 Complete）

每个 `part.meta` 建议保存：

-   upload_id
-   part_number
-   data_file_id 或相对路径
-   size
-   ETag
-   checksum_algorithm / checksum_value
-   状态（Writing / Completed）
-   持久化标记或 generation
-   完成时间

### 3.2 正式对象元数据

推荐对象使用逻辑 extent/segment 列表：

``` json
{
  "object_id": "obj-...",
  "bucket": "bucket-a",
  "key": "large.bin",
  "size": 107374182400,
  "layout": "segments",
  "segments": [
    {
      "offset": 0,
      "length": 35651584,
      "data_ref": "segment-000001",
      "checksum": "..."
    },
    {
      "offset": 35651584,
      "length": 35651584,
      "data_ref": "segment-000002",
      "checksum": "..."
    }
  ],
  "etag": "...",
  "checksum": {
    "algorithm": "SHA256",
    "type": "FULL_OBJECT",
    "value": "..."
  }
}
```

说明：示例仅表达结构；具体 ETag 与 checksum 类型必须遵循 ZigFS 的 S3
兼容规则。Multipart ETag 通常不能直接等同于整个对象的 SHA-256。

## 4. 优化后的流程

### 4.1 UploadPart：写入时校验

``` text
HTTP body stream
    ├── 写入临时 part 文件
    ├── 同时计算 Part checksum
    ├── 校验客户端声明的长度/checksum（如提供）
    ├── flush / sync 按 durability policy 执行
    └── 原子提交 Part Meta，状态设为 Completed
```

原则：

-   不把整个 Part 读入内存。
-   checksum 随上传流计算，不在 Complete 阶段重复计算。
-   Part Meta 只能在数据文件成功写入并达到规定持久性后标记 Completed。
-   Part 重传时采用临时文件 + 原子替换，避免覆盖出半成品。
-   同一 Upload ID / Part Number 的并发写入需要锁、generation
    或条件提交来避免竞态。

### 4.2 CompleteMultipartUpload：只做元数据验证和发布

``` text
Complete 请求
    │
    ├── 1. 对 Upload ID 获取 completing 锁 / 状态 CAS
    ├── 2. 读取客户端提交的 Part 列表
    ├── 3. 批量/顺序读取 Part Meta（而不是 Part 数据）
    ├── 4. 校验编号、顺序、状态、ETag、尺寸和最小 Part 大小
    ├── 5. 构建最终 Object Meta / segment map
    ├── 6. 持久化新的对象元数据（暂不公开）
    ├── 7. 通过事务日志或原子 manifest commit 发布对象
    ├── 8. 对象变为可读
    └── 9. 异步清理 Multipart 临时元数据及不再引用的数据
```

对于 3000 个 Part，完整性检查应主要是 3000
条元数据记录的验证。避免逐个读取 3000 个 Part 的 100GB 数据重新算 hash。

### 4.3 正式对象发布的两种模式

#### 模式 A：Segment/extent 逻辑对象（推荐）

-   Part 数据文件成为正式对象的 segment。
-   对象 manifest 记录 segment 顺序、offset、length 和 data reference。
-   Complete 阶段不需要复制 100GB 数据。
-   读取端根据 Range 定位 segment，并跨 segment 顺序读取。
-   之后由后台 Compaction 可选择把多个 segment 合并。

优点：Complete 快、避免写放大、易于支持超大对象。

成本：读取路径需要支持 segment
map；对象删除、覆盖、引用计数和恢复流程需要严格处理。

#### 模式 B：连续文件物理合并

-   顺序读取各 Part，写入一个 staging 文件。
-   验证合并写入长度。
-   fsync staging 文件。
-   原子 rename 到正式路径。
-   提交元数据并清理 Part。

优点：对象在本地表现为一个普通文件，Range 读取简单。

缺点：100GB 文件至少需要再读取约 100GB 并写入约
100GB，完成耗时受磁盘吞吐限制；不能做到瞬间完成。

建议 ZigFS 优先采用模式 A，模式 B 作为可选后台整理或兼容路径。

## 5. Journal / 崩溃一致性

逻辑发布不能只靠"先写 manifest 再删除临时目录"而没有事务保障。建议通过
journal/WAL 或 generation-based manifest commit 实现可恢复状态机。

推荐状态：

``` text
Uploading
   ↓
Completing
   ↓
ObjectManifestPrepared
   ↓
ObjectCommitted
   ↓
CleanupPending
   ↓
Completed
```

恢复策略：

-   `Uploading`：保留 Part，允许续传；按过期策略清理。
-   `Completing` / `ObjectManifestPrepared`：恢复 Complete，或撤销未提交
    manifest。
-   `ObjectCommitted`：对象已经正式可见；只重试临时数据清理。
-   `CleanupPending`：异步继续清理，清理失败不应让对象不可读。
-   已提交对象的 segment 不得因清理 Multipart 临时目录而误删。

核心安全条件：**对象 manifest 的提交必须先于删除其所引用的数据。**

## 6. Range 下载映射

对逻辑对象执行 `GET Object` 或 `Range: bytes=start-end`：

1.  根据对象 manifest 找到与请求区间相交的 segments。
2.  将对象偏移换算为 segment 内偏移。
3.  对相关 segment 执行 seek/read。
4.  按请求字节顺序流式返回。
5.  处理跨 segment 的 Range；不必将完整对象拼入内存。

示意：

``` text
Object offsets:
[ Segment 1 ][ Segment 2 ][ Segment 3 ][ Segment 4 ]

Requested Range:
                  [------ bytes ------]

Read only intersecting segments and subranges.
```

## 7. Checksum 与 ETag 注意事项

-   UploadPart 阶段计算并持久化 Part checksum。
-   Complete 阶段验证客户端提交的 ETag/Part 清单与已存 Meta 匹配。
-   Multipart ETag 的语义需明确实现；不能简单把它当成对象 SHA-256。
-   若需要 FULL_OBJECT
    SHA-256，而上传时没有计算该值，也没有客户端提供可验证的完整
    checksum，则不能仅由每个 Part 的 SHA-256 拼接得到整个文件 SHA-256。
-   若要求完整对象 SHA-256，可在上传阶段按对象字节顺序维护
    hash（对并发乱序 Part，需要额外设计：客户端提供 full
    checksum、完成后后台计算，或采用可组合的 checksum 算法/结构）。

## 8. 清理策略

-   Complete 成功且对象引用已提交：清理 upload meta 与无引用的临时
    Part。
-   AbortMultipartUpload：标记 Aborted，再异步清理。
-   超时未完成上传：后台 lifecycle worker 清理。
-   清理采用可重试任务；删除失败不应破坏已提交对象。
-   清理前校验 data reference 是否已被正式对象引用，防止误删。
-   清理任务应幂等。

## 9. 性能目标与复杂度

  操作                                       推荐方案复杂度 是否读取 100GB 数据
  -------------------- ------------------------------------ ---------------------
  上传 Part                               O(bytes uploaded) 上传流本身会读
  Complete Meta 扫描                     O(number of parts) 否
  manifest 发布          O(number of parts) + metadata sync 否
  Range 下载                  O(命中 segments + 请求 bytes) 只读请求范围
  后台 Compaction                        O(bytes compacted) 是，异步
  物理合并为连续文件                  O(total object bytes) 是

对于 100GB、3000 Part 的场景，Complete 的主要工作应是验证数千条
Meta、生成 manifest 并持久化提交；不是再读写 100GB 数据。

## 10. 推荐实现优先级

1.  **P0：上传阶段校验与 Part Meta 原子提交。**
2.  **P0：Complete 状态机、重复 Complete 幂等、Part 清单校验。**
3.  **P0：对象 manifest/segment map 与原子提交。**
4.  **P0：Range 下载跨 segment 读取。**
5.  **P0：Journal 恢复和引用安全。**
6.  **P1：Abort、过期 Multipart 清理 worker。**
7.  **P1：后台 Compaction（可配置、可限速）。**
8.  **P2：多盘/纠删码数据布局扩展。**

## 11. 最终建议

ZigFS 应把 Multipart Complete
设计为**对象提交操作，而不是大文件物理拼接操作**。

最终对象逻辑上是单一 S3 Object，底层可由多个 segment 组成。Complete 时：

-   不重新读取所有 Part 数据；
-   不重新计算每个 Part 的 checksum；
-   只扫描并校验 Part Meta；
-   生成并原子提交 Object Manifest；
-   确认提交后再清理上传临时状态。

如果产品或底层实现确实要求单一连续文件，则物理合并不可避免地需要读写对象数据；应把它做成后台
Compaction，而不是 Complete 的同步步骤。
