// ===== 图标系统 —— 液态玻璃风格统一符号集 =====
// 设计原则:
//   1. 统一选自 Dingbats / Miscellaneous Symbols 等文本符号区（非 emoji）
//   2. 所有符号视觉权重相近，在 18-24px 范围内呈现均衡
//   3. 导航/操作/状态三类符号各成体系，互不混用
//   4. 符号作为 Text 字符串使用，配合 DesignTokens.ICON 字号

export class Icons {
  // ═══ 导航 ═══
  /** 返回 — 左箭头 (← U+2190) */
  static readonly BACK = '←'
  /** 前进 — 右箭头 (→ U+2192) */
  static readonly FORWARD = '→'
  /** 关闭 — 粗乘号 (✕ U+2715) */
  static readonly CLOSE = '✕'
  /** 更多 — 水平省略号 (⋯ U+22EF) */
  static readonly MORE_H = '⋯'
  /** 更多 — 垂直省略号 (⋮ U+22EE) */
  static readonly MORE_V = '⋮'

  // ═══ 操作 ═══
  /** 刷新 — 顺时针圆箭头 (↻ U+21BB) */
  static readonly REFRESH = '↻'
  /** 设置 — 菱形点 (◈ U+25C8) 与 ◆ 同系 */
  static readonly SETTINGS = '◈'
  /** 确认/勾选 — 粗勾号 (✓ U+2713) */
  static readonly CHECK = '✓'
  /** 取消/错误 — 叉号 (✗ U+2717) */
  static readonly CROSS = '✗'
  /** 添加 — 加号 (+) */
  static readonly PLUS = '+'
  /** 清空/删除 — 带叉方块 (⌧ U+2327) */
  static readonly CLEAR = '⌧'
  /** 搜索 — 放大镜 (🔍 仅作备选，优先用系统图标) */
  static readonly SEARCH = '⌕'

  // ═══ 状态 ═══
  /** 已连接 — 实心圆 (● U+25CF) */
  static readonly DOT = '●'
  /** 未连接 — 空心圆 (○ U+25CB) */
  static readonly DOT_HOLLOW = '○'
  /** 警告 — 粗感叹号在三角内 (⚠ U+26A0, 文本形式加 U+FE0E 防 emoji) */
  static readonly WARNING = '⚠︎'
  /** 信息 — 圆圈 i (ⓘ U+24D8) */
  static readonly INFO = 'ⓘ'
  /** 空状态 — 长破折号 (— U+2014) */
  static readonly EMPTY = '—'

  // ═══ 内容/布局 ═══
  /** 列表/历史 — 三横线 (☰ U+2630) */
  static readonly LIST = '☰'
  /** 首页 — 房屋 (⌂ U+2302) */
  static readonly HOME = '⌂'
  /** 锁定 — 挂锁 (🔒 仅作备选) */
  static readonly LOCK = '⌖'
  /** 通知 — 空心铃铛 (U+1F514 备用，优先用文字"通知") */
  static readonly BELL = '🔔'
  /** 星标 — 实心星 (★ U+2605) */
  static readonly STAR = '★'
  /** 时钟 — (⌚ 仅作备选) */
  static readonly CLOCK = '◷'

  // ═══ 底部导航 ═══
  /** 终端/命令行 — 命令键符号 (⌘ U+2318) */
  static readonly TERMINAL = '⌘'
  /** 统计/仪表盘 — 菱形 (◆ U+25C6) */
  static readonly STATS = '◆'

  // ═══ 危险/控制 ═══
  /** 停止 — 停止键 (⏹ U+23F9) */
  static readonly STOP = '⏹'
  /** 禁止 — 禁止圈 (⊘ U+2298) */
  static readonly BAN = '⊘'
}
