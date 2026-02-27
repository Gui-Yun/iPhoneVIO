# FeasibleCap 功能差距分析

> 基于论文方法章节 vs 当前 iPhoneVIO 代码库的对比分析
> 开发策略：**UI → 逻辑 → 通信联调**

---

## 当前已完成的功能

| 功能 | 对应文件 | 状态 |
|------|---------|------|
| ARKit VIO 6DoF 位姿估计 (60Hz) | `ARSessionManager.swift` | ✅ 完成 |
| JPEG + 位姿 二进制数据包封装 | `NetworkClient.swift` | ✅ 完成 |
| Bonjour/mDNS 自动发现 + TCP 流传输 | `BonjourManager.swift`, `NetworkClient.swift` | ✅ 完成 |
| 录制控制 (HTTP API → rapid_driver) | `RecordingController.swift` | ✅ 完成 |
| 数据管理界面 (浏览/删除/批量操作) | `DataManagementView.swift`, `DataManagementController.swift` | ✅ 完成 |
| 回放触发 (HTTP REST API) | `DataManagementController.swift` | ✅ 完成 |
| 设备状态监控与重启 | `RecordingController.swift` | ✅ 完成 |

---

## 待实现功能总览

以下 **11 个大功能** 按开发阶段分组，每个功能包含论文描述、技术要点和依赖关系。

---

## 阶段一：UI 层

### 功能 1：虚拟机器人基座放置 (AR Tap-to-Place)

**论文描述 (§3.3)**：用户在 AR 场景中点击一个位置来锚定虚拟机器人的基座位置，结合 ARKit 世界坐标系建立演示者工作空间与目标机器人运动学坐标系之间的空间关系。

**需要实现**：
- AR 场景中的点击射线检测 (ARKit raycast / hit test)
- 基座锚点的 3D 可视化 (SceneKit 节点：坐标轴 + 半透明底座)
- 基座位置的存储与重置功能
- UI 按钮：「放置基座」模式开关

**技术要点**：
- 使用 `ARSession` 的 `raycast(_:)` 或 `ARSCNView` 的 hit test
- 基座 Transform 存储为 `simd_float4x4`，后续 IK 计算以此为参考系
- 需要在录制前完成放置，录制按钮应在基座未放置时禁用

**UI 元素**：
- 底部工具栏新增「放置基座」按钮
- 放置模式下，屏幕中央显示十字准星
- 放置成功后，AR 场景中显示机器人坐标系标记
- 状态提示文字

**依赖**：无（纯 UI + ARKit raycast）

---

### 功能 2：Camera-to-TCP 标定界面

**论文描述 (§3.3)**：iPhone 刚性固定在夹爪上，通过一次性视觉对齐标定 `T_cam→tcp`。用户在 clutch 脱开状态下，同时观察真实夹爪尖端和 AR ghost 末端执行器，手动对齐后按下标定按钮记录当前相对变换。

**需要实现**：
- 标定模式 UI：显示参考标记（真实夹爪尖端 vs AR ghost 末端）
- 标定按钮：捕获当前 `T_cam→tcp`
- 标定结果持久化（UserDefaults 或文件）
- 重新标定入口

**UI 元素**：
- 设置面板中的「标定」入口
- 标定模式下的引导覆盖层：
  - 十字线标记 TCP 目标位置
  - 文字提示「移动设备使标记与夹爪尖端对齐，然后按下标定按钮」
- 标定完成确认提示 + 偏移量显示

**技术要点**：
- `T_cam→tcp` 是一个固定的 `simd_float4x4`，表示相机坐标系到工具中心点的刚体变换
- 标定后每帧计算：`p_t = T_cam_t × T_cam→tcp`
- 需要 clutch 脱开时才能标定（依赖功能 3）

**依赖**：功能 3 (Clutch)，功能 6 (Ghost 渲染，至少需要末端执行器的可视化)

---

### 功能 3：Clutch 机制 (软件离合器)

**论文描述 (§3.3)**：软件离合器控制 iPhone 运动与虚拟末端执行器的耦合/解耦。Engage 时，iPhone 位姿直接驱动 ghost 末端执行器；Disengage 时，ghost 冻结在最后位姿，用户可重新定位设备或从不同角度检查 ghost。

