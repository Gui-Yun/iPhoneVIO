# Recording Management API 规范

> 供 rapid_driver (Rust/axum) 实现的 MCAP 录制文件管理与重播 API。

## 概览

| 端点 | 方法 | 功能 |
|------|------|------|
| `/recordings` | GET | 列出所有 MCAP 录制文件 |
| `/recordings/{session_id}` | DELETE | 删除单个录制文件 |
| `/recordings/delete_batch` | POST | 批量删除录制文件 |
| `/recordings/{session_id}/replay` | POST | 开始重播指定录制 |
| `/replay/stop` | POST | 停止当前重播 |
| `/replay/status` | GET | 查询重播进度 |

**通用约定**：
- Content-Type: `application/json`
- 字段命名: `snake_case`
- 错误响应统一格式: `{"error": "描述信息"}`
- `session_id` 即录制时传入的 UUID，也是 MCAP 文件名前缀

---

## 端点详情

### 1. 列出录制文件

```
GET /recordings
```

扫描固定录制目录下所有 `.mcap` 文件，返回文件列表及存储统计。

**Query 参数**（可选）：

| 参数 | 类型 | 说明 |
|------|------|------|
| `sort` | string | 排序字段，可选 `created_at`（默认）、`size`、`name` |
| `order` | string | `desc`（默认）或 `asc` |

**响应 200**：

```json
{
  "recordings": [
    {
      "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
      "filename": "a1b2c3d4-e5f6-7890-abcd-ef1234567890.mcap",
      "size_bytes": 156000000,
      "created_at": "2024-03-01T14:30:22Z",
      "duration_secs": 154.0,
      "message_count": 4620
    }
  ],
  "total_size_bytes": 2300000000,
  "disk_free_bytes": 15000000000
}
```

**字段说明**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `session_id` | string | 录制会话 UUID |
| `filename` | string | 文件名 |
| `size_bytes` | int64 | 文件大小（字节） |
| `created_at` | string | ISO 8601 创建时间（UTC） |
| `duration_secs` | float \| null | 录制时长（秒），解析失败时为 null |
| `message_count` | int \| null | 消息总数，解析失败时为 null |
| `total_size_bytes` | int64 | 所有录制文件总大小 |
| `disk_free_bytes` | int64 | 录制目录所在磁盘可用空间 |

**错误**：

| 状态码 | 场景 |
|--------|------|
| 500 | 无法读取录制目录 |

---

### 2. 删除单个录制

```
DELETE /recordings/{session_id}
```

删除指定 session_id 对应的 MCAP 文件。

**路径参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `session_id` | string | 录制会话 UUID |

**响应 200**：

```json
{
  "deleted": "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
}
```

**错误**：

| 状态码 | 场景 | 响应示例 |
|--------|------|----------|
| 404 | 文件不存在 | `{"error": "recording not found"}` |
| 409 | 该文件正在录制中 | `{"error": "cannot delete: recording in progress"}` |
| 409 | 该文件正在重播中 | `{"error": "cannot delete: replay in progress"}` |
| 500 | 删除失败 | `{"error": "failed to delete file: <reason>"}` |

---

### 3. 批量删除

```
POST /recordings/delete_batch
```

一次删除多个录制文件。跳过不存在的 session_id（不报错），但对受保护文件（录制中/重播中）返回失败详情。

**请求体**：

```json
{
  "session_ids": [
    "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
    "b2c3d4e5-f6a7-8901-bcde-f12345678901"
  ]
}
```

**响应 200**：

```json
{
  "deleted": [
    "a1b2c3d4-e5f6-7890-abcd-ef1234567890"
  ],
  "failed": [
    {
      "session_id": "b2c3d4e5-f6a7-8901-bcde-f12345678901",
      "error": "cannot delete: replay in progress"
    }
  ]
}
```

**字段说明**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `deleted` | string[] | 成功删除的 session_id 列表 |
| `failed` | object[] | 删除失败的条目，每项包含 `session_id` 和 `error` |

**错误**：

