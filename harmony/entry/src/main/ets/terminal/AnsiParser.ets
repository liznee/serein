/**
 * ANSI 转义序列解析器
 * 将带 ANSI SGR 颜色/样式码的字符串解析为结构化 Segment 数组
 *
 * 支持的 SGR 码: 0(重置) 1(粗体) 4(下划线) 30-37/90-97(前景) 40-47/100-107(背景)
 * 不处理: CSI 光标移动/清屏等
 */

/** ANSI 渲染段 */
export interface AnsiSegment {
  text: string
  fg: string
  bg: string
  bold: boolean
  underline: boolean
}

/** ANSI 16 色调色板（珊瑚色系统一：蓝→珊瑚，紫→浅珊瑚） */
const ANSI_FG: Record<number, string> = {
  30: '#1A1A1A',  31: '#FF6B6B',  32: '#B98376',  33: '#B06F61',
  34: '#C58A78',  35: '#B69A92',  36: '#A98F89',  37: '#E1E2E8',
  90: '#4A4A4A',  91: '#FF8A8A',  92: '#C29A8F',  93: '#BC8172',
  94: '#D3A08F',  95: '#C8AAA2',  96: '#B9A09A',  97: '#FFFFFF',
}

const ANSI_BG: Record<number, string> = {
  40: '#1A1A1A',  41: '#FF6B6B',  42: '#694B45',  43: '#67423B',
  44: '#6D4E46',  45: '#62504D',  46: '#584B49',  47: '#E1E2E8',
  100: '#4A4A4A', 101: '#FF8A8A', 102: '#765B54', 103: '#724C43',
  104: '#78594F', 105: '#6E5B56', 106: '#665754', 107: '#FFFFFF',
}

/** 创建默认 AnsiSegment */
function defaultSegment(text: string): AnsiSegment {
  return { text: text, fg: '#E1E2E8', bg: '', bold: false, underline: false }
}

/**
 * 解析 ANSI SGR 转义序列字符串
 */
export function parseAnsi(raw: string): AnsiSegment[] {
  const result: AnsiSegment[] = []
  if (raw.length === 0) {
    return result
  }

  let currentFg: string = '#E1E2E8'
  let currentBg: string = ''
  let currentBold: boolean = false
  let currentUnderline: boolean = false

  let pos: number = 0
  const len: number = raw.length

  while (pos < len) {
    const escIdx: number = raw.indexOf('\x1b', pos)
    if (escIdx === -1) {
      const text: string = raw.substring(pos)
      if (text.length > 0) {
        result.push({
          text: text,
          fg: currentFg,
          bg: currentBg,
          bold: currentBold,
          underline: currentUnderline
        })
      }
      break
    }

    if (escIdx > pos) {
      const text: string = raw.substring(pos, escIdx)
      result.push({
        text: text,
        fg: currentFg,
        bg: currentBg,
        bold: currentBold,
        underline: currentUnderline
      })
    }

    pos = escIdx + 1
    if (pos >= len) {
      break
    }

    const nextChar: string = raw.charAt(pos)
    if (nextChar === '[') {
      // CSI 序列: ESC [ params... finalByte
      pos++
      let paramStr: string = ''
      while (pos < len) {
        const c: number = raw.charCodeAt(pos)
        if (c >= 0x40 && c <= 0x7E) {
          const finalByte: string = raw.charAt(pos)
          pos++
          if (finalByte === 'm') {
            // 应用 SGR 参数
            const updated: AnsiSegment = applySgrParams(
              paramStr, currentFg, currentBg, currentBold, currentUnderline
            )
            currentFg = updated.fg
            currentBg = updated.bg
            currentBold = updated.bold
            currentUnderline = updated.underline
          }
          break
        } else {
          paramStr += raw.charAt(pos)
          pos++
        }
      }
    } else if (nextChar === ']' || nextChar === 'P' || nextChar === '_' || nextChar === 'X' || nextChar === '^') {
      // OSC/DCS/APC/SOS/PM 字符串序列: 跳过直到 ST (\x1b\) 或 BEL (\x07)
      pos++
      while (pos < len) {
        const c = raw.charCodeAt(pos)
        if (c === 0x1b && pos + 1 < len && raw.charCodeAt(pos + 1) === 0x5c) {
          pos += 2 // ST \x1b\
          break
        }
        if (c === 0x07) { pos++; break } // BEL 终止符 (OSC 常见)
        pos++
      }
    } else if (nextChar >= '\x20' && nextChar <= '\x2F') {
      // ESC 中间字节序列: ESC I F (如 ESC ( B 选字符集, ESC ) B)
      // 中间字节 0x20-0x2F 后跟终结字节 0x40-0x7E
      pos++
      while (pos < len) {
        const c = raw.charCodeAt(pos)
        if (c >= 0x40 && c <= 0x7E) { pos++; break }
        // 安全兜底：非预期字符也跳出避免死循环
        if (c < 0x20 || c >= 0x80) { break }
        pos++
      }
    } else if (nextChar >= '\x30' && nextChar <= '\x7E') {
      // 单字符 ESC 序列: ESC F (如 ESC 7/8 DECSC, ESC = DECPAM, ESC > DECPNM)
      pos++
    } else {
      // 兜底：未知的 ESC 后续字节，跳过避免死循环
      pos++
    }
  }

  return result
}