**需要实现**：
- Clutch 状态管理（engaged/disengaged 布尔值）
- 切换按钮 UI
- 脱开时冻结 ghost 位姿（存储最后一帧的 `p_t`）
- 接合时恢复实时追踪

**UI 元素**：
- 浮动按钮或长按手势切换 clutch
- 状态指示：engaged = 绿色锁图标，disengaged = 红色解锁图标
- 脱开时 ghost 添加脉冲动画提示「已冻结」

**技术要点**：
- 状态变量：`@Published var clutchEngaged: Bool = true`
- 脱开时：停止更新 ghost transform，但继续运行 ARKit（pose 数据仍在采集）
- 标定流程要求 clutch 脱开

**依赖**：无（纯状态管理 + UI）

---

### 功能 4：可行性反馈视觉指示器

**论文描述 (§3.3)**：当任何可行性条件被违反时，ghost 材质变红并触发触觉振动。当所有条件满足时，ghost 显示机器人模型的原始纹理。

**需要实现**：
- Ghost 材质动态切换系统（正常纹理 ↔ 红色半透明）
- 可行性状态使用 `OptionSet` bitmask 建模，支持多种违规并发：
  ```swift
  struct ViolationType: OptionSet {
      static let reachability = ViolationType(rawValue: 1 << 0)
      static let jointRate    = ViolationType(rawValue: 1 << 1)
      static let collision    = ViolationType(rawValue: 1 << 2)
  }
  // violations.isEmpty == feasible
  ```
- 多违规并发时的 UI 着色优先级：collision > jointRate > reachability（按危险程度降序）
- 多违规并发时的触觉优先级：同 UI，取最高优先级的触觉模式
- 状态变化时的平滑过渡动画

**UI 元素**：
- Ghost 机器人材质颜色变化（绿/正常 → 红色）
- 屏幕边缘的可行性状态标签（显示具体违反类型）
- 可选：底部状态栏显示各约束的实时数值（IK 残差、关节速率比、碰撞距离）

**技术要点**：
- SceneKit 材质属性动态修改：`SCNMaterial.diffuse.contents = UIColor.red.withAlphaComponent(0.5)`
- 需要在 60Hz 主循环中高效更新，避免帧率下降
- 颜色过渡可用 `SCNAction` 或直接设值

**依赖**：功能 6 (Ghost 渲染)，功能 8 (可行性评估管线)

---

### 功能 5：触觉反馈 (CoreHaptics)

**论文描述 (§3.3)**：设备在约束违反时通过 CoreHaptics 触发振动。

**需要实现**：
- CoreHaptics 引擎初始化与管理
- 不同违反类型对应不同触觉模式
- 触觉反馈的节流控制（避免持续高频振动）

**技术要点**：
- `CHHapticEngine` 生命周期管理（前后台切换时暂停/恢复）
- 触觉模式设计：
  - 可达性违反：短促单次振动
  - 关节速率违反：快速连续振动
  - 碰撞违反：强烈持续振动
- 节流策略：例如最小间隔 100ms，避免连续帧的重复触发

**依赖**：功能 8 (可行性评估管线)

---

## 阶段二：逻辑层

### 功能 6：URDF 解析与机器人模型加载 + Ghost 渲染

**论文描述 (§3.3)**：目标机器人的运动学模型 M 从 URDF 解析获得。FK 将关节角 q_t 映射到每个连杆的 3D 位姿，SceneKit 将整个手臂渲染为半透明 AR ghost 覆盖在实时相机画面上。

**需要实现**：

#### 6a. URDF 解析器
- XML 解析 URDF 文件，提取：
  - 连杆 (link)：名称、视觉网格路径、碰撞几何
  - 关节 (joint)：类型（revolute/prismatic/fixed）、父子连杆、轴向、限位（位置、速度、力矩）
  - 关节间的变换矩阵（origin xyz rpy）
- 构建运动学树结构
- 支持网格文件加载（STL/DAE/OBJ）

