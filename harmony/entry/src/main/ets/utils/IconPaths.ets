// ===== 图标路径 — 基于 Lucide/Feather 专业图标库 =====
// 四个操作按钮图标形状完全不同，视觉鲜明可辨

export class IconPaths {
  // ======== 状态指示灯 — radar/activity 波形 ========
  // 从左到右递增振幅的竖线波形
  static readonly STATUS_BAR1: string = 'M3 18 L3 14'
  static readonly STATUS_BAR2: string = 'M8 18 L8 10'
  static readonly STATUS_BAR3: string = 'M13 18 L13 5'
  static readonly STATUS_BAR4: string = 'M18 18 L18 8'
  static readonly STATUS_FILL: string = 'M3 19 L3 16'

  // ======== 刷新 — 顺时针双弧箭头 ========
  static readonly REFRESH_ARROW: string = 'M21 12 A9 9 0 0 0 9.6 3.6 M21 4 L21 12 L13 12'
  // 下半弧（较小）
  static readonly REFRESH_ARROW2: string = 'M3 12 A9 9 0 0 0 14.4 20.4 M3 20 L3 12 L11 12'

  // ======== 历史 — 钟面 + 反向环绕箭头 ========
  static readonly HISTORY_CLOCK: string = 'M12 3 A9 9 0 1 1 12 21 A9 9 0 1 1 12 3'
  static readonly HISTORY_HAND: string = 'M12 7 L12 12'
  static readonly HISTORY_MHAND: string = 'M12 12 L16 16'
  // 反向环绕小箭头（左下）
  static readonly HISTORY_REV_ARC: string = 'M2 14 A10 10 0 0 1 10 4'
  static readonly HISTORY_REV_HEAD: string = 'M1 16 L5 12 L3 18'

  // ======== 设置 — 三条水平滑块（sliders） ========
  static readonly SLIDER1_LINE: string = 'M2 6 L22 6'
  static readonly SLIDER1_DOT: string = 'M13 3 A3 3 0 1 1 13 9 A3 3 0 1 1 13 3'
  static readonly SLIDER2_LINE: string = 'M2 12 L22 12'
  static readonly SLIDER2_DOT: string = 'M7 9 A3 3 0 1 1 7 15 A3 3 0 1 1 7 9'
  static readonly SLIDER3_LINE: string = 'M2 18 L22 18'
  static readonly SLIDER3_DOT: string = 'M17 15 A3 3 0 1 1 17 21 A3 3 0 1 1 17 15'

  // ======== 返回箭头 ========
  static readonly BACK: string = 'M15 18 L9 12 L15 6'

  // ======== 关闭 X ========
  static readonly CLOSE: string = 'M6 6 L18 18 M18 6 L6 18'

  // ======== 电脑显示器 ========
  static readonly MONITOR: string = 'M2 4 L22 4 L22 15 L2 15 Z'
  static readonly MONITOR_STAND: string = 'M12 15 L12 20'
  static readonly MONITOR_BASE: string = 'M8 20 L16 20'

  // ======== 垃圾桶 ========
  static readonly TRASH_LID: string = 'M5 5 L19 5'
  static readonly TRASH_BODY: string = 'M6 5 L6 19 A1 1 0 0 0 7 20 L17 20 A1 1 0 0 0 18 19 L18 5'
  static readonly TRASH_LINES: string = 'M9 8 L9 17 M15 8 L15 17'
  static readonly TRASH_HANDLE: string = 'M9 3 L9 5 M15 3 L15 5'

  // ======== 底部导航图标 (from nav-icons.html) ========
  // Projects — 2x2 grid of rounded squares
  static readonly NAV_PROJECTS: string =
    'M3 3 L10 3 L10 10 L3 10 Z M14 3 L21 3 L21 10 L14 10 Z M3 14 L10 14 L10 21 L3 21 Z M14 14 L21 14 L21 21 L14 21 Z'
  static readonly NAV_PROJECTS_RX: number = 1.5  // 圆角

  // Terminal — chevron + cursor
  static readonly NAV_TERMINAL_CHEVRON: string = 'M5 7 L11 12 L5 17'
  static readonly NAV_TERMINAL_CURSOR: string = 'M13 17 L19 17'

  // Stats — 3 bar chart, ascending
  static readonly NAV_STATS_1: string = 'M3 13 L7 13 L7 21 L3 21 Z'
  static readonly NAV_STATS_2: string = 'M10 8 L14 8 L14 21 L10 21 Z'
  static readonly NAV_STATS_3: string = 'M17 3 L21 3 L21 21 L17 21 Z'
  static readonly NAV_STATS_RX: number = 1

  // Settings — gear: center circle + 8 spokes
  static readonly NAV_SETTINGS_CIRCLE: string = 'M12 9 A3 3 0 1 0 12 15 A3 3 0 1 0 12 9'
  static readonly NAV_SETTINGS_SPOKES: string =
    'M12 2 L12 5 M12 19 L12 22 M2 12 L5 12 M19 12 L22 12 M4.9 4.9 L7 7 M17 17 L19.1 19.1 M4.9 19.1 L7 17 M17 7 L19.1 4.9'

  // ======== 扫码图标 (from scan-small.html) ========
  static readonly SCAN_CORNER_TL: string = 'M2 5 L2 2 L5 2'
  static readonly SCAN_CORNER_TR: string = 'M22 5 L22 2 L19 2'
  static readonly SCAN_CORNER_BR: string = 'M22 19 L22 22 L19 22'
  static readonly SCAN_CORNER_BL: string = 'M2 19 L2 22 L5 22'
  static readonly SCAN_LINE: string = 'M6 12 L18 12'
}
