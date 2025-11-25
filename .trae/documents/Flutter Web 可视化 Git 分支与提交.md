## 项目目标
- 构建一个本地运行的 Flutter Web 应用，输入本地 Git 仓库路径，展示所有分支与提交的可视化时间/拓扑图，清晰标示 merge 关系。

## 总体架构
- 前端：Flutter Web（Canvas/CustomPainter + InteractiveViewer）负责绘图与交互。
- 本地后端：Dart `shelf` 启动的轻量 REST 服务，读取指定路径的 Git 仓库，调用系统 `git` CLI（或库）解析数据并返回 JSON。
- 通讯协议：HTTP 本地通信（如 `http://localhost:8080`），前端传入 `repoPath`，后端返回统一结构的提交图数据。

## 后端实现
1. 技术栈与依赖
   - `shelf`、`shelf_router`、`shelf_cors`、`path`、`json_serializable`（可选）、`dart:io`。
   - 使用系统 `git`（Windows 需已安装 Git），通过 `Process.run` 调用。
2. 端点设计
   - `GET /health`：健康检查。
   - `POST /graph`：Body `{ repoPath: string }`，返回提交图 JSON（含分支、提交、关系）。
   - `POST /branches`：Body `{ repoPath }`，返回分支列表与 HEAD 指向。
3. 数据抽取
   - 列分支：`git -C <path> for-each-ref --format="%(refname:short)|%(objectname)" refs/heads`
   - 列提交（含父与装饰）：
     `git -C <path> log --all --date=iso --pretty=format:"%H|%P|%d|%s|%an|%ad" --topo-order`
   - 解析：
     - 提交节点：`hash`、`parents[]`、`refs[]`（从 `%d` 装饰中解析分支标签）、`author`、`date`、`subject`。
     - 边：`parents` 形成从子到父的有向边；父数量>1 表示 merge。
4. 安全与校验
   - 校验路径存在且包含 `.git` 目录。
   - 路径标准化（Windows 路径分隔符处理）。
   - 禁止执行除 `git` 之外的命令；对 `repoPath` 做白名单校验与长度限制。
5. 性能
   - 对大型仓库：分页/窗口化（限定返回最近 N 次提交，或 `since`/`until` 参数）。
   - 缓存最近一次解析结果（按 `repoPath` + 参数键）。

## 前端实现
1. 页面结构
   - 顶部工具栏：仓库路径输入框、加载按钮、分支过滤、显示范围（最近 N 次提交）。
   - 主画布：提交图可视化（缩放/平移），颜色区分分支，清晰的 merge 线。
   - 侧栏（可选）：分支列表、搜索提交（hash/消息/作者）。
2. 可视化技术
   - `CustomPainter` 在 `Canvas` 上绘制节点与边；
   - `InteractiveViewer` 提供缩放/拖拽；
   - 文本使用简短标签（首 7 字符的 hash、分支名），悬浮提示显示详情。
3. 交互
   - 点击节点：显示提交详情（hash、message、author、date、父提交）。
   - 勾选/高亮分支：仅显示或高亮该分支的路径。
   - 搜索定位：输入 hash/关键词定位并高亮。

## 数据模型与 JSON
- CommitNode
  - `id: string`（hash）
  - `parents: string[]`
  - `refs: string[]`（分支/标签指向）
  - `author: string`, `date: string`, `subject: string`
- Branch
  - `name: string`, `head: string`
- GraphResponse
  - `commits: CommitNode[]`, `branches: Branch[]`

## 布局与车道分配算法
- 基本策略（Git 图类似）：
  - 按 `--topo-order` 提交序列迭代，维护活动车道列表；
  - 为每个提交分配 `laneIndex`：
    - 新提交沿着其第一父继续当前车道；
    - 其余父开新车道并画 merge 线；
    - 无父（root）开新车道；
  - 当某车道在后续不再出现（无后继）时回收并复用；
- 绘制坐标：
  - x = `laneIndex * laneWidth`，y = `rowIndex * rowHeight`；
  - 节点：圆点/方块；边：贝塞尔/折线，避免交叉过密。

## 兼容与替代方案
- 纯浏览器方案（无需后端）：Chromium 系浏览器可用 File System Access API（`showDirectoryPicker`）选择文件夹并读取 `.git`。难点：在前端自行解析 Git 对象/refs，复杂度高；可作为后续增强。
- 当前优先方案：本地后端 + Git CLI，兼容性强、实现快。

## 性能与可扩展
- 虚拟化渲染：仅绘制视窗内节点（可维护可见行范围）。
- 折叠视图：按分支折叠、按时间段折叠。
- 渐进加载：默认加载最近 N 提交，可展开更多。

## 安全与鲁棒
- 输入消毒与长度限制；错误处理（路径不存在、非仓库、Git 未安装）。
- 超时与资源控制（进程调用超时、输出大小限制）。

## 验证方案
- 开发时：
  - 后端 `curl` 测试 `POST /graph` 与 `POST /branches`。
  - 前端本地运行，指向测试仓库（例如您当前的任意 Git 仓库）。
- 功能验收：
  - 显示所有分支与提交；merge 线正确；
  - 过滤/搜索/缩放工作正常；
  - 大仓库在分页/窗口化下流畅。

## 交付物
- Flutter Web 前端项目（`lib/` 源码）。
- Dart `shelf` 后端项目（或前端项目中的 `server/` 目录）。
- 运行说明：先启动后端，再启动前端；浏览器访问本地端口。

## 后续迭代
- 增加标签/远程分支显示；
- 增加 `git blame` 或文件变更热力图；
- 导出为 SVG/PNG；
- 支持纯前端读取（File System Access API）模式。

---
确认该方案后，我将开始创建项目骨架、后端端点与前端可视化，并提供可运行的本地预览。