#### 6b. 正向运动学 (FK)
- 根据关节角度计算每个连杆在世界坐标系中的变换
- 从基座沿运动学链逐级传递变换矩阵

#### 6c. SceneKit Ghost 渲染
- 每个连杆创建对应的 `SCNNode`
- 加载连杆的视觉网格（STL → SCNGeometry）
- 设置半透明材质
- 将 FK 结果实时应用到各 SCNNode 的 transform
- 将 ghost 场景覆盖到 ARKit 相机画面上

**技术要点**：
- URDF 是 XML 格式，使用 `Foundation.XMLParser`（SAX 流式解析）。注意：`XMLDocument` 在 iOS 上不可用，仅 macOS 支持
- STL 文件需要自定义解析器或通过 Model I/O (`MDLAsset`) 加载
- SceneKit 与 ARKit 共用同一个坐标系（通过 `ARSCNView` 或手动同步）
- 当前项目用的是 RealityKit (`ARView`)，需要评估是否改用 `ARSCNView`，或在 RealityKit 场景中嵌入 SceneKit 内容
- **重要架构决策**：RealityKit vs ARSCNView — 当前 `ARSessionManager` 使用 RealityKit 的 `ARView`，但论文描述的 ghost 渲染和碰撞检测更适合 SceneKit。可能需要迁移到 `ARSCNView`，或采用混合方案

**依赖**：无（核心基础组件）

---

### 功能 7：逆运动学求解器 (Damped Least-Squares IK)

**论文描述 (§3.3)**：阻尼最小二乘 (DLS) IK 求解器，运行在目标机器人的运动学模型上，计算关节角 q_t。单一求解器实现同时支持 6-DoF 和 7-DoF 机械臂；对于 7-DoF 臂，DLS 自然返回冗余解中的最小范数解。

**需要实现**：
- 雅可比矩阵 (Jacobian) 计算
- DLS 求解：`Δq = J^T (J J^T + λ²I)^{-1} e`
- 迭代求解循环（设定收敛阈值和最大迭代次数）
- 关节限位约束裁剪
- 热启动：使用上一帧的 q 作为初始值

**技术要点**：
- 雅可比矩阵：6×N（N = 关节数），通过 FK 中间结果计算各关节轴和位置
- 阻尼因子 λ：在奇异点附近防止解发散，典型值 0.01-0.1
- 收敛判据：位置误差 < 1mm 且姿态误差 < 1°，或最大 50 次迭代
- 需要在 60Hz 内完成计算（~16ms 预算，IK 应控制在 1-2ms）
- Swift 可利用 Accelerate 框架做矩阵运算加速

**依赖**：功能 6a (URDF 解析，需要运动学链)，功能 6b (FK，需要雅可比计算)

---

### 功能 8：可行性评估管线

**论文描述 (§3.2)**：每帧评估三个条件——可达性（IK 解存在）、关节速率可容许性（max|q̇_i|/q̇_max ≤ 1）、无碰撞。

**需要实现**：

#### 8a. 可达性检测
- IK 求解后检查残差：如果收敛，则可达
- 输出：布尔值 + IK 残差数值

#### 8b. 关节速率可容许性
- 从连续帧的 IK 解估计关节速度：`q̇_i = (q_t,i - q_{t-1,i}) / Δt`
- 与 URDF 中的 `velocity` 限制比较
- 输出：布尔值 + 速率比值（max_i |q̇_i| / q̇_max_i）

#### 8c. 碰撞检测
- **自碰撞**：机器人各连杆之间的碰撞检测（排除相邻连杆对）
- **环境碰撞**：机器人连杆与 LiDAR 场景网格的碰撞检测
- 使用 SceneKit 物理引擎：
  - 每个连杆设置简化碰撞形状（长连杆用胶囊、关节用球、末端用盒子或凸包）
  - 设为 kinematic body
  - 碰撞 mask 排除相邻连杆对
  - 场景网格设为 static collision geometry

#### 8d. 综合可行性状态
- 三个条件全部满足 → feasible
- 任一违反 → infeasible（记录具体类型）
- 输出可行性元数据：`(ik_residual, joint_rate_ratio, collision_flag, overall_feasible)`

