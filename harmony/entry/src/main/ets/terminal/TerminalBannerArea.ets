/**
 * TerminalBannerArea — 终端页面横幅区域组件
 *
 * 从 TerminalPage.ets 的 build() 中提取，减少主文件行数。
 * 包含项目下拉选择器、搜索状态横幅、批量模式选择器、HTTP 警告、WS 重连状态。
 */
import { WSConnectionState } from '../api/WebSocketClient'
import { currentTheme } from './TerminalTheme'

type AgentMode = 'claude' | 'codex' | 'desktop'

@Component
export struct TerminalBannerArea {
  @Prop showProjectPicker: boolean = false
  @Prop projectList: string[] = []
  @Prop terminalProject: string = ''
  @Prop searchTerm: string = ''
  @Prop renderLineCount: number = 0
  @Prop batchMode: boolean = false
  @Prop batchProjects: string[] = []
  @Prop backendIsHttp: boolean = false
  @Prop wsState: WSConnectionState = WSConnectionState.DISCONNECTED
  @Prop projectAgentModes: Map<string, string> = new Map()
  @State expandedProject: string = ''

  /** 用户明确选定启动方式后才调用；点项目名只展开选项。 */
  onLaunchProject?: (name: string, mode: AgentMode) => void
  onClearSearch?: () => void
  onCloseBatch?: () => void
  onBatchToggleProject?: (name: string) => void
  onReconnect?: () => void

  private modeLabel(mode: AgentMode): string {
    if (mode === 'claude') return 'Claude CLI'
    if (mode === 'codex') return 'Codex CLI'
    return 'Codex 桌面'
  }

  @Builder
  launchOption(name: string, mode: AgentMode) {
    Text(this.modeLabel(mode))
      .fontSize(10).fontWeight(600).fontColor('#E1E2E8').fontFamily('monospace')
      .padding({ left: 9, right: 9, top: 7, bottom: 7 })
      .backgroundColor('rgba(217,119,87,0.10)')
      .border({ width: 1, color: 'rgba(217,119,87,0.22)' })
      .borderRadius(7)
      .onClick(() => {
        if (this.onLaunchProject) this.onLaunchProject(name, mode)
        this.expandedProject = ''
      })
  }

  build() {
    Column() {
      // 项目下拉
      if (this.showProjectPicker) {
        Column() {
          ForEach(this.projectList, (name: string) => {
            Column() {
              Row() {
                Text(name).fontSize(12)
                  .fontColor(name === this.terminalProject ? currentTheme().accent : currentTheme().system)
                  .fontFamily('monospace').layoutWeight(1)
                Text(this.expandedProject === name ? '收起' : '选择方式')
                  .fontSize(10).fontColor('#D99A83').fontFamily('monospace')
              }
              .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
              .backgroundColor(name === this.terminalProject ? 'rgba(217,119,87,0.06)' : 'rgba(0,0,0,0)')
              .onClick(() => { this.expandedProject = this.expandedProject === name ? '' : name })

              if (this.expandedProject === name) {
                Row() {
                  this.launchOption(name, 'claude')
                  this.launchOption(name, 'codex')
                  this.launchOption(name, 'desktop')
                }
                .width('100%').justifyContent(FlexAlign.SpaceBetween)
                .padding({ left: 16, right: 16, bottom: 10 })
              }
            }.width('100%')
          }, (name: string) => name)
        }.width('100%').backgroundColor(currentTheme().panel).backdropBlur(8)
          .border({ width: { bottom: 1 }, color: currentTheme().divider })
      }

      // 搜索状态横幅
      if (this.searchTerm !== '') {
        Row() {
          Text('🔍 ' + this.searchTerm + ' · ' + this.renderLineCount + ' 行').fontSize(11)
            .fontColor(currentTheme().diffMeta).fontFamily('monospace').layoutWeight(1)
          Text('✕ 清除').fontSize(11).fontColor(currentTheme().textDim)
            .onClick(() => { if (this.onClearSearch) this.onClearSearch() })
        }
        .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .backgroundColor('rgba(251,191,36,0.08)')
        .border({ width: { bottom: 1 }, color: 'rgba(251,191,36,0.20)' })
      }

      // #10 批量模式项目选择器
      if (this.batchMode) {
        Column() {
          Row() {
            Text('批量模式').fontSize(12).fontColor(currentTheme().tool).fontFamily('monospace').fontWeight(700)
            Blank()
            Text('✕ 取消').fontSize(11).fontColor(currentTheme().textDim)
              .onClick(() => { if (this.onCloseBatch) this.onCloseBatch() })
          }.width('100%').padding({ left: 12, right: 12, top: 6, bottom: 4 })
          Text('选择项目（点击切换） → 输入命令 → 提交').fontSize(10)
            .fontColor(currentTheme().textDim).fontFamily('monospace')
            .width('100%').padding({ left: 12, bottom: 4 })
          Row() {
            ForEach(this.projectList, (name: string) => {
              Row() {
                Text(this.batchProjects.indexOf(name) >= 0 ? '☑ ' : '☐ ')
                  .fontSize(12)
                  .fontColor(this.batchProjects.indexOf(name) >= 0 ? currentTheme().success : currentTheme().textDim)
                Text(name)
                  .fontSize(12)
                  .fontColor(this.batchProjects.indexOf(name) >= 0 ? currentTheme().success : currentTheme().text)
                  .fontFamily('monospace')
              }
              .padding({ left: 8, right: 8, top: 4, bottom: 4 })
              .border({ width: 1, color: this.batchProjects.indexOf(name) >= 0 ? currentTheme().success : currentTheme().divider })
              .borderRadius(6)
              .margin({ right: 6 })
              .onClick(() => {
                if (this.onBatchToggleProject) this.onBatchToggleProject(name)
              })
            }, (name: string) => name)
          }.width('100%').padding({ left: 12, right: 12, top: 2, bottom: 6 })
          if (this.batchProjects.length > 0) {
            Text('已选: ' + this.batchProjects.join(', ')).fontSize(10).fontColor(currentTheme().result)
              .fontFamily('monospace').width('100%').padding({ left: 12, bottom: 6 })
          }
        }
        .width('100%')
        .backgroundColor('rgba(217,119,87,0.04)')
        .border({ width: { bottom: 1 }, color: 'rgba(217,119,87,0.20)' })
      }

      // HTTP 不安全连接警告横幅
      if (this.backendIsHttp) {
        Row() {
          Text('[不安全] HTTP 连接 — 通信不加密，token 和命令可能被截获')
            .fontSize(11).fontColor('#b53333').fontFamily('monospace').layoutWeight(1)
        }
        .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .backgroundColor('rgba(255,75,75,0.10)')
        .border({ width: { bottom: 1 }, color: 'rgba(255,75,75,0.25)' })
      }

      // WS 重连状态横幅
      if (this.wsState === WSConnectionState.RECONNECTING) {
        Row() {
          Text('重连中...').fontSize(11).fontColor('#b53333').fontFamily('monospace').layoutWeight(1)
          Text('点击手动重连').fontSize(11).fontColor(currentTheme().textDim)
            .onClick(() => { if (this.onReconnect) this.onReconnect() })
        }
        .width('100%').padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .backgroundColor('rgba(255,75,75,0.10)')
        .border({ width: { bottom: 1 }, color: 'rgba(255,75,75,0.25)' })
      }
    }.width('100%')
  }
}
