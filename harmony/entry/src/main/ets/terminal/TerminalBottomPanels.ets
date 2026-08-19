/**
 * TerminalBottomPanels — 从 TerminalPage.build() 提取的底部面板 + 工具栏 + 输入栏
 *
 * 减少主文件代码行数，将所有条件渲染面板（斜杠补全、历史、片段、工作流）
 * 与输入栏集中在独立组件中。
 */
import { TerminalSession, type TerminalLineData } from './TerminalSession'
import { TerminalInputBar } from './TerminalInputBar'
import { TerminalToolbar } from './TerminalToolbar'
import { type SlashCommandInfo } from './SlashCommands'
import { type Snippet } from '../store/PrefStore'
import { SlashHintPanel } from './SlashHintPanel'
import { HistoryPanel } from './HistoryPanel'
import { SnippetPanel } from './SnippetPanel'
import { WorkflowPanel } from './WorkflowPanel'

@Component
export struct TerminalBottomPanels {
  @Prop slashHints: SlashCommandInfo[] = []
  @Prop slashHintOverflow: boolean = false
  @Prop showHistory: boolean = false
  @Prop historyList: string[] = []
  @Prop remoteHistory: string[] = []
  @Prop remoteLoading: boolean = false
  @Prop remoteError: string = ''
  @Prop showSnippets: boolean = false
  @Prop snippets: Snippet[] = []
  @Prop showWorkflow: boolean = false
  @Prop inputText: string = ''
  @Prop connected: boolean = false
  @Prop executing: boolean = false
  // 回调
  onPickSlashHint: (cmd: string) => void = () => {}
  onPickHistory: (cmd: string) => void = () => {}
  onPickSnippet: (cmd: string) => void = () => {}
  onAddSnippet: () => void = () => {}
  onDeleteSnippet: (name: string) => void = () => {}
  onCloseSnippet: () => void = () => {}
  onPickWorkflow: (cmds: string[]) => void = () => {}
  onCloseWorkflow: () => void = () => {}
  onKeyTap: (key: string) => void = () => {}
  onChange: (text: string) => void = () => {}
  onSubmit: (text: string) => void = () => {}
  onFilePick: () => void = () => {}
  onVoiceError: (message: string) => void = () => {}

  build() {
    Column() {
      // / 命令补全建议浮层
      if (this.slashHints.length > 0) {
        SlashHintPanel({
          slashHints: this.slashHints,
          slashHintOverflow: this.slashHintOverflow,
          onPick: (cmd: string) => { this.onPickSlashHint(cmd) }
        })
      }
      // 历史模糊搜索浮层
      if (this.showHistory) {
        HistoryPanel({
          historyList: this.historyList,
          remoteHistory: this.remoteHistory,
          remoteLoading: this.remoteLoading,
          remoteError: this.remoteError,
          onPick: (cmd: string) => { this.onPickHistory(cmd) }
        })
      }
      // 片段浮层
      if (this.showSnippets) {
        SnippetPanel({
          snippets: this.snippets,
          onPick: (cmd: string) => { this.onPickSnippet(cmd) },
          onAdd: () => { this.onAddSnippet() },
          onDelete: (name: string) => { this.onDeleteSnippet(name) },
          onClose: () => { this.onCloseSnippet() }
        })
      }
      // Workflow 模板浮层
      if (this.showWorkflow) {
        WorkflowPanel({
          onPick: (cmds: string[]) => { this.onPickWorkflow(cmds) },
          onClose: () => { this.onCloseWorkflow() }
        })
      }
      TerminalToolbar({ onKeyTap: (key: string) => { this.onKeyTap(key) } })
      TerminalInputBar({
        inputText: this.inputText, connected: this.connected, executing: this.executing,
        onChange: (text: string) => { this.onChange(text) },
        onSubmit: (text: string) => { this.onSubmit(text) },
        onFilePick: () => { this.onFilePick() },
        onVoiceError: (message: string) => { this.onVoiceError(message) },
      })
    }
  }
}
