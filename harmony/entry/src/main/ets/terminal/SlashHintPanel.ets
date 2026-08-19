/**
 * SlashHintPanel — / 命令补全建议浮层组件
 * 提取自 TerminalPage.ets 的 slashHintPanel @Builder
 */
import { currentTheme } from './TerminalTheme'
import type { SlashCommandInfo } from './SlashCommands'

@Component
export struct SlashHintPanel {
  @Prop slashHints: SlashCommandInfo[] = []
  @Prop slashHintOverflow: boolean = false
  onPick?: (cmd: string) => void

  private panelHeight(): number {
    const rowCount = this.slashHints.length + (this.slashHintOverflow ? 1 : 0)
    return Math.min(244, Math.max(48, rowCount * 42 + 8))
  }

  build() {
    List() {
      ForEach(this.slashHints, (item: SlashCommandInfo) => {
        ListItem() {
          Row() {
            Text(item.cmd).fontSize(13).fontColor(item.builtin ? currentTheme().accent : currentTheme().tool).fontFamily('monospace')
            Text('  ' + item.desc).fontSize(12).fontColor(currentTheme().textDim).maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            Text(item.builtin ? 'CMD' : 'skill').fontSize(9).fontColor(currentTheme().textDim).margin({ left: 6 })
          }
          .width('100%').padding({ left: 16, right: 16, top: 9, bottom: 9 })
          .onClick(() => { if (this.onPick) this.onPick(item.cmd) })
        }
      }, (item: SlashCommandInfo) => item.cmd)
      if (this.slashHintOverflow) {
        ListItem() {
          Text('… 更多命令，继续输入字母过滤').fontSize(11).fontColor(currentTheme().textDim)
            .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 8 })
        }
      }
    }
    .width('100%').height(this.panelHeight())
    .scrollBar(BarState.Auto).edgeEffect(EdgeEffect.Spring)
    .backgroundColor('#0F1319').borderRadius({ topLeft: 8, topRight: 8 })
    .border({ width: { top: 1, left: 0, right: 0, bottom: 0 }, color: 'rgba(30,37,48,0.80)' })
    .padding({ top: 4, bottom: 4 }).shadow({ radius: 8, color: 'rgba(0,0,0,0.25)', offsetY: -2 })
  }
}