**技术要点**：
- 碰撞检测是性能瓶颈，需要优化：
  - 简化碰撞几何（不用视觉网格做碰撞）
  - SceneKit 的 `SCNPhysicsWorld.contactTest(with:options:)` 可做即时碰撞查询
- 关节速率计算需要低通滤波以避免噪声导致的假阳性
- 需要存储上一帧的 q 值用于速率计算

**依赖**：功能 6 (URDF + FK)，功能 7 (IK)，功能 9 (LiDAR 场景网格)

---

### 功能 9：LiDAR 场景网格重建

**论文描述 (§3.3)**：ARKit 的 LiDAR 重建提供场景网格 E，用于环境碰撞检测。精度达到厘米级。

**需要实现**：
- 启用 ARKit 的 `ARWorldTrackingConfiguration.sceneReconstruction = .mesh`
- 获取 `ARMeshAnchor` 数据
- 将 ARKit mesh 转换为 SceneKit 碰撞几何
- 实时更新场景网格

**技术要点**：
- 需要 iPhone 带 LiDAR 的型号（iPhone 12 Pro 及以上）
- ARKit mesh 以 `ARMeshAnchor` 形式提供，包含顶点、法线、面索引
- 需要将 mesh 转换为 `SCNGeometry` 并设为 static physics body
- mesh 更新频率低于帧率，不需要每帧重建
- 注意：当前 `ARSessionManager.swift:62` 的 `ARWorldTrackingConfiguration` 未启用 scene reconstruction

**⚠️ 能力探测与降级策略**：
- 启动时必须检查 `ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)`
- **有 LiDAR**：启用完整环境碰撞检测（自碰撞 + 环境碰撞）
- **无 LiDAR**：降级为仅自碰撞检测模式，环境碰撞检测禁用
  - UI 提示用户：「当前设备不支持 LiDAR，环境碰撞检测已禁用」
  - 可行性评估中的碰撞条件仅检查自碰撞
  - 不阻止使用，但在状态栏显示降级标识
- 降级策略需在功能 8（可行性评估管线）中同步体现

**依赖**：无

---

## 阶段三：通信联调

### 功能 10：Per-Frame 可行性元数据记录

**论文描述 (§3.3, §3.4)**：每帧可行性状态（IK 残差、关节速率比、碰撞标志）作为元数据与原始位姿和图像数据一起记录。FeasibleCap 不修改记录数据——原始位姿和图像流忠实保留，可行性状态存储为可选的下游使用元数据。

**需要实现**：
- 定义可行性元数据的数据结构
- 将元数据附加到现有的 FramePacket 二进制格式
- 更新 `NetworkClient` 的数据发送协议
- 更新 rapid_driver 端的数据接收和 MCAP 写入

**技术要点**：

- **⚠️ 协议兼容性警告**：不能在现有帧格式中间插入字段——旧版 rapid_driver 会错误解析 JPEG 起始位置，导致整包损坏。必须使用新的 `messageType` 实现版本区分。

- 协议版本方案（基于 `NetworkClient.swift` 现有 header 结构）：
  ```
  现有 header: [4B payload_len] [1B msg_type] [3B reserved]
  现有 msg_type: 0x01 = metadata(JSON), 0x02 = frame(binary)

  新增 msg_type: 0x03 = frame_with_feasibility(binary)
  ```

- 新消息类型 0x03 的 payload 格式：
  ```
  [4B JPEG_size] [64B transform] [8B device_ts] [8B wall_ts]
  [JPEG_data]
  [--- 可行性数据追加在 JPEG 之后 ---]
  [4B feasibility_block_size: uint32]  // 自描述长度，便于未来扩展
  [4B ik_residual: float32]
  [4B joint_rate_ratio: float32]
  [1B violation_bitmask: uint8]  // bit0=reachability, bit1=joint_rate, bit2=collision
  [1B overall_feasible: uint8]   // 0=infeasible, 1=feasible
  [2B reserved]
  [N×4B joint_angles: float32[N]]  // 可选：IK 求解的关节角
  ```
  将可行性数据放在 JPEG 之后（而非之间），这样旧版接收端如果误收 0x03 消息，可以直接丢弃而不会错解 JPEG。

