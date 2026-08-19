/**
 * TerminalHeaderBar — 终端页面顶部操作栏组件
 *
 * 从 TerminalPage.ets 的 build() 中提取，减少主文件行数。
 * 包含菜单按钮、项目名、Verbosity 切换、字号调整、复制按钮。
 * 不含 Relay 状态指示器（用户要求在终端输出中以消息呈现）。
 */
import { currentTheme } from './TerminalTheme'
import { agentDisplayName } from '../store/PrefStore'

@Component
export struct TerminalHeaderBar {
  @Prop terminalProject: string = ''
  @Prop agentType: string = 'claude'
  @Prop runtimeMode: string = 'cli'
  @Prop hasLineSelection: boolean = false

  onMenuClick?: () => void
  onFontSmaller?: () => void
  onFontLarger?: () => void
  onCopyAll?: () => void

  build() {
    Row() {
      // 菜单按钮 ☰ 图标
      Row() {
        Text('☰')
          .fontSize(16).fontColor(currentTheme().text).fontWeight(500)
      }
      .width(36).height(36).borderRadius(8)
      .backgroundColor('rgba(140,144,159,0.08)')
      .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
      .margin({ right: 8 })
      .onClick(() => { if (this.onMenuClick) this.onMenuClick() })

      // 项目名称
      Text(this.terminalProject.toUpperCase())
        .fontSize(12).fontColor(currentTheme().text).fontFamily('monospace').fontWeight(600)

      Text(this.runtimeMode === 'desktop' ? 'Codex Desktop' : agentDisplayName(this.agentType))
        .fontSize(9).fontColor('#D97757').fontFamily('monospace')
        .padding({ left: 6, right: 6, top: 3, bottom: 3 })
        .backgroundColor('rgba(217,119,87,0.08)')
        .border({ width: 1, color: 'rgba(217,119,87,0.20)' }).borderRadius(9999)
        .margin({ left: 8 })

      Blank()

      // 复制与字号：三个独立点击区之间留出 8vp，避免小文字相邻导致误触。
      Row() {
        Row() {
          Text(this.hasLineSelection ? '复制行' : '复制')
            .fontSize(11)
            .fontColor(this.hasLineSelection ? '#D97757' : currentTheme().textDim)
        }
        .width(this.hasLineSelection ? 52 : 44).height(32).borderRadius(8)
        .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
        .backgroundColor(this.hasLineSelection ? 'rgba(217,119,87,0.10)' : 'rgba(140,144,159,0.08)')
        .onClick(() => { if (this.onCopyAll) this.onCopyAll() })

        Row() {
          Text('Aa-').fontSize(12).fontColor(currentTheme().textDim)
        }
        .width(40).height(32).borderRadius(8)
        .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
        .backgroundColor('rgba(140,144,159,0.08)')
        .margin({ left: 8 })
        .onClick(() => { if (this.onFontSmaller) this.onFontSmaller() })

        Row() {
          Text('Aa+').fontSize(12).fontColor(currentTheme().textDim)
        }
        .width(40).height(32).borderRadius(8)
        .justifyContent(FlexAlign.Center).alignItems(VerticalAlign.Center)
        .backgroundColor('rgba(140,144,159,0.08)')
        .margin({ left: 8 })
        .onClick(() => { if (this.onFontLarger) this.onFontLarger() })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 44, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .backgroundColor(currentTheme().panel).backdropBlur(4)
    .border({ width: { bottom: 1 }, color: currentTheme().divider })
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.TOP])
  }
}
