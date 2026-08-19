/** ArkTS-safe JSON field helpers used by platform adapters. */

export function jsonString(data: Record<string, Object>, key: string, fallback: string = ''): string {
  const value = data[key]
  return typeof value === 'string' ? value : fallback
}

export function jsonNumber(data: Record<string, Object>, key: string, fallback: number = 0): number {
  const value = data[key]
  return typeof value === 'number' ? value : fallback
}

export function jsonBoolean(data: Record<string, Object>, key: string, fallback: boolean = false): boolean {
  const value = data[key]
  return typeof value === 'boolean' ? value : fallback
}

export function jsonObject(data: Record<string, Object>, key: string): Record<string, Object> {
  const value = data[key]
  if (value !== null && typeof value === 'object' && !Array.isArray(value)) {
    return value as Record<string, Object>
  }
  return {}
}

export function jsonArray(data: Record<string, Object>, key: string): Record<string, Object>[] {
  const value = data[key]
  return Array.isArray(value) ? value as Record<string, Object>[] : []
}

export function jsonStringArray(data: Record<string, Object>, key: string): string[] {
  const value = data[key]
  if (!Array.isArray(value)) return []
  const result: string[] = []
  for (let i = 0; i < value.length; i++) {
    if (typeof value[i] === 'string') result.push(value[i] as string)
  }
  return result
}

export function boundedExternalText(value: string, maxLength: number): string {
  if (value.length <= maxLength) return value
  return value.substring(0, maxLength) + '\n\n[内容过长，已在 Serein 中截断；请打开原链接查看完整内容]'
}

export function stringId(value: Object | undefined): string {
  if (typeof value === 'string') return value
  if (typeof value === 'number') return value.toString()
  return ''
}

export function encodeQuery(params: Record<string, string>): string {
  const keys = Object.keys(params)
  const pairs: string[] = []
  for (let i = 0; i < keys.length; i++) {
    const key = keys[i]
    if (params[key] !== '') {
      pairs.push(encodeURIComponent(key) + '=' + encodeURIComponent(params[key]))
    }
  }
  return pairs.join('&')
}