- **协议协商流程**：
  1. iPhone 端在连接建立后发送 metadata 消息时，增加 `"protocol_version": 2` 字段
  2. rapid_driver 检查版本号：支持 v2 则正常解析 0x03 消息；不支持则忽略 0x03（或回复降级提示）
  3. iPhone 端收到降级提示后，回退到 0x02 消息类型（不发送可行性数据）
  4. 未收到降级提示 = 协商成功，后续帧使用 0x03

- 需要与 rapid_driver 端协调：
  - 新增 0x03 消息类型的解析逻辑
  - MCAP 中新增 `/feasibility` topic 存储可行性元数据
  - 向后兼容：rapid_driver 必须同时支持 0x02 和 0x03

**依赖**：功能 8 (可行性评估)，rapid_driver 端更新

---

### 功能 11：回放进度同步与状态显示

**论文描述 (§3.4)**：iPhone app 显示回放进度用于监控。

**当前状态**：已有基本的回放状态轮询 (`GET /replay/status`) 和进度条 UI。

**待增强**：
- 回放时在 AR 视图中显示实时机器人状态（可选，如果通信带宽允许）
- 回放失败时的详细错误信息展示
- 回放速度调节

**依赖**：现有 HTTP API 基础

---

## 开发优先级与建议路线图

```
阶段一 UI 层（可并行）
├── 功能 3: Clutch 机制           ← 纯状态管理，最简单，先做
├── 功能 1: 虚拟基座放置          ← ARKit raycast，独立
├── 功能 5: 触觉反馈引擎          ← CoreHaptics 初始化，可提前封装
└── 功能 4: 可行性视觉指示器 UI    ← 预留接口，等 ghost 渲染后接入

阶段二 逻辑层（需串行）
├── 功能 9: LiDAR 场景网格         ← 独立，可与 6 并行
├── 功能 6: URDF 解析 + FK + Ghost  ← 核心，最大工作量
│   ├── 6a: URDF 解析器
│   ├── 6b: FK 引擎
│   └── 6c: SceneKit Ghost 渲染
├── 功能 7: IK 求解器              ← 依赖功能 6
├── 功能 8: 可行性评估管线          ← 依赖 6, 7, 9
└── 功能 2: Camera-to-TCP 标定     ← 依赖 3, 6（需要 ghost 可视化）

阶段三 通信联调
├── 功能 10: 可行性元数据记录       ← 依赖功能 8 + rapid_driver 协调
└── 功能 11: 回放增强              ← 已有基础，增量开发
```

---

## 关键架构决策（开发前需讨论）

### 决策 1：RealityKit vs ARSCNView

当前项目基于 RealityKit (`ARView`)，但 ghost 渲染和碰撞检测更适合 SceneKit (`ARSCNView`)。

| 方案 | 优点 | 缺点 |
|------|------|------|
| **迁移到 ARSCNView** | 天然支持 SceneKit physics、碰撞检测、材质动态切换 | 波及范围大（见下文） |
| **RealityKit + SceneKit 混合** | 保留现有代码 | 两个渲染引擎同步复杂，性能开销 |
| **纯 RealityKit** | 现代 API、性能好 | RealityKit 的 physics/碰撞 API 有限，自定义网格加载困难 |

**迁移波及范围评估**（如选择 ARSCNView）：
- `ARSessionManager.swift`：核心重写，当前继承 `UIViewController` 并持有 `ARView`（RealityKit），需改为持有 `ARSCNView`。涉及：AR session setup（:38）、guide entity 渲染（:70 起的 RealityKit entity 创建）、delegate 回调
- `ContentView.swift`：`ARViewContainer`（:32）使用 `UIViewControllerRepresentable` 包装 ViewController，内部引用 `ARView` 类型需改为 `ARSCNView`；AR guide 渲染逻辑如果在 ContentView 中有耦合也需调整
- AR 引导标记（坐标轴、原点球）：当前用 RealityKit 的 `ModelEntity` + `SimpleMaterial` 实现，需改为 `SCNNode` + `SCNGeometry`