/** 应用 SGR 参数 */
function applySgrParams(
  paramStr: string,
  fg: string, bg: string, bold: boolean, underline: boolean
): AnsiSegment {
  if (paramStr.length === 0) {
    return { text: '', fg: '#E1E2E8', bg: '', bold: false, underline: false }
  }

  let newFg: string = fg
  let newBg: string = bg
  let newBold: boolean = bold
  let newUnderline: boolean = underline

  const params: string[] = paramStr.split(';')
  for (let i: number = 0; i < params.length; i++) {
    const n: number = parseInt(params[i])
    if (isNaN(n)) {
      continue
    }
    if (n === 0) {
      newFg = '#E1E2E8'
      newBg = ''
      newBold = false
      newUnderline = false
    } else if (n === 1) {
      newBold = true
    } else if (n === 4) {
      newUnderline = true
    } else if (n === 38 && i + 1 < params.length) {
      // 256色 truecolor 前景: 38;5;N 或 38;2;R;G;B
      const sub: number = parseInt(params[i + 1])
      if (sub === 5 && i + 2 < params.length) {
        newFg = map256Color(parseInt(params[i + 2]))
        i += 2
      } else if (sub === 2 && i + 4 < params.length) {
        newFg = remapTruecolor(parseInt(params[i + 2]), parseInt(params[i + 3]), parseInt(params[i + 4]))
        i += 4
      }
    } else if (n === 48 && i + 1 < params.length) {
      // 256色 truecolor 背景: 48;5;N 或 48;2;R;G;B
      const sub: number = parseInt(params[i + 1])
      if (sub === 5 && i + 2 < params.length) {
        newBg = map256Color(parseInt(params[i + 2]))
        i += 2
      } else if (sub === 2 && i + 4 < params.length) {
        newBg = remapTruecolor(parseInt(params[i + 2]), parseInt(params[i + 3]), parseInt(params[i + 4]))
        i += 4
      }
    } else if (n >= 30 && n <= 37) {
      const c: string | undefined = ANSI_FG[n]
      if (c !== undefined) {
        newFg = c
      }
    } else if (n >= 40 && n <= 47) {
      const c: string | undefined = ANSI_BG[n]
      if (c !== undefined) {
        newBg = c
      }
    } else if (n >= 90 && n <= 97) {
      const c: string | undefined = ANSI_FG[n]
      if (c !== undefined) {
        newFg = c
      }
    } else if (n >= 100 && n <= 107) {
      const c: string | undefined = ANSI_BG[n]
      if (c !== undefined) {
        newBg = c
      }
    }
  }
  return { text: '', fg: newFg, bg: newBg, bold: newBold, underline: newUnderline }
}

