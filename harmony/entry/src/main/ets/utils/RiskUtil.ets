import type { RiskLevel, Decision } from '../api/types'

// ===== 风险/决策 → UI 映射工具 =====
// 遵循 ui-ux-pro-max: 颜色仅用于语义强化,必须搭配图标/文字
// 色彩体系: terracotta 强调 + 暖绿 success + 暖橙 warn + 暖红 danger

/** 风险等级 → 文字颜色资源名 */
export function riskColor(level: RiskLevel): ResourceColor {
  switch (level) {
    case 'red':
      return $r('app.color.risk_red_text')
    case 'yellow':
      return $r('app.color.risk_yellow_text')
    case 'green':
      return $r('app.color.risk_green_text')
    default:
      return $r('app.color.text_secondary')
  }
}

/** 风险等级 → 背景色资源名 */
export function riskBgColor(level: RiskLevel): ResourceColor {
  switch (level) {
    case 'red':
      return $r('app.color.risk_red_bg')
    case 'yellow':
      return $r('app.color.risk_yellow_bg')
    case 'green':
      return $r('app.color.risk_green_bg')
    default:
      return $r('app.color.surface_secondary')
  }
}

/** 风险等级 → 中文文案 */
export function riskLabel(level: RiskLevel): string {
  switch (level) {
    case 'red':
      return '高危'
    case 'yellow':
      return '中危'
    case 'green':
      return '低危'
    default:
      return '未知'
  }
}

/** 决策 → 颜色资源名 */
export function decisionColor(decision: Decision): ResourceColor {
  switch (decision) {
    case 'allow':
      return $r('app.color.success')
    case 'deny':
      return $r('app.color.danger')
    case 'timeout':
      return $r('app.color.warning')
    case 'pending':
    default:
      return $r('app.color.text_tertiary')
  }
}

/** 决策 → 边框色（25% 透明度，保持品牌克制） */
export function decisionBorderColor(decision: Decision): string {
  switch (decision) {
    case 'allow':
      return 'rgba(23,163,74,0.25)'
    case 'deny':
      return 'rgba(181,51,51,0.25)'
    case 'timeout':
      return 'rgba(217,119,48,0.25)'
    case 'pending':
    default:
      return 'rgba(140,144,159,0.25)'
  }
}

/** 决策 → 中文文案 */
export function decisionLabel(decision: Decision): string {
  switch (decision) {
    case 'allow':
      return '已同意'
    case 'deny':
      return '已拒绝'
    case 'timeout':
      return '已超时'
    case 'pending':
    default:
      return '待审批'
  }
}
