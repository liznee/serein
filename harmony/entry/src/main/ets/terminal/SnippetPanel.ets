/**
 * SnippetPanel — 片段库浮层组件
 * 提取自 TerminalPage.ets 的 snippetPanel @Builder
 * v2: 添加搜索过滤功能
 */
import { currentTheme } from './TerminalTheme'
import type { Snippet } from '../store/PrefStore'

@Component
export struct SnippetPanel {
  @Prop snippets: Snippet[] = []
  onPick?: (cmd: string) => void
  onAdd?: () => void
  onDelete?: (name: string) => void
  onClose?: () => void
  @State searchQuery: string = ''

  /** 按搜索词过滤片段（name + command 模糊匹配） */
  private get filtered(): Snippet[] {
    const q = this.searchQuery.toLowerCase().trim()
    if (q === '') return this.snippets
    const out: Snippet[] = []
    for (let i = 0; i < this.snippets.length; i++) {
      const sp = this.snippets[i]
      if (sp.name.toLowerCase().indexOf(q) >= 0 || sp.command.toLowerCase().indexOf(q) >= 0) {
        out.push(sp)
      }
    }
    return out
  }

  build() {
    Column() {
      Row() {
        Text('片段库').fontSize(11).fontColor(currentTheme().textDim).layoutWeight(1)
        Text('+ 存当前输入').fontSize(11).fontColor(currentTheme().accent)
          .onClick(() => { if (this.onAdd) this.onAdd() })
        Text('  ✕').fontSize(11).fontColor(currentTheme().textDim)
          .onClick(() => { if (this.onClose) this.onClose() })
      }.width('100%').padding({ left: 16, right: 16, top: 6, bottom: 4 })
      // 搜索输入框
      TextInput({ text: this.searchQuery, placeholder: '搜索片段…' })
        .fontSize(12).fontColor(currentTheme().text).placeholderColor(currentTheme().textDim)
        .fontFamily('monospace').height(32)
        .padding({ left: 12, right: 12 })
        .backgroundColor('rgba(255,255,255,0.04)')
        .borderRadius(6).border({ width: 1, color: 'rgba(140,144,159,0.08)' })
        .margin({ left: 12, right: 12, bottom: 4 })
        .onChange((v: string) => { this.searchQuery = v })
      if (this.filtered.length === 0) {
        Text(this.searchQuery.trim() !== '' ? '  (无匹配)' : '  (空 · 输入命令后点 + 存当前输入)')
          .fontSize(12).fontColor(currentTheme().textDim).padding({ left: 16, bottom: 8 })
      }
      ForEach(this.filtered, (sp: Snippet, idx: number) => {
        Row() {
          Text(sp.name).fontSize(11).fontColor(currentTheme().textDim).maxLines(1).width(70)
          Text(sp.command).fontSize(12).fontColor(currentTheme().text).fontFamily('monospace').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          Text(' ✕').fontSize(11).fontColor(currentTheme().textDim).margin({ left: 6 })
            .hitTestBehavior(HitTestMode.Block)
            .onClick(() => { if (this.onDelete) this.onDelete(sp.name) })
        }
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .onClick(() => { if (this.onPick) this.onPick(sp.command) })
      }, (sp: Snippet, idx: number) => idx.toString() + '_' + sp.name + '|' + sp.command)
    }
    .width('100%').backgroundColor(currentTheme().panel).borderRadius({ topLeft: 8, topRight: 8 })
    .border({ width: { top: 1 }, color: currentTheme().divider })
    .padding({ top: 4, bottom: 4 }).shadow({ radius: 8, color: 'rgba(0,0,0,0.25)', offsetY: -2 })
  }
}
