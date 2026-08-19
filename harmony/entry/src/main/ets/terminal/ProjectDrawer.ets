/**
 * ProjectDrawer — 项目切换侧边栏抽屉组件
 * v2: 从 TerminalPage.ets 提取为独立组件，降低文件行数
 * v3: 点项目只展开启动方式；只有明确选择 Claude CLI / Codex CLI / Codex Desktop
 *     才会切入对应项目并启动该方式，避免“点项目即切终端”的歧义。
 */
import { currentTheme } from './TerminalTheme'
import { agentDisplayName } from '../store/PrefStore'

// agent 模式枚举：合并了 agentType (claude|codex) 和 runtimeMode (cli|desktop)
// 'claude'      → Claude Code CLI
// 'codex'       → Codex CLI
// 'desktop'     → Codex Desktop
type AgentMode = 'claude' | 'codex' | 'desktop'

@Component
export struct ProjectDrawer {
  @Prop projectList: string[] = []
  @Prop terminalProject: string = ''
  @Prop connected: boolean = false
  // 每个项目当前的 agent 模式，key=项目名，value=AgentMode
  @Prop projectAgentModes: Map<string, string> = new Map()
  // 当前展开选择器的项目名（null=无展开）
  @State expandedProject: string = ''
  /** 唯一的项目切换/启动入口：用户已明确选择了运行方式。 */
  onLaunchProject?: (projectName: string, mode: AgentMode) => void
  onClose?: () => void

  private getAgentMode(projectName: string): AgentMode {
    const mode = this.projectAgentModes.get(projectName)
    if (mode === 'desktop') return 'desktop'
    if (mode === 'codex') return 'codex'
    return 'claude'
  }

  private modeLabel(mode: AgentMode): string {
    switch (mode) {
      case 'claude': return 'Claude Code'
      case 'codex': return 'Codex CLI'
      case 'desktop': return 'Codex Desktop'
      default: return 'Claude Code'
    }
  }

  private modeDesc(mode: AgentMode): string {
    switch (mode) {
      case 'claude': return 'Anthropic 官方 CLI'
      case 'codex': return 'OpenAI Codex 命令行'
      case 'desktop': return 'Codex 桌面会话'
      default: return ''
    }
  }

  @Builder
  AgentModeOption(projectName: string, mode: AgentMode) {
    Row() {
      // 选中指示器：纯色小圆点（避免 Unicode）
      Column()
        .width(7).height(7).borderRadius(4)
        .backgroundColor(this.getAgentMode(projectName) === mode ? '#D97757' : 'transparent')
        .border({ width: 1, color: this.getAgentMode(projectName) === mode ? '#D97757' : 'rgba(140,144,159,0.25)' })
        .margin({ left: 2, right: 10 })

      Column() {
        Text(this.modeLabel(mode))
          .fontSize(12)
          .fontColor(this.getAgentMode(projectName) === mode ? '#D97757' : '#E1E2E8')
          .fontWeight(this.getAgentMode(projectName) === mode ? 600 : 400)
          .fontFamily('monospace')
        Text(this.modeDesc(mode))
          .fontSize(9)
          .fontColor('#686D78')
          .margin({ top: 2 })
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 12, right: 12, top: 9, bottom: 9 })
    .backgroundColor(this.getAgentMode(projectName) === mode ? 'rgba(217,119,87,0.08)' : 'transparent')
    .border({
      width: 1,
      color: this.getAgentMode(projectName) === mode ? 'rgba(217,119,87,0.22)' : 'rgba(140,144,159,0.10)'
    })
    .borderRadius(8)
    .margin({ bottom: 6 })
    .onClick(() => {
      if (this.onLaunchProject) this.onLaunchProject(projectName, mode)
      this.expandedProject = ''
      if (this.onClose) this.onClose()
    })
  }

  @Builder
  ProjectItem(name: string) {
    Column() {
      Row() {
        Text(name).fontSize(13)
          .fontColor(name === this.terminalProject ? '#D97757' : '#E1E2E8')
          .fontFamily('monospace').layoutWeight(1)

        // 只用于展示上一次使用的方式；卡片本身负责展开选择器。
        Row() {
          Text(this.modeLabel(this.getAgentMode(name)))
            .fontSize(9).fontColor(name === this.terminalProject ? '#D97757' : '#8C909F')
            .fontFamily('monospace')
        }
        .padding({ left: 8, right: 8, top: 3, bottom: 3 })
        .backgroundColor(name === this.terminalProject ? 'rgba(217,119,87,0.10)' : 'rgba(140,144,159,0.08)')
        .border({
          width: 1,
          color: name === this.terminalProject ? 'rgba(217,119,87,0.22)' : 'rgba(140,144,159,0.12)'
        })
        .borderRadius(9999)

        // 选中指示器（纯文字，避免 Unicode）
        if (name === this.terminalProject) {
          Text('current').fontSize(8).fontColor('#D97757').fontFamily('monospace').margin({ left: 6 })
        }
      }
      .width('100%')
      .padding({ left: 16, right: 16, top: 9, bottom: 9 })
      .backgroundColor(name === this.terminalProject ? 'rgba(217,119,87,0.06)' : 'transparent')
      .border({
        width: name === this.terminalProject ? 1 : 0,
        color: 'rgba(217,119,87,0.25)',
        style: BorderStyle.Solid
      })
      .borderRadius(10)
      .onClick(() => {
        // 项目名只负责展开，不会选中项目、更不会进入终端。
        this.expandedProject = this.expandedProject === name ? '' : name
      })

      // 展开的启动方式（选择其中一项才会切换项目并启动）
      if (this.expandedProject === name) {
        Column() {
          Text('选择启动方式').fontSize(10).fontColor('#8C909F').fontFamily('monospace')
            .width('100%').margin({ bottom: 7 })
          this.AgentModeOption(name, 'claude')
          this.AgentModeOption(name, 'codex')
          this.AgentModeOption(name, 'desktop')
        }
        .width('100%')
        .padding({ left: 16, right: 16, top: 6, bottom: 6 })
        .alignItems(HorizontalAlign.Start)
      }
    }
  }

  build() {
    Column() {
      Text('项目列表').fontSize(13).fontColor('#C2C6D6').fontFamily('monospace')
        .width('100%').padding({ left: 16, top: 52, bottom: 8 })

      ForEach(this.projectList, (name: string) => {
        this.ProjectItem(name)
      }, (name: string) => name)

      // 当前项目状态
      Row() {
        Column().width(6).height(6).borderRadius(3).backgroundColor(this.connected ? currentTheme().success : '#8C909F')
        Text(this.connected ? '  已连接' : '  未连接').fontSize(11).fontColor('#8C909F')
          .fontFamily('monospace')
      }
      .width('100%').padding({ left: 16, top: 20, bottom: 24 })
    }
    .width(260)
    .height('100%')
    .backgroundColor('#0A0E14')
    .border({ width: { right: 1 }, color: 'rgba(30,37,48,0.80)' })
    .alignItems(HorizontalAlign.Start)
    .position({ x: 0, y: 0 })
  }
}