**建议**：迁移到 ARSCNView。虽然波及范围比单独重写 ARSessionManager 更大，但 Ghost 渲染和碰撞检测是项目核心功能，SceneKit 在这方面明显更灵活。建议在阶段二功能 6 开始前完成迁移。

### 决策 2：URDF 解析实现方式

| 方案 | 优点 | 缺点 |
|------|------|------|
| **自行实现 Swift URDF 解析器** | 完全控制、无外部依赖 | 开发量大 |
| **嵌入 Python/C++ 库** | 功能完整 | 跨语言调用复杂 |
| **简化模型格式 (自定义 JSON)** | 快速实现 | 不通用，每换一个机器人需重新转换 |

**建议**：自行实现 Swift URDF 解析器。URDF 的核心结构不复杂（link + joint + origin），工作量可控。

### 决策 3：IK 求解器实现

| 方案 | 优点 | 缺点 |
|------|------|------|
| **纯 Swift DLS 实现** | 无依赖、可优化 | 需要手写矩阵运算 |
| **Swift + Accelerate 框架** | 利用硬件加速 | API 较底层 |
| **Metal Compute Shader** | GPU 加速 | 过度工程 |

**建议**：纯 Swift + Accelerate 框架的 DLS 实现。6-7 DoF 的 IK 计算量不大，CPU 足够。

---

## 工作量估算

| 功能 | 复杂度 | 备注 |
|------|--------|------|
| 功能 1: 基座放置 | 🟢 低 | ARKit raycast 成熟 API |
| 功能 2: TCP 标定 | 🟡 中 | UI + 变换数学 |
| 功能 3: Clutch | 🟢 低 | 纯状态管理 |
| 功能 4: 视觉指示器 | 🟢 低 | SceneKit 材质切换 |
| 功能 5: 触觉反馈 | 🟢 低 | CoreHaptics API |
| 功能 6: URDF + FK + Ghost | 🔴 高 | 最大工作量，含解析器/FK/渲染 |
| 功能 7: IK 求解器 | 🔴 高 | 数学密集 |
| 功能 8: 可行性管线 | 🟡 中 | 集成 6+7+9 的输出 |
| 功能 9: LiDAR 网格 | 🟡 中 | ARKit API + 格式转换 |
| 功能 10: 元数据记录 | 🟡 中 | 协议扩展 + 双端协调 |
| 功能 11: 回放增强 | 🟢 低 | 增量改进 |

---

## 已知风险：测试基线

当前项目的单元测试（`iPhoneVIOTests.swift:31`）与实际模型字段（`RecordingController.swift:14`）已存在不一致，说明现有测试无法作为可靠的回归门槛。

**建议**：在开始功能开发前，先修复或删除失效测试，确保 `xcodebuild test` 在改动前是绿色的。每个功能完成后应补充对应的单元测试（至少覆盖 URDF 解析、FK/IK 数学计算、可行性判定逻辑），作为阶段交付的验收条件。

---

## 开放问题决议记录

以下问题需在开发前确认，当前给出默认方案：

### Q1：新旧 rapid_driver 二进制协议是否并存？

**默认方案：是，必须并存。** iPhone 端通过协议协商（metadata 消息中的 `protocol_version` 字段）自动选择消息类型。旧版 rapid_driver 收到 0x02 正常工作；新版支持 0x02 + 0x03。详见功能 10 的协议协商流程。

### Q2：多违规并发时 UI 与 haptic 的优先级规则？

**默认方案：按危险程度降序取最高优先级。** collision > jointRate > reachability。
- UI 着色：ghost 整体使用最高优先级违规对应的颜色（当前均为红色；未来若扩展为分级色彩则按此优先级）
- 触觉模式：播放最高优先级违规对应的 haptic pattern
- 状态标签：显示所有并发违规类型（bitmask 展开为文字列表）

### Q3：非 LiDAR 机型是否作为正式支持目标？

**默认方案：支持，但明确为降级模式。** 非 LiDAR 设备可正常使用除环境碰撞检测外的所有功能（可达性、关节速率、自碰撞均不依赖 LiDAR）。UI 中显示降级提示。详见功能 9 的降级策略。
