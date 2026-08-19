/**
 * HistoryPanel — 历史命令模糊搜索浮层组件
 * v4: 远程历史只读标记 + Theme 取色 + ForEach key 防重复
 */
import { currentTheme } from './TerminalTheme'

@Component
export struct HistoryPanel {
  @Prop historyList: string[] = []
  @Prop remoteHistory: string[] = []
  @Prop remoteLoading: boolean = false
  @Prop remoteError: string = ''
  onPick?: (cmd: string) => void
  @State searchQuery: string = ''

  private totalCount(): number {
    return this.historyList.length + this.remoteHistory.length
  }

  /** 合并本地 + 远程历史，过滤。本地按最近使用先显示，远程反转后追加（API 返回最旧在前）*/
  private get combinedList(): HistoryEntry[] {
    const q = this.searchQuery.toLowerCase().trim()
    const out: HistoryEntry[] = []
    // 本地历史（最近使用在前）
    for (let i = 0; i < this.historyList.length; i++) {
      const cmd = this.historyList[i]
      if (q === '' || cmd.toLowerCase().indexOf(q) >= 0) {
        out.push({ text: cmd, remote: false })
      }
    }
    // 远程历史（反转使最新在前）
    for (let i = this.remoteHistory.length - 1; i >= 0; i--) {
      const cmd = this.remoteHistory[i]
      if (q === '' || cmd.toLowerCase().indexOf(q) >= 0) {
        out.push({ text: cmd, remote: true })
      }
    }
    return out
  }

  build() {
    Column() {
      // 标题
      Row() {
        Text('历史搜索').fontSize(11).fontColor(currentTheme().textDim).layoutWeight(1)
        Text(this.totalCount() + ' 条').fontSize(10).fontColor(currentTheme().textDim).margin({ right: 12 })
      }.width('100%').padding({ left: 16, right: 16, top: 6, bottom: 2 })
      // 搜索输入框
      TextInput({ text: this.searchQuery, placeholder: '模糊搜索历史命令…' })
        .fontSize(12).fontColor(currentTheme().text).placeholderColor(currentTheme().textDim)
        .fontFamily('monospace').height(32)
        .padding({ left: 12, right: 12 })
        .backgroundColor('rgba(255,255,255,0.04)')
        .borderRadius(6).border({ width: 1, color: 'rgba(140,144,159,0.08)' })
        .margin({ left: 12, right: 12, bottom: 4 })
        .onChange((v: string) => { this.searchQuery = v })

      // 远程历史加载中
      if (this.remoteLoading) {
        Row() {
          LoadingProgress().width(12).height(12).color(currentTheme().accent)
          Text('  加载远程历史…').fontSize(11).fontColor(currentTheme().textDim).fontFamily('monospace')
        }.width('100%').padding({ left: 16, top: 4, bottom: 4 })
      }

      // 远程历史加载失败
      if (this.remoteError !== '') {
        Text('[远程错误] ' + this.remoteError)
          .fontSize(11).fontColor(currentTheme().error).fontFamily('monospace')
          .padding({ left: 16, top: 4, bottom: 4 })
      }

      // 列表
      if (this.combinedList.length === 0 && !this.remoteLoading) {
        Text(this.searchQuery.trim() !== '' ? '  (无匹配)' : '  (无历史记录)')
          .fontSize(12).fontColor(currentTheme().textDim).padding({ left: 16, bottom: 8 })
      }
      ForEach(this.combinedList, (entry: HistoryEntry, idx: number) => {
        Row() {
          Text(entry.text).fontSize(12)
            .fontColor(entry.remote ? currentTheme().textDim : currentTheme().text)
            .fontFamily('monospace').maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
          if (entry.remote) {
            Text(' 只读').fontSize(9).fontColor(currentTheme().textDim).fontFamily('monospace').opacity(0.6)
          }
        }
        .width('100%').padding({ left: 16, right: 16, top: 8, bottom: 8 })
        .opacity(entry.remote ? 0.7 : 1.0)
        .onClick(() => {
          if (this.onPick && !entry.remote) this.onPick(entry.text)
          // 远程历史仅展示不可点击填入
        })
      }, (entry: HistoryEntry, idx: number) => (entry.remote ? 'r' : 'l') + '_' + idx.toString() + '_' + entry.text)
    }
    .width('100%').backgroundColor(currentTheme().panel).borderRadius({ topLeft: 8, topRight: 8 })
    .border({ width: { top: 1, left: 0, right: 0, bottom: 0 }, color: currentTheme().divider })
    .padding({ top: 4, bottom: 4 }).shadow({ radius: 8, color: 'rgba(0,0,0,0.25)', offsetY: -2 })
  }
}

interface HistoryEntry {
  text: string
  remote: boolean
}