/** 256 色码中的高彩度工具色统一压到终端的玫瑰陶土色系。 */
function map256Color(n: number): string {
  // NaN 通过传入 Invalid ANSI 解析产生，n > 255 和 n < 0 都会返回 false（NaN > 255 === false），
  // 必须额外检查 isNaN，否则 NaN 通过守卫后进入 color256toHex 产生 '#undefined' 字符串。
  if (isNaN(n) || n < 0 || n > 255) return '#E1E2E8'
  if (n < 16) {
    const c: string | undefined = ANSI_FG[30 + (n % 8)]
    return c ?? '#E1E2E8'
  }
  if (n >= 232) return color256toHex(n)
  const n6: number = n - 16
  const ri: number = Math.floor(n6 / 36) % 6
  const gi: number = Math.floor(n6 / 6) % 6
  const bi: number = n6 % 6
  const val: number[] = [0, 95, 135, 175, 215, 255]
  return remapTruecolor(val[ri], val[gi], val[bi])
}

/** 模块级 toHex 辅助函数（提取为模块级避免每次调用重新创建闭包）*/
function toHex(x: number): string {
  return Math.max(0, Math.min(255, x)).toString(16).padStart(2, '0')
}

/** 256 色码转 RGB hex（非蓝紫色用真实颜色）*/
function color256toHex(n: number): string {
  if (n < 16) {
    const c: string | undefined = ANSI_FG[30 + (n % 8)]
    return c ?? '#E1E2E8'
  }
  if (n >= 232) {
    const v: number = 8 + (n - 232) * 10
    const hex: string = v.toString(16).padStart(2, '0')
    return '#' + hex + hex + hex
  }
  // 6x6x6 色立方体
  const n6: number = n - 16
  const r: number = Math.floor(n6 / 36) % 6
  const g: number = Math.floor(n6 / 6) % 6
  const b: number = n6 % 6
  const val: number[] = [0, 95, 135, 175, 215, 255]
  return '#' + toHex(val[r]) + toHex(val[g]) + toHex(val[b])
}

/** truecolor 中的绿、黄、蓝、紫和青统一为低饱和的终端辅助色。 */
function remapTruecolor(r: number, g: number, b: number): string {
  if (g > 90 && g > r * 1.12 && g > b * 1.05) return '#B98376'
  if (r > 110 && g > 80 && b < Math.min(r, g) * 0.78) return '#B06F61'
  if (b > 100 && b > r && b > g) return '#C58A78'
  if (r > 100 && b > 100 && g < Math.max(r, b) * 0.85) return '#B69A92'
  if (g > 100 && b > 100 && r < Math.max(g, b) * 0.82) return '#A98F89'
  return '#' + toHex(r) + toHex(g) + toHex(b)
}

/**
 * 剥离所有 ANSI 转义序列（包括 CSI/SGR/OSC/DCS 等），返回纯可见文本。
 * 用于 TerminalLineData.text 字段——该字段供长按复制到剪贴板时使用，
 * 若保留 SGR 逃逸序列会导致剪贴板内容包含 \x1b[...m 等不可见字符。
 */
export function stripAnsi(raw: string): string {
  // 依次过滤各类 ANSI 序列：
  // 1) OSC: ESC ] ... ST (BEL | ESC \ | \x9c)
  let result = raw.replace(/\x1b\][^\x1b\x07\x9c]*(?:\x1b\\|\x07|\x9c)/g, '')
  // 2) DCS: ESC P ... ST
  result = result.replace(/\x1bP[^\x1b\x9c]*(?:\x1b\\|\x9c)/g, '')
  // 3) APC: ESC _ ... ST
  result = result.replace(/\x1b_[^\x1b\x9c]*(?:\x1b\\|\x9c)/g, '')
  // 4) SOS/PM: ESC X / ESC ^ ... ST
  result = result.replace(/\x1b[X^][^\x1b\x9c]*(?:\x1b\\|\x9c)/g, '')
  // 5) CSI 序列 (含 SGR): ESC [ params... finalByte
  result = result.replace(/\x1b\[[\d;:]*[@-~]/g, '')
  result = result.replace(/\x9b[\d;:]*[@-~]/g, '')
  // 6) 单字符 ESC 序列
  result = result.replace(/\x1b[\x40-\x5a\x5c\x5e-\x7e]/g, '')
  return result
}