| 状态码 | 场景 | 响应示例 |
|--------|------|----------|
| 400 | `session_ids` 为空或缺失 | `{"error": "session_ids is required and must not be empty"}` |

---

### 4. 开始重播

```
POST /recordings/{session_id}/replay
```

读取指定 MCAP 文件，按原始时间戳间隔回发消息到 ZMQ。同一时刻只允许一个重播任务。

**路径参数**：

| 参数 | 类型 | 说明 |
|------|------|------|
| `session_id` | string | 录制会话 UUID |

**请求体**（可选）：

```json
{
  "speed": 1.0
}
```

| 字段 | 类型 | 默认值 | 说明 |
|------|------|--------|------|
| `speed` | float | 1.0 | 重播速率倍数（0.1 ~ 10.0） |

**响应 200**：

```json
{
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "total_secs": 154.0,
  "message_count": 4620
}
```

**错误**：

| 状态码 | 场景 | 响应示例 |
|--------|------|----------|
| 404 | 文件不存在 | `{"error": "recording not found"}` |
| 409 | 正在录制中 | `{"error": "cannot replay while recording is active"}` |
| 409 | 已有重播进行中 | `{"error": "another replay is already active, stop it first"}` |
| 400 | speed 超出范围 | `{"error": "speed must be between 0.1 and 10.0"}` |

---

### 5. 停止重播

```
POST /replay/stop
```

停止当前正在进行的重播任务。无重播进行时也返回 200（幂等）。

**请求体**：空 `{}` 或无 body 均可。

**响应 200**：

```json
{
  "stopped": true
}
```

---

### 6. 查询重播状态

```
GET /replay/status
```

返回当前重播任务的进度信息。iOS 端可用此接口轮询进度（建议间隔 1 秒）。

**响应 200**（重播进行中）：

```json
{
  "active": true,
  "session_id": "a1b2c3d4-e5f6-7890-abcd-ef1234567890",
  "progress": 0.45,
  "elapsed_secs": 69.3,
  "total_secs": 154.0,
  "speed": 1.0
}
```

**响应 200**（无重播）：

```json
{
  "active": false,
  "session_id": null,
  "progress": 0.0,
  "elapsed_secs": 0.0,
  "total_secs": 0.0,
  "speed": 1.0
}
```

**字段说明**：

| 字段 | 类型 | 说明 |
|------|------|------|
| `active` | bool | 是否有重播正在进行 |
| `session_id` | string \| null | 当前重播的会话 ID |
| `progress` | float | 进度 0.0 ~ 1.0 |
| `elapsed_secs` | float | 已播放时长（秒） |
| `total_secs` | float | 总时长（秒） |
| `speed` | float | 当前播放速率 |

---

## 状态互斥规则

后端需强制以下互斥约束：

| 当前状态 | 禁止操作 | 错误码 |
|----------|----------|--------|
| 录制进行中 | 开始重播 | 409 |
| 录制进行中 | 删除正在录制的文件 | 409 |
| 重播进行中 | 开始录制（已有 `/recording/start` 端点需检查） | 409 |
| 重播进行中 | 删除正在重播的文件 | 409 |
| 重播进行中 | 开始另一个重播 | 409 |

---

## 实现备注

1. **文件扫描**：`GET /recordings` 扫描固定录制目录（如 `~/recordings/` 或配置路径），匹配 `*.mcap`
2. **元数据提取**：`duration_secs` 和 `message_count` 从 MCAP Summary Section 读取，读取失败返回 null 而非报错
3. **磁盘空间**：`disk_free_bytes` 通过 `statvfs` 获取录制目录所在分区可用空间
4. **重播实现**：读取 MCAP 消息，按原始时间戳差值 sleep 后发送到 ZMQ，respect `speed` 倍率
5. **并发安全**：录制/重播状态用 `Arc<Mutex<>>` 或 `tokio::sync::RwLock` 保护
6. **文件名映射**：`session_id` 与文件名的映射规则为 `{session_id}.mcap`
