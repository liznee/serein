/**
 * TerminalSessionPersistence — 终端会话持久化（存储/恢复）
 *
 * 从 TerminalPage 提取的独立模块，负责：
 * - 保存/恢复会话内容（行数据、状态）
 * - 载入/保存命令历史
 */
import PrefStore from '../store/PrefStore'
import { TerminalSession, type TerminalLineData, type LineKind } from './TerminalSession'
import type { AnsiSegment } from './AnsiParser'

export class TerminalSessionPersistence {
  /** 从 PrefStore 载入该项目的持久化命令历史 */
  static async loadHistoryInto(proj: string, s: TerminalSession): Promise<void> {
    try {
      const h = await PrefStore.loadCmdHistory(proj)
      if (h.length > 0) {
        s.commandHistory = h
      }
    } catch (e) {
      console.error('serein: 载入命令历史失败: ' + (e as Error).message)
    }
  }

  /** 保存指定项目的命令历史 */
  static async saveHistory(proj: string, s: TerminalSession | undefined): Promise<void> {
    if (s === undefined) return
    try {
      await PrefStore.saveCmdHistory(proj, s.commandHistory.concat([]))
    } catch (e) {
      console.error('serein: 保存命令历史失败: ' + (e as Error).message)
    }
  }

  /** 持久化当前项目的终端会话（行内容 + 状态） */
  static async saveCurrentSession(proj: string, s: TerminalSession | undefined): Promise<void> {
    if (s === undefined) return
    try {
      // 注意：调用方应在同步阶段预先调用 s.endThinkingIfActive()，
      // 避免在 fire-and-forget 异步路径中变异 session._thinkingLineIdx
      // 导致页面销毁后 session 被复用时 thinking 状态丢失。
      const linesData: Record<string, Object>[] = []
      for (let i = 0; i < s.lines.length; i++) {
        const ln = s.lines[i]
        const lineObj: Record<string, Object> = {} as Record<string, Object>
        lineObj['segments'] = JSON.stringify(ln.segments)
        lineObj['timestamp'] = ln.timestamp
        lineObj['isPrompt'] = ln.isPrompt
        lineObj['kind'] = ln.kind
        lineObj['blockId'] = ln.blockId
        lineObj['text'] = ln.text
        lineObj['choiceGroupId'] = ln.choiceGroupId
        linesData.push(lineObj)
      }
      const data: Record<string, Object> = {} as Record<string, Object>
      data['lines'] = linesData
      data['hasBanner'] = s.hasBanner
      data['bannerProject'] = s.bannerProject
      data['currentBlockId'] = s.currentBlockId
      data['blockSeq'] = s.blockSeq
      await PrefStore.saveTermSession(proj, data)
    } catch (e) {
      console.error('serein: 保存会话失败: ' + (e as Error).message)
    }
  }

  /** 从持久化恢复会话，返回 true 表示有数据被恢复 */
  static async restoreCurrentSession(proj: string, s: TerminalSession | undefined): Promise<boolean> {
    if (s === undefined) return false
    try {
      const saved = await PrefStore.loadTermSession(proj)
      if (saved === null) return false
      const linesRaw = saved['lines'] as Record<string, Object>[] | undefined
      if (!linesRaw || linesRaw.length === 0) return false
      const restoredLines: TerminalLineData[] = []
      for (let i = 0; i < linesRaw.length; i++) {
        const r = linesRaw[i]
        let segments = (r['segments'] as string) ?? '[]'
        let parsedSegs: AnsiSegment[]
        try { parsedSegs = JSON.parse(segments) } catch (_e) { continue }
        if (!Array.isArray(parsedSegs)) continue
        const text = (r['text'] as string) ?? ''
        const thinkingDuration = (r['thinkingDuration'] as number) ?? 0
        // 旧版本把每轮分隔线和内部思考块写入了会话历史。新版使用一个
        // 实时的英文状态提示，因此恢复历史时顺便清除这些纯 UI 遗留项。
        if (text === '───────────────────' || thinkingDuration !== 0) continue
        restoredLines.push({
          segments: parsedSegs,
          timestamp: (r['timestamp'] as number) ?? Date.now(),
          isPrompt: (r['isPrompt'] as boolean) ?? false,
          kind: (r['kind'] as LineKind) ?? 'normal',
          blockId: (r['blockId'] as number) ?? -1,
          text: text,
selected: (r['selected'] as boolean) ?? false,
locked: (r['locked'] as boolean) ?? false,
thinkingDuration: 0,
choiceGroupId: (r['choiceGroupId'] as number) ?? -1,
        })
      }
      if (restoredLines.length > 0) {
        s.lines = restoredLines
        s.hasBanner = (saved['hasBanner'] as boolean) ?? false
        s.bannerProject = (saved['bannerProject'] as string) ?? ''
        const restoredBlockId = (saved['currentBlockId'] as number) ?? -1
        if (restoredBlockId >= 0) {
          s.currentBlockId = restoredBlockId
        }
        const restoredBlockSeq = (saved['blockSeq'] as number) ?? 0
        s.blockSeq = restoredBlockSeq > s.blockSeq ? restoredBlockSeq : s.blockSeq
        await PrefStore.clearTermSession(proj)
        return true
      }
    } catch (e) {
      console.error('serein: 恢复会话失败: ' + (e as Error).message)
    }
    return false
  }

  /** 清空持久化的终端会话数据（不恢复，直接清除） */
  static async clearSessionData(proj: string): Promise<void> {
    try {
      await PrefStore.clearTermSession(proj)
    } catch (_e) { /* non-fatal */ }
  }
}
