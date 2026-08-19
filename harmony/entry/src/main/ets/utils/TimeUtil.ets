// ===== 时间格式化工具 =====
// 处理后端 RFC3339 UTC 时间字符串

const MINUTE_MS = 60 * 1000
const HOUR_MS = 60 * MINUTE_MS
const DAY_MS = 24 * HOUR_MS

/**
 * 将 ISO 时间字符串转为相对时间文案
 * - <1 分钟 → "刚刚"
 * - <60 分钟 → "N 分钟前"
 * - <24 小时 → "N 小时前"
 * - <7 天 → "N 天前"
 * - 否则 → 本地格式化
 */
export function formatRelative(iso: string): string {
  const date = new Date(iso)
  if (isNaN(date.getTime())) {
    return iso // 解析失败，原样返回
  }

  const now = Date.now()
  const diff = now - date.getTime()

  if (diff < MINUTE_MS) {
    return '刚刚'
  }
  if (diff < HOUR_MS) {
    return Math.floor(diff / MINUTE_MS) + ' 分钟前'
  }
  if (diff < DAY_MS) {
    return Math.floor(diff / HOUR_MS) + ' 小时前'
  }
  if (diff < 7 * DAY_MS) {
    return Math.floor(diff / DAY_MS) + ' 天前'
  }

  return formatLocal(iso)
}

/**
 * 将 ISO 时间字符串转为本地格式化 "YYYY-MM-DD HH:mm:ss"
 */
export function formatLocal(iso: string): string {
  const date = new Date(iso)
  if (isNaN(date.getTime())) {
    return iso
  }

  const y = date.getFullYear()
  const mo = pad2(date.getMonth() + 1)
  const d = pad2(date.getDate())
  const h = pad2(date.getHours())
  const mi = pad2(date.getMinutes())
  const s = pad2(date.getSeconds())

  return y + '-' + mo + '-' + d + ' ' + h + ':' + mi + ':' + s
}

/** 补零到 2 位 */
function pad2(n: number): string {
  return n < 10 ? '0' + n : '' + n
}

/**
 * 判断是否已超时（当前时间 > timeout_at）
 */
export function isTimedOut(timeoutAt: string): boolean {
  const date = new Date(timeoutAt)
  if (isNaN(date.getTime())) {
    return false
  }
  return Date.now() > date.getTime()
}
