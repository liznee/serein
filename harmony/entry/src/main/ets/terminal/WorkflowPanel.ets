/**
 * WorkflowPanel — 多步任务编排模板面板
 *
 * 预置常用多步操作模板（如"部署后端"=bump版本→编译→上传→重启），
 * 选择后自动按序执行各步骤。
 *
 * 模板数据存储在 PrefStore.ets（term_workflows key），
 * 用户可通过 SnippetPanel 类似方式管理自定义模板。
 */
import { currentTheme } from './TerminalTheme'
import { WorkflowTemplate, WorkflowStep } from '../store/PrefStore'
import PrefStore from '../store/PrefStore'

@Component
export struct WorkflowPanel {
  onPick?: (steps: string[]) => void
  onClose?: () => void
  @State templates: WorkflowTemplate[] = []
  @State searchQuery: string = ''

  aboutToAppear(): void {
    this.loadTemplates()
  }

  private async loadTemplates(): Promise<void> {
    try {
      this.templates = await PrefStore.loadWorkflows()
      if (this.templates.length === 0) {
        // 首次使用时初始化默认模板
        this.templates = this.defaultTemplates()
        await PrefStore.saveWorkflows(this.templates)
      }
    } catch (e) {
      console.error('[Workflow] 加载模板失败: ' + (e as Error).message)
    }
  }

  /** 按搜索词过滤 */
  private get filtered(): WorkflowTemplate[] {
    const q = this.searchQuery.toLowerCase().trim()
    if (q === '') return this.templates
    const out: WorkflowTemplate[] = []
    for (let i = 0; i < this.templates.length; i++) {
      const t = this.templates[i]
      if (t.name.toLowerCase().indexOf(q) >= 0) {
        out.push(t)
      }
    }
    return out
  }

  /** 默认 Workflow 模板 */
  private defaultTemplates(): WorkflowTemplate[] {
    return [
      {
        name: '部署后端',
        description: 'bump 版本 → go build → scp 上传 → 重启服务',
        steps: [
          { command: '/!cd /opt/serein/serein-server && git pull', description: '拉取最新代码' },
          { command: '/release-backend', description: '编译并部署后端' },
        ],
      },
      {
        name: '部署完整',
        description: '后端 + 前端全量部署',
        steps: [
          { command: '/release', description: '全量发版' },
        ],
      },
      {
        name: '全量编译测试',
        description: 'Go 编译 + Vet + Test',
        steps: [
          { command: '/!cd /opt/serein/serein-server && go build ./... && go vet ./... && go test ./... -count=1', description: 'Go 编译测试' },
        ],
      },
      {
        name: '查看系统状态',
        description: '服务器资源监控',
        steps: [
          { command: '/!free -h', description: '内存' },
          { command: '/!df -h', description: '磁盘' },
          { command: '/!uptime', description: '运行时间' },
          { command: '/!ps aux --sort=-%mem | head -10', description: '进程内存 TOP10' },
        ],
      },
    ]
  }

  build() {
    Column() {
      Row() {
        Text('Workflow 多步任务').fontSize(11).fontColor(currentTheme().textDim).layoutWeight(1)
        Text('  ✕').fontSize(11).fontColor(currentTheme().textDim)
          .onClick(() => { if (this.onClose) this.onClose() })
      }.width('100%').padding({ left: 16, right: 16, top: 6, bottom: 4 })

      // 搜索输入框
      TextInput({ text: this.searchQuery, placeholder: '搜索 Workflow…' })
        .fontSize(12).fontColor(currentTheme().text).placeholderColor(currentTheme().textDim)
        .fontFamily('monospace').height(32)
        .padding({ left: 12, right: 12 })
        .backgroundColor('rgba(255,255,255,0.04)')
        .borderRadius(6).border({ width: 1, color: 'rgba(140,144,159,0.08)' })
        .margin({ left: 12, right: 12, bottom: 4 })
        .onChange((v: string) => { this.searchQuery = v })

      if (this.filtered.length === 0) {
        Text(this.searchQuery.trim() !== '' ? '  (无匹配)' : '  (空 · 暂无可用的 Workflow 模板)')
          .fontSize(12).fontColor(currentTheme().textDim).padding({ left: 16, bottom: 8 })
      }

      ForEach(this.filtered, (template: WorkflowTemplate, idx: number) => {
        Column() {
          Row() {
            Text(template.name).fontSize(12).fontColor(currentTheme().accent).fontWeight(600)
            Blank()
            Text(template.steps.length + ' 步').fontSize(10).fontColor(currentTheme().textDim)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .backgroundColor('rgba(140,144,159,0.06)').borderRadius(4)
          }.width('100%')

          if (template.description !== '') {
            Text(template.description).fontSize(10).fontColor(currentTheme().textDim)
              .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%').margin({ top: 2 })
          }

          // 显示各步骤
          ForEach(template.steps, (step: WorkflowStep, sIdx: number) => {
            Row() {
              Text((sIdx + 1) + '.').fontSize(10).fontColor(currentTheme().textDim).width(16)
              Text(step.description).fontSize(10).fontColor(currentTheme().text).fontFamily('monospace')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
            }.width('100%').margin({ top: 1 })
          }, (step: WorkflowStep, sIdx: number) => sIdx.toString() + '_' + step.command)

          // 执行按钮
          Row() {
            Text('▶ 执行 ' + template.steps.length + ' 步').fontSize(11).fontColor(currentTheme().accent)
          }
          .width('100%').padding({ top: 6, bottom: 2 })
          .onClick(() => {
            const cmds: string[] = []
            for (let i = 0; i < template.steps.length; i++) {
              cmds.push(template.steps[i].command)
            }
            if (this.onPick) this.onPick(cmds)
          })
        }
        .width('100%').padding({ left: 16, right: 16, top: 10, bottom: 10 })
        .border({ width: { bottom: 1 }, color: currentTheme().divider })
      }, (template: WorkflowTemplate, idx: number) => idx.toString() + '_' + template.name)
    }
    .width('100%').backgroundColor(currentTheme().panel).borderRadius({ topLeft: 8, topRight: 8 })
    .border({ width: { top: 1 }, color: currentTheme().divider })
    .padding({ top: 4, bottom: 4 }).shadow({ radius: 8, color: 'rgba(0,0,0,0.25)', offsetY: -2 })
  }
}
