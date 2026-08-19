/**
 * 终端主题与字号。
 * 主珊瑚色只用于关键交互；普通工具过程和结果使用低饱和的玫瑰陶土色。
 */

export type ThemeName = 'dark' | 'light' | 'contrast'

export interface TerminalTheme {
  name: ThemeName
  bg: string
  panel: string
  text: string
  textDim: string
  prompt: string
  accent: string
  tool: string
  result: string
  success: string
  warning: string
  hint: string
  diffAdd: string
  diffDel: string
  diffHunk: string
  diffMeta: string
  error: string
  system: string
  divider: string
  diffAddBg: string
  diffDelBg: string
}

export const THEME_DARK: TerminalTheme = {
  name: 'dark',
  bg: '#0B0E12',
  panel: 'rgba(15,19,25,0.95)',
  text: '#E1E2E8',
  textDim: '#8C909F',
  prompt: '#E1E2E8',
  accent: '#D97757',
  tool: '#C58A78',
  result: '#B69A92',
  success: '#B98376',
  warning: '#B06F61',
  hint: '#A98F89',
  diffAdd: '#B98376',
  diffDel: '#b53333',
  diffHunk: '#C58A78',
  diffMeta: '#A98F89',
  error: '#b53333',
  system: '#6B7280',
  divider: 'rgba(30,37,48,0.80)',
  diffAddBg: 'rgba(185,131,118,0.10)',
  diffDelBg: 'rgba(181,51,51,0.10)'
}

export const THEME_LIGHT: TerminalTheme = {
  name: 'light',
  bg: '#F7F7F4',
  panel: 'rgba(255,255,255,0.92)',
  text: '#1A1C20',
  textDim: '#6B7280',
  prompt: '#1A1C20',
  accent: '#AD5B47',
  tool: '#9C5343',
  result: '#725D58',
  success: '#8F5549',
  warning: '#8D493D',
  hint: '#6F625F',
  diffAdd: '#8F5549',
  diffDel: '#B91C1C',
  diffHunk: '#9C5343',
  diffMeta: '#725D58',
  error: '#B91C1C',
  system: '#6B7280',
  divider: 'rgba(0,0,0,0.08)',
  diffAddBg: 'rgba(143,85,73,0.08)',
  diffDelBg: 'rgba(185,28,28,0.08)'
}

export const THEME_CONTRAST: TerminalTheme = {
  name: 'contrast',
  bg: '#000000',
  panel: 'rgba(0,0,0,0.95)',
  text: '#FFFFFF',
  textDim: '#C0C0C0',
  prompt: '#FFFFFF',
  accent: '#FF9B84',
  tool: '#FFB09C',
  result: '#E2B7AD',
  success: '#FF9B84',
  warning: '#FF806B',
  hint: '#D2B8B1',
  diffAdd: '#FF9B84',
  diffDel: '#FF4444',
  diffHunk: '#FFB09C',
  diffMeta: '#E2B7AD',
  error: '#FF5555',
  system: '#CCCCCC',
  divider: 'rgba(255,255,255,0.25)',
  diffAddBg: 'rgba(255,155,132,0.15)',
  diffDelBg: 'rgba(255,68,68,0.15)'
}

export function getTheme(name: ThemeName): TerminalTheme {
  if (name === 'light') return THEME_LIGHT
  if (name === 'contrast') return THEME_CONTRAST
  return THEME_DARK
}

export const DEFAULT_THEME: ThemeName = 'dark'
export const DEFAULT_FONT_SIZE: number = 13
export const MIN_FONT_SIZE: number = 11
export const MAX_FONT_SIZE: number = 22

let _current: TerminalTheme = THEME_DARK
let _fontSize: number = DEFAULT_FONT_SIZE
let _screenWidthVp: number = 360

export function currentTheme(): TerminalTheme { return _current }
export function currentFontSize(): number { return _fontSize }
export function screenWidthVp(): number { return _screenWidthVp }
export function setTheme(name: ThemeName): void { _current = getTheme(name) }
export function setFontSize(size: number): void {
  _fontSize = Math.max(MIN_FONT_SIZE, Math.min(MAX_FONT_SIZE, size))
}
export function setScreenWidthVp(widthVp: number): void {
  _screenWidthVp = Math.max(280, Math.min(600, widthVp))
}
