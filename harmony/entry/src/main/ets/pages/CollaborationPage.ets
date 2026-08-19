import { promptAction } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { pasteboard } from '@kit.BasicServicesKit'
import { webview } from '@kit.ArkWeb'
import CollaborationStore from '../store/CollaborationStore'
import { AmbientBackdrop } from '../components/AmbientBackdrop'
import type {
  CollaborationAccount, CollaborationRecord, CollaborationState, CollaborationWorkItem,
  LocalProjectRemote, ProviderKind, RemoteRepository, RepositoryBinding, WorkComment, WritebackAudit
} from '../model/collaboration/CollaborationModels'
import {
  collaborationPendingCount, emptyCollaborationState, providerDisplayName
} from '../model/collaboration/CollaborationModels'
import CollaborationAuthService from '../collaboration/CollaborationAuthService'
import type { OAuthAccessMode } from '../collaboration/CollaborationAuthService'
import CollaborationSyncService from '../collaboration/CollaborationSyncService'
import CollaborationProjectService from '../collaboration/CollaborationProjectService'
import CollaborationWorkService from '../collaboration/CollaborationWorkService'
import CollaborationResultService from '../collaboration/CollaborationResultService'
import CollaborationWritebackService from '../collaboration/CollaborationWritebackService'

type RepositorySection = 'pending' | 'issues' | 'comments' | 'changes' | 'processed'

@Component
export struct CollaborationContent {
  @State selectedProviderIndex: number = 0
  @State selectedRepositoryId: string = ''
  @State selectedRepositorySection: RepositorySection = 'pending'
  @State loading: boolean = true
  @State loadError: string = ''
  @State state: CollaborationState = emptyCollaborationState()
  @State syncing: boolean = false
  @State githubPullRefreshing: boolean = false
  @State giteePullRefreshing: boolean = false
  @State githubPullRefreshPhase: string = 'refreshing'
  @State giteePullRefreshPhase: string = 'refreshing'
  @State authorizing: boolean = false
  @State authMessage: string = ''
  @State githubAvailable: boolean = false
  @State giteeAvailable: boolean = false
  @State oauthConfigLoaded: boolean = false
  @State localProjects: LocalProjectRemote[] = []
  @State showWorkDetail: boolean = false
  @State detailLoading: boolean = false
  @State handoffBusy: boolean = false
  @State resultBusy: boolean = false
  @State writebackBusy: boolean = false
  @State showAuthWeb: boolean = false
  @State authUrl: string = ''
  @State authProvider: ProviderKind = 'github'
  @State authLoadError: string = ''
  @State draftText: string = ''
  @State labelText: string = ''
  @State showPullRequestComposer: boolean = false
  @State pullRequestTitle: string = ''
  @State pullRequestHead: string = ''
  @State pullRequestBase: string = ''
  @State pullRequestBody: string = ''
  @State selectedWorkItem: CollaborationWorkItem | null = null
  @State managedAccount: CollaborationAccount | null = null
  @State removingAccount: boolean = false
  @State bindingRepository: RemoteRepository | null = null
  @State bindingCandidates: LocalProjectRemote[] = []
  @State bindingRemoteMatched: boolean = false
  @State pendingBindingProject: LocalProjectRemote | null = null
  @State bindingSaving: boolean = false
  private authPollTimer: number = 0
  private silentSyncTimer: number = 0
  private lastSyncSucceeded: boolean = true
  private authExpiresAt: number = 0
  private pendingAuthAccess: OAuthAccessMode = 'read'
  private authWebController: webview.WebviewController = new webview.WebviewController()

  aboutToAppear(): void {
    this.loadCache()
    this.loadOAuthConfig()
    this.loadLocalProjects()
  }

  aboutToDisappear(): void {
    if (this.authPollTimer !== 0) {
      clearTimeout(this.authPollTimer)
      this.authPollTimer = 0
    }
    if (this.silentSyncTimer !== 0) {
      clearTimeout(this.silentSyncTimer)
      this.silentSyncTimer = 0
    }
  }

  private async loadOAuthConfig(): Promise<void> {
    try {
      const config = await CollaborationAuthService.config()
      this.githubAvailable = config.github.available
      this.giteeAvailable = config.gitee.available
    } catch (_) {
      this.githubAvailable = false
      this.giteeAvailable = false
    } finally {
      this.oauthConfigLoaded = true
    }
  }

  private async loadLocalProjects(): Promise<void> {
    try {
      this.localProjects = await CollaborationProjectService.loadLocalProjects()
    } catch (_) {
      this.localProjects = []
    }
  }

  private repositoryFor(item: CollaborationWorkItem): RemoteRepository | undefined {
    return this.state.repositories.find((value: RemoteRepository) => value.id === item.repositoryId)
  }

  private localProjectFor(binding: RepositoryBinding): LocalProjectRemote | undefined {
    return this.localProjects.find((value: LocalProjectRemote) => value.project === binding.project)
  }

  private async openWorkItem(item: CollaborationWorkItem): Promise<void> {
    this.selectedWorkItem = item
    const existing = CollaborationWorkService.findRecord(this.state, item.id)
    this.draftText = existing ? existing.replyDraft : ''
    this.prepareWriteEditors(item, existing)
    this.showWorkDetail = true
    this.detailLoading = true
    try {
      this.selectedWorkItem = await CollaborationSyncService.loadWorkItemDetails(item.id)
      this.state = await CollaborationStore.load()
      if (this.selectedWorkItem) this.prepareLabels(this.selectedWorkItem)
    } catch (e) {
      promptAction.showToast({ message: '详情同步失败：' + (e as Error).message, duration: 2200 })
    } finally {
      this.detailLoading = false
    }
  }

  private prepareWriteEditors(item: CollaborationWorkItem, record: CollaborationRecord | undefined): void {
    this.prepareLabels(item)
    const repository = this.repositoryFor(item)
    this.showPullRequestComposer = false
    this.pullRequestTitle = 'Fix #' + item.number + ': ' + item.title
    this.pullRequestHead = ''
    this.pullRequestBase = repository ? repository.defaultBranch : ''
    this.pullRequestBody = record && record.replyDraft !== '' ? record.replyDraft : item.title
  }

  private prepareLabels(item: CollaborationWorkItem): void {
    let value = ''
    for (let i = 0; i < item.labels.length; i++) {
      if (value !== '') value += ', '
      value += item.labels[i].name
    }
    this.labelText = value
  }

  private async handoffSelected(): Promise<void> {
    if (this.handoffBusy || this.selectedWorkItem === null) return
    const item = this.selectedWorkItem
    const repository = this.repositoryFor(item)
    if (!repository) {
      promptAction.showToast({ message: '没有找到所属仓库', duration: 1800 })
      return
    }
    const binding = this.bindingFor(repository.id)
    if (!binding) {
      this.chooseProjectBinding(repository)
      promptAction.showToast({ message: '请先确认一次本地项目绑定，再交给 Agent', duration: 2200 })
      return
    }
    let project = this.localProjectFor(binding)
    if (!project) {
      await this.loadLocalProjects()
      project = this.localProjectFor(binding)
    }
    if (!project) {
      promptAction.showToast({ message: '电脑端当前没有上报这个本地项目', duration: 2200 })
      return
    }
    this.handoffBusy = true
    try {
      const record = await CollaborationWorkService.handoff(item, repository, binding, project)
      this.state = await CollaborationStore.load()
      this.showWorkDetail = false
      CollaborationWorkService.openTerminal(record)
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message, duration: 2600 })
    } finally {
      this.handoffBusy = false
    }
  }

  private selectedRecord(): CollaborationRecord | undefined {
    if (this.selectedWorkItem === null) return undefined
    return CollaborationWorkService.findRecord(this.state, this.selectedWorkItem.id)
  }

  private openSelectedTerminal(): void {
    const record = this.selectedRecord()
    if (!record) return
    this.showWorkDetail = false
    CollaborationWorkService.openTerminal(record)
  }

  private async refreshSelectedResult(): Promise<void> {
    if (this.resultBusy) return
    const record = this.selectedRecord()
    if (!record) return
    this.resultBusy = true
    try {
      await CollaborationResultService.refresh(record.id)
      this.state = await CollaborationStore.load()
      const latest = this.selectedRecord()
      if (latest) this.draftText = latest.replyDraft
      const refreshed = this.selectedRecord()
      if (refreshed && refreshed.state === 'working') {
        promptAction.showToast({ message: 'Agent 仍在处理', duration: 1500 })
      } else if (refreshed && !refreshed.result) {
        promptAction.showToast({ message: '已完成，但没有可解析的结构化摘要，可进入终端查看原文', duration: 2400 })
      }
    } catch (e) {
      promptAction.showToast({ message: (e as Error).message, duration: 2000 })
    } finally {
      this.resultBusy = false
    }
  }

  private hasSelectedRecord(): boolean { return this.selectedRecord() !== undefined }

  private selectedRecordLabel(): string {
    const record = this.selectedRecord()
    if (!record) return ''
    if (record.state === 'working') return 'Agent 正在处理'
    if (record.state === 'draft_ready') return '回复草稿待确认'
    if (record.state === 'fixed') return '已修复'
    if (record.state === 'reproduced') return '已完成分析'
    if (record.state === 'failed') return '处理失败'
    if (record.state === 'replied') return '已回复'
    return '处理已完成'
  }

  private selectedResultText(): string {
    const record = this.selectedRecord()
    if (!record || !record.result) return ''
    let value = record.result.cause
    if (record.result.changeSummary !== '') value += '\n\n' + record.result.changeSummary
    if (record.result.testResult !== '') value += '\n\n测试：' + record.result.testResult
    return value
  }

  private selectedReplyDraft(): string {
    const record = this.selectedRecord()
    return record ? record.replyDraft : ''
  }

  private selectedAccount(): CollaborationAccount | undefined {
    if (this.selectedWorkItem === null) return undefined
    const repository = this.repositoryFor(this.selectedWorkItem)
    if (!repository) return undefined
    return this.state.accounts.find((value: CollaborationAccount) => value.id === repository.accountId)
  }

  private selectedWriteEnabled(): boolean {
    const account = this.selectedAccount()
    return account ? account.writeEnabled : false
  }

  private selectedCanCreatePullRequest(): boolean {
    const account = this.selectedAccount()
    return account ? account.capabilities.createPullRequest : false
  }

  private selectedCanMergePullRequest(): boolean {
    const account = this.selectedAccount()
    return account ? account.capabilities.mergePullRequest : false
  }

  private selectedCanRerunBuild(): boolean {
    const account = this.selectedAccount()
    return account ? account.capabilities.rerunBuild : false
  }

  private requestWriteAccess(): void {
    if (this.selectedWorkItem === null) return
    const repository = this.repositoryFor(this.selectedWorkItem)
    if (!repository) return
    const message = repository.provider === 'github'
      ? (repository.isPrivate
        ? 'GitHub 的 repo 权限同时包含私有仓库读写能力。Serein 仍会在每次发布、关闭、推送或合并前再次确认。'
        : 'GitHub 的 public_repo 权限包含公开仓库读写能力。Serein 仍会在每次写操作前再次确认。')
      : 'Gitee 的接口权限粒度较粗。启用后 Serein 仍不会自动写入，每次发布、关闭、推送或合并都要再次确认。'
    promptAction.showDialog({
      title: '单独启用受控写回', message: message,
      buttons: [{ text: '取消', color: '#8C909F' }, { text: '继续授权', color: '#D97757' }],
    }).then((result) => {
      if (result.index !== 1) return
      const access: OAuthAccessMode = repository.isPrivate ? 'private_write' : 'public_write'
      this.beginAuthorization(repository.provider, access)
    }).catch(() => {})
  }

  private async publishSelectedReply(): Promise<void> {
    if (this.writebackBusy) return
    const record = this.selectedRecord()
    if (!record || this.selectedWorkItem === null) return
    const draft = this.draftText.trim()
    if (draft === '') {
      promptAction.showToast({ message: '回复草稿为空', duration: 1600 })
      return
    }
    await CollaborationResultService.saveDraft(record.id, draft)
    promptAction.showDialog({
      title: '确认发布回复', message: draft.length > 500 ? draft.substring(0, 500) + '…' : draft,
      buttons: [{ text: '取消', color: '#8C909F' }, { text: '发布到平台', color: '#D97757' }],
    }).then(async (result) => {
      if (result.index !== 1 || this.selectedWorkItem === null) return
      this.writebackBusy = true
      try {
        await CollaborationWritebackService.publishReply(record.id, this.selectedWorkItem.id, true)
        this.state = await CollaborationStore.load()
        promptAction.showToast({ message: '回复已发布', duration: 1800 })
      } catch (e) {
        promptAction.showToast({ message: '发布失败：' + (e as Error).message, duration: 2400 })
      } finally {
        this.writebackBusy = false
      }
    }).catch(() => {})
  }

  private copySelectedReply(): void {
    const value = this.draftText.trim()
    if (value === '') {
      promptAction.showToast({ message: '回复草稿为空', duration: 1200 })
      return
    }
    try {
      const data = pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, value)
      pasteboard.getSystemPasteboard().setDataSync(data)
      promptAction.showToast({ message: '回复草稿已复制', duration: 1200 })
    } catch (e) {
      promptAction.showToast({ message: '复制失败：' + (e as Error).message, duration: 1600 })
    }
  }

  private closeSelectedIssue(): void {
    const record = this.selectedRecord()
    if (!record || this.selectedWorkItem === null || this.selectedWorkItem.kind !== 'issue') return
    promptAction.showDialog({
      title: '确认关闭 Issue',
      message: '这会修改远程平台上的 Issue 状态，不会合并代码或推送文件。',
      buttons: [{ text: '取消', color: '#8C909F' }, { text: '确认关闭', color: '#C89A89' }],
    }).then(async (result) => {
      if (result.index !== 1 || this.selectedWorkItem === null) return
      this.writebackBusy = true
      try {
        await CollaborationWritebackService.closeIssue(record.id, this.selectedWorkItem.id, true)
        this.state = await CollaborationStore.load()
        promptAction.showToast({ message: 'Issue 已关闭', duration: 1800 })
      } catch (e) {
        promptAction.showToast({ message: '关闭失败：' + (e as Error).message, duration: 2400 })
      } finally {
        this.writebackBusy = false
      }
    }).catch(() => {})
  }

  private reopenSelectedIssue(): void {
    const record = this.selectedRecord()
    if (!record || this.selectedWorkItem === null || this.selectedWorkItem.kind !== 'issue') return
    promptAction.showDialog({
      title: '确认重新打开 Issue',
      message: '这会修改远程平台上的 Issue 状态，不会推送或合并代码。',
      buttons: [{ text: '取消', color: '#8C909F' }, { text: '确认重新打开', color: '#D97757' }],
    }).then(async (result) => {
      if (result.index !== 1 || this.selectedWorkItem === null) return
      this.writebackBusy = true
      try {
        await CollaborationWritebackService.reopenIssue(record.id, this.selectedWorkItem.id, true)
        this.state = await CollaborationStore.load()
        if (this.selectedWorkItem) this.selectedWorkItem.state = 'open'
        promptAction.showToast({ message: 'Issue 已重新打开', duration: 1800 })
      } catch (e) {
        promptAction.showToast({ message: '操作失败：' + (e as Error).message, duration: 2400 })
      } finally {
        this.writebackBusy = false
      }
    }).catch(() => {})
  }

  private updateSelectedLabels(): void {
    const record = this.selectedRecord()
    if (!record || this.selectedWorkItem === null || this.selectedWorkItem.kind !== 'issue') return
    const labels: string[] = []
    const values = this.labelText.split(',')
    for (let i = 0; i < values.length; i++) {
      const value = values[i].trim()
      if (value !== '' && labels.indexOf(value) < 0) labels.push(value)
    }
    promptAction.showDialog({
      title: '确认更新标签',
      message: labels.length === 0 ? '将清空该 Issue 的全部标签。' : '将标签更新为：' + labels.join('、'),
      buttons: [{ text: '取消', color: '#8C909F' }, { text: '确认更新', color: '#D97757' }],
    }).then(async (result) => {
      if (result.index !== 1 || this.selectedWorkItem === null) return
      this.writebackBusy = true
      try {
        await CollaborationWritebackService.updateLabels(record.id, this.selectedWorkItem.id, labels, true)
        this.state = await CollaborationStore.load()
        promptAction.showToast({ message: '标签已更新', duration: 1800 })
      } catch (e) {
        promptAction.showToast({ message: '更新失败：' + (e as Error).message, duration: 2400 })
      } finally {
        this.writebackBusy = false
      }
    }).catch(() => {})
  }

  private createSelectedPullRequest(): void {
    const record = this.selectedRecord()
    if (!record || this.selectedWorkItem === null || this.selectedWorkItem.kind !== 'issue') return
    const title = this.pullRequestTitle.trim()
    const head = this.pullRequestHead.trim()
    const base = this.pullRequestBase.trim()
    if (title === '' || head === '' || base === '') {
      promptAction.showToast({ message: '请填写标题、源分支和目标分支', duration: 1800 })
      return
    }
    promptAction.showDialog({
      title: '确认创建草稿 PR/MR',
      message: title + '\n' + head + ' → ' + base + '\n\nSerein 不会替你自动推送本地分支；源分支必须已经存在于远程仓库。',
      buttons: [{ text: '取消', color: '#8C909F' }, { text: '确认创建', color: '#D97757' }],
    }).then(async (result) => {
      if (result.index !== 1 || this.selectedWorkItem === null) return
      this.writebackBusy = true
      try {
        await CollaborationWritebackService.createPullRequest(record.id, this.selectedWorkItem.id, {
          title: title, body: this.pullRequestBody, head: head, base: base, draft: true,
        }, true)
        this.state = await CollaborationStore.load()
        this.showPullRequestComposer = false
        promptAction.showToast({ message: '草稿 PR/MR 已创建', duration: 2000 })
      } catch (e) {
        promptAction.showToast({ message: '创建失败：' + (e as Error).message, duration: 2600 })
      } finally {
        this.writebackBusy = false
      }
    }).catch(() => {})
  }

  private mergeSelectedPullRequest(method: string): void {
    const record = this.selectedRecord()
    if (!record || this.selectedWorkItem === null || this.selectedWorkItem.kind !== 'pull_request') return
    promptAction.showDialog({
      title: '确认合并 PR/MR',
      message: '将使用 ' + method + ' 合并 #' + this.selectedWorkItem.number + '。这是不可轻易撤销的远程写操作。',
      buttons: [{ text: '取消', color: '#8C909F' }, { text: '确认合并', color: '#C89A89' }],
    }).then(async (result) => {
      if (result.index !== 1 || this.selectedWorkItem === null) return
      this.writebackBusy = true
      try {
        await CollaborationWritebackService.mergePullRequest(record.id, this.selectedWorkItem.id, method, true)
        this.state = await CollaborationStore.load()
        if (this.selectedWorkItem) this.selectedWorkItem.state = 'merged'
        promptAction.showToast({ message: 'PR/MR 已合并', duration: 1800 })
      } catch (e) {
        promptAction.showToast({ message: '合并失败：' + (e as Error).message, duration: 2600 })
      } finally {
        this.writebackBusy = false
      }
    }).catch(() => {})
  }

  private chooseMergeMethod(): void {
    promptAction.showActionMenu({
      title: '选择合并方式',
      buttons: [
        { text: 'Merge commit', color: '#D99A83' },
        { text: 'Squash', color: '#D99A83' },
        { text: 'Rebase', color: '#D99A83' },
      ],
    }).then((result) => {
      const methods: string[] = ['merge', 'squash', 'rebase']
      if (result.index >= 0 && result.index < methods.length) this.mergeSelectedPullRequest(methods[result.index])
    }).catch(() => {})
  }

  private rerunSelectedBuild(): void {
    const record = this.selectedRecord()
    if (!record || this.selectedWorkItem === null || this.selectedWorkItem.kind !== 'build') return
    promptAction.showDialog({
      title: '确认重跑失败构建',
      message: '这会在远程平台重新消耗 CI 资源，仅重跑当前失败的 GitHub Actions jobs。',
      buttons: [{ text: '取消', color: '#8C909F' }, { text: '确认重跑', color: '#D97757' }],
    }).then(async (result) => {
      if (result.index !== 1 || this.selectedWorkItem === null) return
      this.writebackBusy = true
      try {
        await CollaborationWritebackService.rerunBuild(record.id, this.selectedWorkItem.id, true)
        this.state = await CollaborationStore.load()
        if (this.selectedWorkItem) this.selectedWorkItem.state = 'running'
        promptAction.showToast({ message: '失败构建已提交重跑', duration: 2000 })
      } catch (e) {
        promptAction.showToast({ message: '重跑失败：' + (e as Error).message, duration: 2600 })
      } finally {
        this.writebackBusy = false
      }
    }).catch(() => {})
  }

  private openRecord(record: CollaborationRecord): void {
    const item = this.state.workItems.find((value: CollaborationWorkItem) => value.id === record.workItemId)
    if (item) this.openWorkItem(item)
  }

  private selectedTitle(): string { return this.selectedWorkItem ? this.selectedWorkItem.title : '' }
  private selectedBody(): string { return this.selectedWorkItem ? this.selectedWorkItem.body : '' }
  private selectedNumber(): string { return this.selectedWorkItem ? this.selectedWorkItem.number : '' }
  private selectedComments(): WorkComment[] {
    return this.selectedWorkItem ? this.selectedWorkItem.comments : []
  }

  private async openSelectedInProvider(): Promise<void> {
    if (!this.selectedWorkItem || this.selectedWorkItem.webUrl === '') return
    try {
      const context = getContext(this) as common.UIAbilityContext
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: this.selectedWorkItem.webUrl })
    } catch (e) {
      promptAction.showToast({ message: '无法打开平台页面：' + (e as Error).message, duration: 2000 })
    }
  }

  @Builder
  private workDetailOverlay(): void {
    Stack({ alignContent: Alignment.Bottom }) {
      Column()
        .width('100%').height('100%')
        .backgroundColor('rgba(0,0,0,0.66)')
        .onClick(() => { this.showWorkDetail = false })
      Column() {
        Row() {
          Column() {
            Text('#' + this.selectedNumber()).fontSize(11).fontColor('#C89A89')
            Text(this.selectedTitle()).fontSize(17).fontWeight(650).fontColor('#F0EBE7')
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 5 })
          }.layoutWeight(1).alignItems(HorizontalAlign.Start)
          Text('×').fontSize(25).fontColor('#A9ACB7').padding(8)
            .onClick(() => { this.showWorkDetail = false })
        }.width('100%')

        if (this.detailLoading) {
          LoadingProgress().width(28).height(28).color('#D99A83').margin({ top: 52 })
        } else {
          Scroll() {
            Column() {
              if (this.hasSelectedRecord()) {
                Row() {
                  Text(this.selectedRecordLabel()).fontSize(11).fontWeight(650).fontColor('#D99A83')
                  Blank()
                  Text(this.resultBusy ? '刷新中…' : '刷新结果').fontSize(11).fontColor('#B8BBC5')
                    .onClick(() => { this.refreshSelectedResult() })
                }.width('100%').padding(11).margin({ bottom: 12 })
                  .backgroundColor('rgba(217,119,87,0.08)').borderRadius(10)
              }
              Text(this.selectedBody() === '' ? '没有正文' : this.selectedBody())
                .fontSize(13).fontColor('#C9CBD3').lineHeight(21).width('100%')
              if (this.selectedWorkItem && this.selectedWorkItem.webUrl !== '') {
                Text('在 ' + providerDisplayName(this.selectedWorkItem.provider) + ' 打开原始页面与附件')
                  .fontSize(11).fontWeight(600).fontColor('#C89A89')
                  .width('100%').textAlign(TextAlign.End).margin({ top: 9 })
                  .onClick(() => { this.openSelectedInProvider() })
              }
              if (this.selectedResultText() !== '') {
                Text('Agent 结果').fontSize(12).fontWeight(650).fontColor('#D99A83')
                  .width('100%').margin({ top: 22, bottom: 7 })
                Text(this.selectedResultText()).fontSize(12).fontColor('#C9CBD3').lineHeight(20)
                  .width('100%').padding(12).backgroundColor('rgba(140,144,159,0.07)').borderRadius(10)
              }
              if (this.selectedReplyDraft() !== '') {
                Text('回复草稿').fontSize(12).fontWeight(650).fontColor('#D99A83')
                  .width('100%').margin({ top: 22, bottom: 7 })
                TextArea({ text: this.draftText, placeholder: '确认并编辑回复草稿' })
                  .fontSize(12).fontColor('#C9CBD3').height(150).padding(12)
                  .backgroundColor('rgba(217,119,87,0.07)').borderRadius(10)
                  .onChange((value: string) => { this.draftText = value })
                if (!this.selectedWriteEnabled()) {
                  Row() {
                    Text('复制草稿').fontSize(11).fontColor('#A9ACB7')
                      .onClick(() => { this.copySelectedReply() })
                    Blank()
                    Text('启用受控写回').fontSize(11).fontWeight(650).fontColor('#D99A83')
                      .onClick(() => { this.requestWriteAccess() })
                  }.width('100%').margin({ top: 10 })
                } else {
                  Row() {
                    Text('复制草稿').fontSize(11).fontColor('#A9ACB7')
                      .onClick(() => { this.copySelectedReply() })
                    Blank()
                    Text(this.writebackBusy ? '处理中…' : '确认并发布')
                      .fontSize(11).fontWeight(650).fontColor('#D99A83')
                      .onClick(() => { this.publishSelectedReply() })
                  }.width('100%').margin({ top: 10 })
                }
              }
              if (this.hasSelectedRecord() && this.selectedReplyDraft() === '' && !this.selectedWriteEnabled()) {
                Text('启用受控写回').fontSize(11).fontWeight(650).fontColor('#D99A83')
                  .width('100%').textAlign(TextAlign.End).margin({ top: 18 })
                  .onClick(() => { this.requestWriteAccess() })
              }
              if (this.hasSelectedRecord() && this.selectedWriteEnabled() && this.selectedWorkItem &&
                this.selectedWorkItem.kind === 'issue') {
                Text('Issue 操作').fontSize(12).fontWeight(650).fontColor('#D99A83')
                  .width('100%').margin({ top: 22, bottom: 7 })
                TextInput({ text: this.labelText, placeholder: '标签，以英文逗号分隔' })
                  .fontSize(12).fontColor('#C9CBD3').height(42).padding({ left: 12, right: 12 })
                  .backgroundColor('rgba(140,144,159,0.07)').borderRadius(10)
                  .onChange((value: string) => { this.labelText = value })
                Row() {
                  if (this.selectedWorkItem.state === 'closed') {
                    Text('重新打开 Issue').fontSize(11).fontColor('#A9ACB7')
                      .onClick(() => { this.reopenSelectedIssue() })
                  } else {
                    Text('关闭 Issue').fontSize(11).fontColor('#A9ACB7')
                      .onClick(() => { this.closeSelectedIssue() })
                  }
                  Blank()
                  Text('确认更新标签').fontSize(11).fontWeight(650).fontColor('#C89A89')
                    .onClick(() => { this.updateSelectedLabels() })
                }.width('100%').margin({ top: 10 })
                if (this.selectedCanCreatePullRequest()) {
                  Text(this.showPullRequestComposer ? '收起 PR/MR 创建器' : '创建草稿 PR/MR')
                    .fontSize(11).fontWeight(650).fontColor('#D99A83')
                    .width('100%').textAlign(TextAlign.End).margin({ top: 17 })
                    .onClick(() => { this.showPullRequestComposer = !this.showPullRequestComposer })
                  if (this.showPullRequestComposer) {
                    TextInput({ text: this.pullRequestTitle, placeholder: 'PR/MR 标题' })
                      .fontSize(12).fontColor('#C9CBD3').height(42).margin({ top: 9 })
                      .backgroundColor('rgba(140,144,159,0.07)').borderRadius(10)
                      .onChange((value: string) => { this.pullRequestTitle = value })
                    Row({ space: 8 }) {
                      TextInput({ text: this.pullRequestHead, placeholder: '已推送的源分支' })
                        .layoutWeight(1).fontSize(11).fontColor('#C9CBD3').height(42)
                        .backgroundColor('rgba(140,144,159,0.07)').borderRadius(10)
                        .onChange((value: string) => { this.pullRequestHead = value })
                      TextInput({ text: this.pullRequestBase, placeholder: '目标分支' })
                        .layoutWeight(1).fontSize(11).fontColor('#C9CBD3').height(42)
                        .backgroundColor('rgba(140,144,159,0.07)').borderRadius(10)
                        .onChange((value: string) => { this.pullRequestBase = value })
                    }.width('100%').margin({ top: 8 })
                    TextArea({ text: this.pullRequestBody, placeholder: 'PR/MR 描述' })
                      .fontSize(12).fontColor('#C9CBD3').height(120).padding(12).margin({ top: 8 })
                      .backgroundColor('rgba(140,144,159,0.07)').borderRadius(10)
                      .onChange((value: string) => { this.pullRequestBody = value })
                    Text(this.writebackBusy ? '处理中…' : '确认并创建草稿 PR/MR')
                      .fontSize(11).fontWeight(650).fontColor('#D99A83')
                      .width('100%').textAlign(TextAlign.End).margin({ top: 10 })
                      .onClick(() => { this.createSelectedPullRequest() })
                  }
                }
              }
              if (this.hasSelectedRecord() && this.selectedWriteEnabled() && this.selectedWorkItem &&
                this.selectedWorkItem.kind === 'pull_request' && this.selectedWorkItem.state === 'open' &&
                this.selectedCanMergePullRequest()) {
                Text('选择方式并确认合并 PR/MR').fontSize(11).fontWeight(650).fontColor('#C89A89')
                  .width('100%').textAlign(TextAlign.End).margin({ top: 20 })
                  .onClick(() => { this.chooseMergeMethod() })
              }
              if (this.hasSelectedRecord() && this.selectedWriteEnabled() && this.selectedWorkItem &&
                this.selectedWorkItem.kind === 'build' && this.selectedWorkItem.state === 'failed' &&
                this.selectedCanRerunBuild()) {
                Text('确认重跑失败构建').fontSize(11).fontWeight(650).fontColor('#D99A83')
                  .width('100%').textAlign(TextAlign.End).margin({ top: 20 })
                  .onClick(() => { this.rerunSelectedBuild() })
              }
              if (this.selectedComments().length > 0) {
                Text('评论').fontSize(12).fontWeight(650).fontColor('#D99A83')
                  .width('100%').margin({ top: 22, bottom: 2 })
                ForEach(this.selectedComments(), (comment: WorkComment) => {
                  Column() {
                    Text(comment.author).fontSize(11).fontWeight(600).fontColor('#B8BBC5').width('100%')
                    Text(comment.body).fontSize(12).fontColor('#A9ACB7').lineHeight(19)
                      .width('100%').margin({ top: 5 })
                  }
                  .width('100%').padding(12).margin({ top: 8 })
                  .backgroundColor('rgba(140,144,159,0.07)').borderRadius(10)
                }, (comment: WorkComment) => comment.id)
              }
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .justifyContent(FlexAlign.Start)
          }
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
          .align(Alignment.TopStart)
          .margin({ top: 14 })

          Row({ space: 10 }) {
            if (this.selectedRecord()) {
              Button('进入终端')
                .layoutWeight(1).height(44).fontSize(13).fontColor('#D9D4D0')
                .backgroundColor('rgba(140,144,159,0.12)').borderRadius(10)
                .onClick(() => { this.openSelectedTerminal() })
            }
            Button(this.handoffBusy ? '正在交给 Agent…' : (this.selectedRecord() ? '继续处理' : '交给 Agent'))
              .layoutWeight(1).height(44).fontSize(13).fontWeight(650).fontColor('#17191D')
              .backgroundColor('#D97757').borderRadius(10)
              .enabled(!this.handoffBusy)
              .onClick(() => { this.handoffSelected() })
          }.width('100%').margin({ top: 14 })
        }
      }
      .width('100%').height('68%').padding({ left: 20, right: 20, top: 18, bottom: 22 })
      .backgroundColor('#15181C').borderRadius({ topLeft: 22, topRight: 22 })
      .border({ width: 1, color: 'rgba(217,119,87,0.18)' })
    }.width('100%').height('100%')
  }

  private chooseProvider(): void {
    promptAction.showActionMenu({
      title: '添加代码平台（首次只读）',
      buttons: [
        { text: this.githubAvailable ? 'GitHub' : 'GitHub · 后端未配置', color: '#D99A83' },
        { text: this.giteeAvailable ? 'Gitee' : 'Gitee · 后端未配置', color: '#D99A83' },
      ]
    }).then((result) => {
      const provider: ProviderKind = result.index === 0 ? 'github' : 'gitee'
      const available = provider === 'github' ? this.githubAvailable : this.giteeAvailable
      if (!available) {
        promptAction.showToast({ message: '请先在 Serein 后端配置该平台的 OAuth 环境变量', duration: 2200 })
        return
      }
      this.beginAuthorization(provider)
    }).catch(() => {})
  }

  private manageAccount(account: CollaborationAccount): void {
    this.managedAccount = account
  }

  private closeManageAccountDialog(): void {
    if (this.removingAccount) return
    this.managedAccount = null
  }

  private async removeManagedAccount(): Promise<void> {
    const account = this.managedAccount
    if (!account || this.removingAccount) return
    this.removingAccount = true
    try {
      await CollaborationSyncService.removeAccount(account.id)
      this.state = await CollaborationStore.load()
      if (this.authProvider === account.provider) this.authMessage = ''
      this.managedAccount = null
      promptAction.showToast({ message: '社区账号和本地数据已移除', duration: 2000 })
    } catch (e) {
      promptAction.showToast({ message: '移除失败：' + (e as Error).message, duration: 2400 })
    } finally {
      this.removingAccount = false
    }
  }

  private async beginAuthorization(provider: ProviderKind, access: OAuthAccessMode = 'read'): Promise<void> {
    if (this.authorizing) return
    this.authorizing = true
    this.pendingAuthAccess = access
    this.authMessage = '正在打开 ' + providerDisplayName(provider) + ' 授权页…'
    this.authProvider = provider
    this.authLoadError = ''
    try {
      const started = await CollaborationAuthService.start(provider, access)
      if (!this.isTrustedAuthorizationUrl(started.authorization_url, provider)) {
        throw new Error('授权地址不是受信任的平台域名')
      }
      this.authExpiresAt = Date.now() + started.expires_in * 1000
      this.authUrl = started.authorization_url
      this.showAuthWeb = true
      this.authMessage = '请在页面内完成授权，Serein 会自动接收结果'
      this.scheduleAuthPoll(provider, started.state)
    } catch (e) {
      this.authorizing = false
      this.showAuthWeb = false
      this.authUrl = ''
      this.authMessage = '授权启动失败：' + (e as Error).message
    }
  }

  private isTrustedAuthorizationUrl(url: string, provider: ProviderKind): boolean {
    if (provider === 'github') return url.startsWith('https://github.com/login/oauth/authorize')
    return url.startsWith('https://gitee.com/oauth/authorize')
  }

  private closeAuthorizationWeb(cancelAuthorization: boolean): void {
    this.showAuthWeb = false
    this.authUrl = ''
    this.authLoadError = ''
    if (!cancelAuthorization || !this.authorizing) return
    this.authorizing = false
    this.authMessage = '已取消授权'
    if (this.authPollTimer !== 0) {
      clearTimeout(this.authPollTimer)
      this.authPollTimer = 0
    }
  }

  private async openAuthorizationExternally(): Promise<void> {
    if (this.authUrl === '') return
    try {
      const context = getContext(this) as common.UIAbilityContext
      await context.startAbility({ action: 'ohos.want.action.viewData', uri: this.authUrl })
    } catch (e) {
      this.authLoadError = '无法打开系统浏览器：' + (e as Error).message
    }
  }

  private scheduleAuthPoll(provider: ProviderKind, state: string): void {
    if (this.authPollTimer !== 0) clearTimeout(this.authPollTimer)
    this.authPollTimer = setTimeout(() => { this.pollAuthorization(provider, state) }, 1600)
  }

  private async pollAuthorization(provider: ProviderKind, state: string): Promise<void> {
    this.authPollTimer = 0
    if (!this.authorizing) return
    if (Date.now() > this.authExpiresAt) {
      this.authorizing = false
      this.closeAuthorizationWeb(false)
      this.authMessage = '授权已超时，请重新发起'
      return
    }
    try {
      const result = await CollaborationAuthService.poll(provider, state)
      if (result.status === 'pending') {
        this.scheduleAuthPoll(provider, state)
        return
      }
      if (result.status !== 'complete' || !result.access_token) {
        this.authorizing = false
        this.closeAuthorizationWeb(false)
        this.authMessage = result.error ?? '授权未完成，请重试'
        return
      }
      // access_token 只存在于当前局部变量中，保存后不进入 @State 或日志。
      await CollaborationSyncService.finishAuthorization(provider, result.access_token, result.scopes ?? [],
        this.pendingAuthAccess !== 'read', this.pendingAuthAccess === 'private_write')
      // finishAuthorization persists the account. Refresh the in-memory state before
      // syncNow checks it, otherwise a newly connected account still looks absent
      // until the page is recreated.
      this.state = await CollaborationStore.load()
      this.authorizing = false
      this.closeAuthorizationWeb(false)
      this.authMessage = providerDisplayName(provider) + ' 已连接，正在同步仓库…'
      await this.syncNow()
      this.scheduleSilentSync()
      this.authMessage = providerDisplayName(provider) + ' 账号已连接'
    } catch (e) {
      this.authorizing = false
      this.closeAuthorizationWeb(false)
      this.authMessage = '授权失败：' + (e as Error).message
    }
  }

  private async syncNow(): Promise<boolean> {
    if (this.syncing) {
      await this.waitForSyncToFinish()
      return this.lastSyncSucceeded
    }
    if (this.state.accounts.length === 0) {
      this.lastSyncSucceeded = false
      return false
    }
    this.syncing = true
    try {
      this.state = await CollaborationSyncService.syncAll()
      this.loadError = ''
      this.lastSyncSucceeded = true
      return true
    } catch (e) {
      this.loadError = '同步失败：' + (e as Error).message
      this.lastSyncSucceeded = false
      return false
    } finally {
      this.syncing = false
    }
  }

  private async waitForSyncToFinish(): Promise<void> {
    while (this.syncing) {
      await new Promise<void>((resolve: () => void) => {
        setTimeout(resolve, 80)
      })
    }
  }

  private providerPullRefreshing(provider: ProviderKind): boolean {
    return provider === 'github' ? this.githubPullRefreshing : this.giteePullRefreshing
  }

  private setProviderPullRefreshing(provider: ProviderKind, refreshing: boolean): void {
    if (provider === 'github') this.githubPullRefreshing = refreshing
    else this.giteePullRefreshing = refreshing
  }

  private providerPullRefreshPhase(provider: ProviderKind): string {
    return provider === 'github' ? this.githubPullRefreshPhase : this.giteePullRefreshPhase
  }

  private setProviderPullRefreshPhase(provider: ProviderKind, phase: string): void {
    if (provider === 'github') this.githubPullRefreshPhase = phase
    else this.giteePullRefreshPhase = phase
  }

  private async pullToRefresh(provider: ProviderKind): Promise<void> {
    const startedAt = Date.now()
    this.setProviderPullRefreshPhase(provider, 'checking')
    this.setProviderPullRefreshing(provider, true)
    try {
      if (!this.oauthConfigLoaded) await this.loadOAuthConfig()
      const connected = this.accountsForProvider(provider).length > 0
      if (!connected) {
        this.setProviderPullRefreshPhase(provider,
          this.providerAvailable(provider) ? 'unconnected' : 'unconfigured')
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 720) })
        return
      }

      this.setProviderPullRefreshPhase(provider, 'refreshing')
      const succeeded = await this.syncNow()
      const remaining = 650 - (Date.now() - startedAt)
      if (remaining > 0) {
        await new Promise<void>((resolve: () => void) => { setTimeout(resolve, remaining) })
      }
      this.setProviderPullRefreshPhase(provider, succeeded ? 'success' : 'failed')
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 420) })
    } finally {
      // Keep the final result visible while Refresh retracts. Reset only after it
      // has moved off-screen, otherwise the user sees "正在刷新" during collapse.
      this.setProviderPullRefreshing(provider, false)
      await new Promise<void>((resolve: () => void) => { setTimeout(resolve, 360) })
      if (!this.providerPullRefreshing(provider)) {
        this.setProviderPullRefreshPhase(provider, 'refreshing')
      }
    }
  }

  @Builder
  private pullRefreshIndicator(provider: ProviderKind): void {
    Row() {
      if (this.providerPullRefreshPhase(provider) === 'refreshing') {
        LoadingProgress().width(22).height(22).color('#D97757')
        Text('正在刷新').fontSize(11).fontColor('#C98B75').margin({ left: 8 })
      } else if (this.providerPullRefreshPhase(provider) === 'success') {
        Text('✓').fontSize(15).fontWeight(700).fontColor('#D97757')
        Text('刷新完成').fontSize(11).fontColor('#C98B75').margin({ left: 7 })
      } else if (this.providerPullRefreshPhase(provider) === 'checking') {
        LoadingProgress().width(18).height(18).color('#D97757')
        Text('正在检查账号').fontSize(11).fontColor('#C98B75').margin({ left: 8 })
      } else if (this.providerPullRefreshPhase(provider) === 'unconfigured') {
        Text('OAuth 尚未配置').fontSize(11).fontColor('#A9ACB7')
      } else if (this.providerPullRefreshPhase(provider) === 'unconnected') {
        Text('账号未绑定').fontSize(11).fontColor('#A9ACB7')
      } else {
        Text('刷新失败').fontSize(11).fontColor('#C85F52')
      }
    }
    .width('100%').height(44)
    .justifyContent(FlexAlign.Center)
  }

  private scheduleSilentSync(): void {
    if (this.silentSyncTimer !== 0) clearTimeout(this.silentSyncTimer)
    this.silentSyncTimer = setTimeout(async () => {
      this.silentSyncTimer = 0
      await this.syncNow()
      this.scheduleSilentSync()
    }, 5 * 60 * 1000)
  }

  private async toggleTracked(repository: RemoteRepository): Promise<void> {
    const tracked = this.state.trackedRepositoryIds.indexOf(repository.id) >= 0
    await CollaborationSyncService.setTracked(repository.id, !tracked)
    this.state = await CollaborationStore.load()
    if (!tracked) await this.syncNow()
  }

  private bindingFor(repositoryId: string): RepositoryBinding | undefined {
    return this.state.bindings.find((binding: RepositoryBinding) => binding.repositoryId === repositoryId)
  }

  private matchingProjects(repository: RemoteRepository): LocalProjectRemote[] {
    return CollaborationProjectService.matchingProjects(repository, this.localProjects)
  }

  private chooseProjectBinding(repository: RemoteRepository): void {
    const matches = this.matchingProjects(repository)
    const candidates = matches.length > 0 ? matches : this.localProjects
    if (candidates.length === 0) {
      promptAction.showToast({ message: '电脑端暂未发现可绑定的本地项目', duration: 1800 })
      return
    }
    if (candidates.length === 1) {
      this.confirmProjectBinding(repository, candidates[0], matches.length === 1)
      return
    }
    this.showProjectMenu(repository, candidates, matches.length > 0)
  }

  private projectMenuLabel(project: LocalProjectRemote): string {
    return project.project + ' · ' + (project.agentType === 'codex' ? 'Codex' : 'Claude Code')
  }

  private showProjectMenu(repository: RemoteRepository, allCandidates: LocalProjectRemote[],
    remoteMatched: boolean): void {
    this.bindingRepository = repository
    this.bindingCandidates = allCandidates.slice(0, 6)
    this.bindingRemoteMatched = remoteMatched
    this.pendingBindingProject = null
  }

  private confirmProjectBinding(repository: RemoteRepository, project: LocalProjectRemote,
    remoteMatched: boolean): void {
    this.bindingRepository = repository
    this.bindingRemoteMatched = remoteMatched
    this.bindingCandidates = []
    this.pendingBindingProject = project
  }

  private closeBindingDialog(): void {
    if (this.bindingSaving) return
    this.bindingRepository = null
    this.bindingCandidates = []
    this.pendingBindingProject = null
  }

  private selectBindingProject(project: LocalProjectRemote): void {
    const repository = this.bindingRepository
    if (!repository) return
    this.confirmProjectBinding(repository, project, this.bindingRemoteMatched)
  }

  private async saveBinding(): Promise<void> {
    const repository = this.bindingRepository
    const project = this.pendingBindingProject
    if (!repository || !project || this.bindingSaving) return
    this.bindingSaving = true
    try {
      await CollaborationProjectService.confirmBinding(repository, project)
      this.state = await CollaborationStore.load()
      await this.syncNow()
      this.closeBindingDialog()
    } catch (e) {
      promptAction.showToast({ message: '绑定失败：' + (e as Error).message, duration: 2200 })
    } finally {
      this.bindingSaving = false
    }
  }

  private async loadCache(): Promise<void> {
    this.loading = true
    this.loadError = ''
    try {
      this.state = await CollaborationStore.load()
      AppStorage.setOrCreate('collaborationPendingCount', collaborationPendingCount(this.state))
    } catch (e) {
      this.loadError = '社区数据无法解锁，请在设置中清除后重新绑定'
      console.error('[Collaboration] load cache failed: ' + (e as Error).message)
    } finally {
      this.loading = false
      if (this.state.accounts.length > 0) {
        this.syncNow()
        this.scheduleSilentSync()
      }
    }
  }

  private repositoryBindingLabel(repository: RemoteRepository): string {
    const binding = this.bindingFor(repository.id)
    if (binding) return '已绑定 ' + binding.project
    const matches = this.matchingProjects(repository)
    if (matches.length === 1) return '可绑定 ' + matches[0].project
    return matches.length > 1 ? '多个本地项目匹配' : '选择本地项目'
  }

  private repositoryBindingColor(repository: RemoteRepository): string {
    return this.bindingFor(repository.id) ? '#A9ACB7' : '#C89A89'
  }

  private repositoryBoundAgent(repository: RemoteRepository): string {
    const binding = this.bindingFor(repository.id)
    if (!binding) return ''
    const project = this.localProjects.find((value: LocalProjectRemote) => value.project === binding.project)
    return ' · ' + (project && project.agentType === 'codex' ? 'Codex' : 'Claude Code')
  }

  private pendingItems(): CollaborationWorkItem[] {
    return this.state.workItems.filter((item: CollaborationWorkItem) => {
      if (item.unread || item.state === 'failed') return true
      const record = CollaborationWorkService.findRecord(this.state, item.id)
      return record ? record.state === 'working' || record.state === 'draft_ready' || record.state === 'failed' : false
    })
  }

  private accountsForProvider(provider: ProviderKind): CollaborationAccount[] {
    return this.state.accounts.filter((account: CollaborationAccount) => account.provider === provider)
  }

  private repositoriesForProvider(provider: ProviderKind): RemoteRepository[] {
    return this.state.repositories.filter((repository: RemoteRepository) => repository.provider === provider)
  }

  private workItemsForRepository(repositoryId: string): CollaborationWorkItem[] {
    return this.state.workItems.filter((item: CollaborationWorkItem) => item.repositoryId === repositoryId)
  }

  private pendingItemsForRepository(repositoryId: string): CollaborationWorkItem[] {
    return this.pendingItems().filter((item: CollaborationWorkItem) => item.repositoryId === repositoryId)
  }

  private issueItemsForRepository(repositoryId: string): CollaborationWorkItem[] {
    return this.workItemsForRepository(repositoryId)
      .filter((item: CollaborationWorkItem) => item.kind === 'issue')
  }

  private commentItemsForRepository(repositoryId: string): CollaborationWorkItem[] {
    return this.workItemsForRepository(repositoryId)
      .filter((item: CollaborationWorkItem) => item.commentsCount > 0)
  }

  private changeItemsForRepository(repositoryId: string): CollaborationWorkItem[] {
    return this.workItemsForRepository(repositoryId)
      .filter((item: CollaborationWorkItem) => item.kind === 'pull_request' || item.kind === 'build')
  }

  private recordsForRepository(repositoryId: string): CollaborationRecord[] {
    return this.state.records.filter((record: CollaborationRecord) =>
      record.repositoryId === repositoryId && record.state !== 'queued' && record.state !== 'working')
  }

  private auditsForRepository(repositoryId: string): WritebackAudit[] {
    return this.state.writebackAudits.filter((audit: WritebackAudit) => audit.repositoryId === repositoryId)
  }

  private repositoryCommentCount(repositoryId: string): number {
    const items = this.workItemsForRepository(repositoryId)
    let count = 0
    for (let i = 0; i < items.length; i++) count += items[i].commentsCount
    return count
  }

  private pendingCountForProvider(provider: ProviderKind): number {
    const repositories = this.repositoriesForProvider(provider)
    let count = 0
    for (let i = 0; i < repositories.length; i++) {
      count += this.pendingItemsForRepository(repositories[i].id).length
    }
    return count
  }

  private selectedRepository(provider: ProviderKind): RemoteRepository | undefined {
    if (this.selectedRepositoryId === '') return undefined
    return this.state.repositories.find((repository: RemoteRepository) =>
      repository.id === this.selectedRepositoryId && repository.provider === provider)
  }

  private selectProvider(index: number): void {
    if (this.selectedProviderIndex === index) return
    this.selectedProviderIndex = index
    this.selectedRepositoryId = ''
    this.selectedRepositorySection = 'pending'
  }

  private openRepository(repository: RemoteRepository): void {
    this.selectedRepositoryId = repository.id
    this.selectedRepositorySection = 'pending'
  }

  private closeRepository(): void {
    this.selectedRepositoryId = ''
    this.selectedRepositorySection = 'pending'
  }

  private providerAvailable(provider: ProviderKind): boolean {
    return provider === 'github' ? this.githubAvailable : this.giteeAvailable
  }

  private activeProvider(): ProviderKind {
    return this.selectedProviderIndex === 0 ? 'github' : 'gitee'
  }

  private providerChangeLabel(provider: ProviderKind): string {
    return provider === 'github' ? 'PR/CI' : 'MR/CI'
  }

  private itemsForRepositorySection(repository: RemoteRepository): CollaborationWorkItem[] {
    if (this.selectedRepositorySection === 'pending') return this.pendingItemsForRepository(repository.id)
    if (this.selectedRepositorySection === 'issues') return this.issueItemsForRepository(repository.id)
    if (this.selectedRepositorySection === 'comments') return this.commentItemsForRepository(repository.id)
    if (this.selectedRepositorySection === 'changes') return this.changeItemsForRepository(repository.id)
    return []
  }

  private repositorySectionEmptyTitle(): string {
    if (this.selectedRepositorySection === 'pending') return '这个仓库暂时没有待处理项'
    if (this.selectedRepositorySection === 'issues') return '这个仓库暂时没有 Issue'
    if (this.selectedRepositorySection === 'comments') return '这个仓库暂时没有带评论的事项'
    if (this.selectedRepositorySection === 'changes') return '这个仓库暂时没有 PR/MR 或构建记录'
    return '这个仓库还没有处理记录'
  }

  private repositorySectionEmptyDescription(): string {
    if (this.selectedRepositorySection === 'pending') return '新 Issue、@ 提及、失败构建和等待确认的 Agent 结果会显示在这里。'
    if (this.selectedRepositorySection === 'issues') return '这里只展示平台真实返回的 Issue，不会用仓库统计数字生成占位内容。'
    if (this.selectedRepositorySection === 'comments') return '有评论数量的 Issue 或 PR/MR 会显示在这里，点开后再同步完整评论。'
    if (this.selectedRepositorySection === 'changes') return 'GitHub 使用 PR，Gitee 使用 MR；CI 构建也归入这个变更入口。'
    return '交给 Agent 并形成结果后，会按仓库保存在这里。'
  }

  private workItemActionLabel(item: CollaborationWorkItem): string {
    const record = CollaborationWorkService.findRecord(this.state, item.id)
    if (!record) return '交给 Agent'
    if (record.state === 'working') return 'Agent 处理中'
    if (record.state === 'draft_ready') return '确认结果'
    if (record.state === 'failed') return '查看失败'
    return '继续处理'
  }

  @Builder
  private providerTab(provider: ProviderKind, index: number): void {
    Column() {
      Row() {
        Text(providerDisplayName(provider))
          .fontSize(14)
          .fontWeight(this.selectedProviderIndex === index ? 650 : 450)
          .fontColor(this.selectedProviderIndex === index ? '#F0EBE7' : '#777C8A')
        if (this.pendingCountForProvider(provider) > 0) {
          Text(this.pendingCountForProvider(provider) > 99 ? '99+' : this.pendingCountForProvider(provider).toString())
            .fontSize(9).fontWeight(700).fontColor('#F0D4C8')
            .height(18).padding({ left: 6, right: 6 }).margin({ left: 7 })
            .backgroundColor('rgba(217,119,87,0.24)').borderRadius(9)
        }
      }.height(36).justifyContent(FlexAlign.Center)
      Row()
        .width(this.selectedProviderIndex === index ? 36 : 0).height(2)
        .backgroundColor('#D97757').borderRadius(1)
    }
    .layoutWeight(1).height(44)
    .justifyContent(FlexAlign.Center)
    .onClick(() => { this.selectProvider(index) })
  }

  @Builder
  private repositorySectionButton(section: RepositorySection, label: string, count: number): void {
    Column() {
      Text(label).fontSize(10).fontWeight(this.selectedRepositorySection === section ? 650 : 450)
        .fontColor(this.selectedRepositorySection === section ? '#E8E3DF' : '#777C8A')
      Text(count > 99 ? '99+' : count.toString()).fontSize(9)
        .fontColor(this.selectedRepositorySection === section ? '#D99A83' : '#656A76')
        .margin({ top: 2 })
    }
    .layoutWeight(1).height(43).justifyContent(FlexAlign.Center)
    .backgroundColor(this.selectedRepositorySection === section ? 'rgba(217,119,87,0.11)' : Color.Transparent)
    .borderRadius(9)
    .onClick(() => { this.selectedRepositorySection = section })
  }

  @Builder
  private emptyPanel(title: string, description: string): void {
    Column() {
      Text(title).fontSize(16).fontWeight(600).fontColor('#E1E2E8')
      Text(description)
        .fontSize(12).fontColor('#8C909F').textAlign(TextAlign.Center)
        .lineHeight(19).width('82%').margin({ top: 7 })
    }
    .width('100%').padding({ top: 52, bottom: 42 })
  }

  @Builder
  private accountStrip(provider: ProviderKind): void {
    if (this.accountsForProvider(provider).length > 0) {
      Column({ space: 10 }) {
        ForEach(this.accountsForProvider(provider), (account: CollaborationAccount) => {
          Row() {
            if (account.avatarUrl !== '') {
              Image(account.avatarUrl)
                .width(46).height(46).borderRadius(23)
                .objectFit(ImageFit.Cover)
                .backgroundColor('rgba(217,119,87,0.10)')
            } else {
              Row() {
                Text((account.displayName !== '' ? account.displayName : account.login).substring(0, 1).toUpperCase())
                  .fontSize(18).fontWeight(650).fontColor('#D99A83')
              }
              .width(46).height(46).borderRadius(23)
              .backgroundColor('rgba(217,119,87,0.12)')
              .justifyContent(FlexAlign.Center)
            }

            Column({ space: 4 }) {
              Text(account.displayName !== '' ? account.displayName : account.login)
                .fontSize(15).fontWeight(600).fontColor('#E5E1DE')
                .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
              Row() {
                Text('@' + account.login).fontSize(11).fontColor('#8C909F')
              }
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            .margin({ left: 12 })

            Text('管理')
              .fontSize(11).fontWeight(600).fontColor('#C78A75')
              .padding({ left: 10, right: 10, top: 6, bottom: 6 })
              .backgroundColor('rgba(217,119,87,0.08)').borderRadius(8)
          }
          .width('100%').height(60)
          .onClick(() => { this.manageAccount(account) })
        }, (account: CollaborationAccount) => account.id)
      }.width('100%')
    }
    if (this.authMessage !== '' && this.authProvider === provider) {
      Text(this.authMessage).fontSize(11).fontColor('#A9ACB7').margin({ top: 9 })
    }
  }

  @Builder
  private deleteAccountIcon(): void {
    Stack({ alignContent: Alignment.TopStart }) {
      Row()
        .width(14).height(7)
        .border({ width: { top: 2, right: 2, bottom: 0, left: 2 }, color: '#C98B75' })
        .borderRadius({ topLeft: 3, topRight: 3 })
        .position({ x: 15, y: 0 })
      Row()
        .width(38).height(4)
        .backgroundColor('#C98B75')
        .borderRadius(2)
        .position({ x: 3, y: 7 })
      Row()
        .width(30).height(29)
        .border({ width: { top: 0, right: 2, bottom: 2, left: 2 }, color: '#C98B75' })
        .borderRadius({ bottomLeft: 6, bottomRight: 6 })
        .position({ x: 7, y: 11 })
      Row()
        .width(2).height(18)
        .backgroundColor('#A87566')
        .borderRadius(1)
        .position({ x: 16, y: 15 })
      Row()
        .width(2).height(18)
        .backgroundColor('#A87566')
        .borderRadius(1)
        .position({ x: 26, y: 15 })
    }
    .width(44).height(42)
  }

  @Builder
  private manageAccountOverlay(): void {
    Stack({ alignContent: Alignment.Center }) {
      Row()
        .width('100%').height('100%')
        .backgroundColor('rgba(4,6,9,0.72)')
        .onClick(() => { this.closeManageAccountDialog() })

      Column() {
        Row() {
          this.deleteAccountIcon()

          Column() {
            Text('移除 ' + providerDisplayName((this.managedAccount as CollaborationAccount).provider) + ' 账号')
              .fontSize(17).fontWeight(650).fontColor('#F0EBE7')
            Text('@' + (this.managedAccount as CollaborationAccount).login)
              .fontSize(11).fontColor('#8C909F').margin({ top: 4 })
          }
          .layoutWeight(1).alignItems(HorizontalAlign.Start).margin({ left: 13 })
        }.width('100%')

        Text('将删除该账号的安全凭证、本地仓库缓存、项目绑定、处理记录和写回审计。')
          .width('100%').fontSize(12).fontColor('#B4B0AE').lineHeight(19)
          .margin({ top: 18 })

        Text('如需彻底撤销授权，请前往 ' +
          providerDisplayName((this.managedAccount as CollaborationAccount).provider) +
          ' 的 OAuth 授权设置，取消对 Serein 的授权。')
          .width('100%').fontSize(11).fontColor('#777C8A').lineHeight(18)
          .margin({ top: 8 })

        Row({ space: 10 }) {
          Row() {
            Text('取消').fontSize(12).fontWeight(600).fontColor('#B8BBC5')
          }
            .layoutWeight(1).height(42).justifyContent(FlexAlign.Center)
            .backgroundColor('rgba(140,144,159,0.10)').borderRadius(11)
            .opacity(this.removingAccount ? 0.55 : 1)
            .onClick(() => { this.closeManageAccountDialog() })
          Row() {
            Text(this.removingAccount ? '正在移除…' : '确认移除')
              .fontSize(12).fontWeight(650).fontColor('#EAD8D1')
          }
            .layoutWeight(1).height(42).justifyContent(FlexAlign.Center)
            .backgroundColor('rgba(201,112,88,0.18)').borderRadius(11)
            .border({ width: 1, color: 'rgba(217,119,87,0.28)' })
            .opacity(this.removingAccount ? 0.55 : 1)
            .onClick(() => { this.removeManagedAccount() })
        }.width('100%').margin({ top: 22 })
      }
      .width('86%').padding({ left: 20, right: 20, top: 20, bottom: 18 })
      .backgroundColor('#171A1F').borderRadius(20)
      .border({ width: 1, color: 'rgba(217,119,87,0.22)' })
      .shadow({ radius: 24, color: 'rgba(0,0,0,0.42)', offsetY: 8 })
    }
    .width('100%').height('100%')
    .transition(TransitionEffect.OPACITY.animation({ duration: 180, curve: Curve.EaseOut }))
  }

  @Builder
  private bindingOverlay(): void {
    Stack({ alignContent: Alignment.Bottom }) {
      Row().width('100%').height('100%').backgroundColor('rgba(4,6,9,0.72)')
        .onClick(() => { this.closeBindingDialog() })

      Column() {
        if (this.pendingBindingProject === null) {
          Text(this.bindingRemoteMatched ? '选择匹配的本地项目' : '选择本地项目')
            .fontSize(20).fontWeight(700).fontColor('#F0EBE7').width('100%')
          Text(this.bindingRemoteMatched ? '已按 Git Remote 找到多个匹配，请确认要处理此仓库事项的项目。' :
            '手动绑定后，该仓库的事项会固定交给所选项目的默认 Agent。')
            .fontSize(11).fontColor('#8C909F').lineHeight(18).width('100%').margin({ top: 8, bottom: 14 })
          ForEach(this.bindingCandidates, (project: LocalProjectRemote) => {
            Row() {
              Column({ space: 3 }) {
                Text(project.project).fontSize(15).fontWeight(650).fontColor('#ECE7E3')
                Text(project.agentType === 'codex' ? 'OpenAI Codex' : 'Claude Code')
                  .fontSize(10).fontColor('#C89A89')
              }.alignItems(HorizontalAlign.Start).layoutWeight(1)
              Text('选择').fontSize(11).fontWeight(650).fontColor('#D97757')
            }
            .width('100%').height(58).padding({ left: 13, right: 13 }).margin({ top: 8 })
            .backgroundColor('rgba(255,255,255,0.045)').borderRadius(12)
            .border({ width: 1, color: 'rgba(217,119,87,0.16)' })
            .onClick(() => { this.selectBindingProject(project) })
          }, (project: LocalProjectRemote) => project.project)
          Row() {
            Text('取消').fontSize(12).fontWeight(650).fontColor('#B8BBC5')
          }.width('100%').height(44).justifyContent(FlexAlign.Center).margin({ top: 12 })
            .backgroundColor('rgba(140,144,159,0.10)').borderRadius(11)
            .onClick(() => { this.closeBindingDialog() })
        } else {
          Text('确认绑定').fontSize(20).fontWeight(700).fontColor('#F0EBE7').width('100%')
          Text((this.bindingRepository as RemoteRepository).fullName)
            .fontSize(12).fontColor('#C89A89').margin({ top: 5 }).width('100%')
          Text(this.bindingRemoteMatched ? 'Git Remote 已匹配。' : '这是手动绑定。')
            .fontSize(12).fontColor('#B8BBC5').margin({ top: 18 }).width('100%')
          Text('以后 #' + (this.bindingRepository as RemoteRepository).name + ' 的事项会交给 ' +
            (this.pendingBindingProject as LocalProjectRemote).project + ' 的 ' +
            ((this.pendingBindingProject as LocalProjectRemote).agentType === 'codex' ? 'Codex' : 'Claude Code') + '。')
            .fontSize(12).fontColor('#B8BBC5').lineHeight(19).width('100%').margin({ top: 6 })
          Row({ space: 10 }) {
            Row() { Text('取消').fontSize(12).fontWeight(650).fontColor('#B8BBC5') }
              .layoutWeight(1).height(44).justifyContent(FlexAlign.Center)
              .backgroundColor('rgba(140,144,159,0.10)').borderRadius(11)
              .onClick(() => { this.closeBindingDialog() })
            Row() { Text(this.bindingSaving ? '正在绑定…' : '确认绑定').fontSize(12).fontWeight(700).fontColor('#181A1F') }
              .layoutWeight(1).height(44).justifyContent(FlexAlign.Center)
              .backgroundColor('#D97757').borderRadius(11).opacity(this.bindingSaving ? 0.55 : 1)
              .onClick(() => { this.saveBinding() })
          }.width('100%').margin({ top: 22 })
        }
      }
      .width('100%').padding({ left: 20, right: 20, top: 22, bottom: 24 })
      .backgroundColor('#1A1D23')
      .border({ width: { top: 1 }, color: 'rgba(217,119,87,0.32)' })
      .borderRadius({ topLeft: 24, topRight: 24 })
      .transition(TransitionEffect.move(TransitionEdge.BOTTOM)
        .combine(TransitionEffect.OPACITY).animation({ duration: 220, curve: Curve.FastOutSlowIn }))
    }.width('100%').height('100%')
  }

  @Builder
  private workItemCard(item: CollaborationWorkItem): void {
    Column() {
      Row() {
        Text(item.kind === 'issue' ? 'ISSUE' : (item.kind === 'pull_request' ? 'PR' : 'CI'))
          .fontSize(9).fontWeight(700).fontColor('#D99A83')
        Text('#' + item.number).fontSize(10).fontColor('#777C8A').margin({ left: 7 })
        Blank()
        Text(providerDisplayName(item.provider)).fontSize(10).fontColor('#777C8A')
      }.width('100%')
      Text(item.title).fontSize(14).fontWeight(550).fontColor('#E1E2E8')
        .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis }).margin({ top: 9 })
      Row() {
        Text(item.author).fontSize(10).fontColor('#8C909F')
        Text(' · ' + item.commentsCount + ' 条评论').fontSize(10).fontColor('#8C909F')
        Blank()
        Text(this.workItemActionLabel(item)).fontSize(11).fontWeight(600).fontColor('#D99A83')
      }.width('100%').margin({ top: 12 })
    }
    .width('100%').padding(15).margin({ top: 10 })
    .backgroundColor('rgba(29,32,36,0.68)').borderRadius(13)
    .border({ width: 1, color: 'rgba(140,144,159,0.12)' })
    .onClick(() => { this.openWorkItem(item) })
  }

  @Builder
  private repositoryCard(repository: RemoteRepository): void {
    Column() {
      Row() {
        Text(repository.fullName).fontSize(15).fontWeight(620).fontColor('#E8E3DF')
          .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis }).layoutWeight(1)
        Text(repository.isPrivate ? '私有' : '公开').fontSize(10).fontColor('#777C8A')
      }.width('100%')
      Row() {
        Text(this.repositoryBindingLabel(repository))
          .fontSize(10).fontWeight(550)
          .fontColor(this.repositoryBindingColor(repository))
          .onClick(() => { this.chooseProjectBinding(repository) })
        if (this.bindingFor(repository.id)) {
          Text(this.repositoryBoundAgent(repository)).fontSize(10).fontColor('#777C8A')
        }
        Blank()
        Text('★ ' + repository.stars).fontSize(10).fontColor('#8C909F')
      }.width('100%').margin({ top: 8 })

      Row({ space: 6 }) {
        this.repositoryMetric('待处理', this.pendingItemsForRepository(repository.id).length, true)
        this.repositoryMetric('Issue', repository.openIssues, false)
        this.repositoryMetric('评论', this.repositoryCommentCount(repository.id), false)
        this.repositoryMetric(repository.provider === 'github' ? 'PR' : 'MR', repository.openPullRequests, false)
        this.repositoryMetric('已处理', this.recordsForRepository(repository.id).length, false)
      }.width('100%').margin({ top: 13 })

      Row() {
        Text(this.state.trackedRepositoryIds.indexOf(repository.id) >= 0 ? '已跟踪' : '跟踪仓库')
          .fontSize(10).fontWeight(600)
          .fontColor(this.state.trackedRepositoryIds.indexOf(repository.id) >= 0 ? '#C89A89' : '#777C8A')
          .padding({ top: 8, bottom: 8, right: 10 })
          .onClick(() => { this.toggleTracked(repository) })
        Blank()
        Text('进入仓库  →').fontSize(11).fontWeight(650).fontColor('#D99A83')
          .padding({ top: 8, bottom: 8, left: 10 })
      }.margin({ top: 6 }).width('100%')
    }
    .width('100%').padding(15).margin({ top: 11 })
    .backgroundColor('rgba(29,32,36,0.68)').borderRadius(13)
    .border({ width: 1, color: 'rgba(140,144,159,0.12)' })
    .onClick(() => { this.openRepository(repository) })
  }

  @Builder
  private repositoryMetric(label: string, count: number, highlighted: boolean): void {
    Column() {
      Text(count >= 0 ? (count > 99 ? '99+' : count.toString()) : '—')
        .fontSize(12).fontWeight(650).fontColor(highlighted && count > 0 ? '#E6B19E' : '#C9CBD3')
      Text(label).fontSize(8).fontColor('#717681').margin({ top: 2 })
    }
    .layoutWeight(1).height(42).justifyContent(FlexAlign.Center)
    .backgroundColor(highlighted && count > 0 ? 'rgba(217,119,87,0.10)' : 'rgba(140,144,159,0.055)')
    .borderRadius(8)
  }

  @Builder
  private providerConnectPanel(provider: ProviderKind): void {
    Column() {
      Text(providerDisplayName(provider)).fontSize(21).fontWeight(700).fontColor('#E8E3DF')
      Text(this.providerAvailable(provider) ? '连接账号后，这里会按仓库整理社区事项。' : '后端暂未配置这个平台的 OAuth。')
        .fontSize(12).fontColor('#8C909F').textAlign(TextAlign.Center).lineHeight(19)
        .width('82%').margin({ top: 8 })
      Button(this.providerAvailable(provider) ? '连接 ' + providerDisplayName(provider) : '暂不可连接')
        .height(38).fontSize(12).fontWeight(650).fontColor('#F0EBE7')
        .backgroundColor('rgba(217,119,87,0.14)').borderRadius(10)
        .border({ width: 1, color: 'rgba(217,119,87,0.26)' }).margin({ top: 18 })
        .enabled(this.providerAvailable(provider) && !this.authorizing)
        .onClick(() => { this.beginAuthorization(provider) })
    }.width('100%').padding({ top: 66, bottom: 52 }).alignItems(HorizontalAlign.Center)
  }

  @Builder
  private repositoryWorkspace(repository: RemoteRepository): void {
    Column() {
      Row() {
        Text('‹').fontSize(28).fontColor('#B8BBC5').width(34)
          .onClick(() => { this.closeRepository() })
        Column() {
          Text(repository.fullName).fontSize(16).fontWeight(650).fontColor('#F0EBE7')
            .maxLines(1).textOverflow({ overflow: TextOverflow.Ellipsis })
          Text(providerDisplayName(repository.provider) + ' · ' +
            (this.bindingFor(repository.id) ? this.repositoryBindingLabel(repository) : '尚未绑定本地项目'))
            .fontSize(10).fontColor('#777C8A').margin({ top: 3 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text(this.state.trackedRepositoryIds.indexOf(repository.id) >= 0 ? '已跟踪' : '跟踪')
          .fontSize(10).fontWeight(600).fontColor('#C89A89').padding(8)
          .onClick(() => { this.toggleTracked(repository) })
      }.width('100%').height(52)

      Row() {
        this.repositorySectionButton('pending', '待处理', this.pendingItemsForRepository(repository.id).length)
        this.repositorySectionButton('issues', 'Issue', this.issueItemsForRepository(repository.id).length)
        this.repositorySectionButton('comments', '评论', this.repositoryCommentCount(repository.id))
        this.repositorySectionButton('changes', this.providerChangeLabel(repository.provider),
          this.changeItemsForRepository(repository.id).length)
        this.repositorySectionButton('processed', '已处理', this.recordsForRepository(repository.id).length)
      }
      .width('100%').height(51).padding(4).margin({ top: 7 })
      .backgroundColor('rgba(29,32,36,0.58)').borderRadius(11)

      Scroll() {
        Column() {
          if (this.selectedRepositorySection === 'processed') {
            if (this.recordsForRepository(repository.id).length === 0 &&
              this.auditsForRepository(repository.id).length === 0) {
              this.emptyPanel(this.repositorySectionEmptyTitle(), this.repositorySectionEmptyDescription())
            } else {
              ForEach(this.recordsForRepository(repository.id), (record: CollaborationRecord) => {
                this.recordCard(record)
              }, (record: CollaborationRecord) => record.id)
              if (this.auditsForRepository(repository.id).length > 0) {
                Text('受控写回审计').fontSize(11).fontWeight(650).fontColor('#A9ACB7')
                  .width('100%').margin({ top: 20, bottom: 2 })
                ForEach(this.auditsForRepository(repository.id), (audit: WritebackAudit) => {
                  this.auditCard(audit)
                }, (audit: WritebackAudit) => audit.id)
              }
            }
          } else if (this.itemsForRepositorySection(repository).length === 0) {
            this.emptyPanel(this.repositorySectionEmptyTitle(), this.repositorySectionEmptyDescription())
          } else {
            ForEach(this.itemsForRepositorySection(repository), (item: CollaborationWorkItem) => {
              this.workItemCard(item)
            }, (item: CollaborationWorkItem) => item.id)
          }
        }
        .width('100%')
        .padding({ bottom: 28 })
        .justifyContent(FlexAlign.Start)
        .alignItems(HorizontalAlign.Start)
      }
      .layoutWeight(1)
      .scrollBar(BarState.Off)
      .align(Alignment.TopStart)
    }.width('100%').height('100%')
  }

  @Builder
  private providerPage(provider: ProviderKind): void {
    Refresh({
      refreshing: provider === 'github' ? this.githubPullRefreshing : this.giteePullRefreshing,
      builder: () => { this.pullRefreshIndicator(provider) }
    }) {
      Column() {
        this.accountStrip(provider)
        if (this.loadError !== '') {
          Text(this.loadError).fontSize(12).fontColor('#C8A487').margin({ top: 18 })
        } else if (this.loading) {
          LoadingProgress().width(28).height(28).color('#D97757').margin({ top: 56 })
        } else if (this.accountsForProvider(provider).length === 0) {
          this.providerConnectPanel(provider)
        } else if (this.selectedRepository(provider)) {
          this.repositoryWorkspace(this.selectedRepository(provider) as RemoteRepository)
        } else if (this.repositoriesForProvider(provider).length === 0) {
          this.emptyPanel('还没有仓库', '下拉同步后，这里只展示 ' + providerDisplayName(provider) + ' 返回的真实仓库。')
        } else {
          Scroll() {
            Column() {
              Row() {
                Text('仓库').fontSize(12).fontWeight(650).fontColor('#B8BBC5')
                Blank()
                Text('左右滑动可切换平台').fontSize(9).fontColor('#656A76')
              }.width('100%').margin({ top: 14, bottom: 1 })
              ForEach(this.repositoriesForProvider(provider), (repository: RemoteRepository) => {
                this.repositoryCard(repository)
              }, (repository: RemoteRepository) => repository.id)
            }
            .width('100%').padding({ bottom: 28 })
            .justifyContent(FlexAlign.Start).alignItems(HorizontalAlign.Start)
          }.layoutWeight(1).scrollBar(BarState.Off).align(Alignment.TopStart)
        }
      }.width('100%').height('100%').padding({ left: 20, right: 20, top: 12 })
    }
    .width('100%').height('100%')
    .onRefreshing(() => { this.pullToRefresh(provider) })
  }

  @Builder
  private recordCard(record: CollaborationRecord): void {
    Row() {
      Column() {
        Text(record.project).fontSize(14).fontWeight(600).fontColor('#E1E2E8')
        Text(record.state === 'draft_ready' ? '回复草稿待确认' : record.state)
          .fontSize(11).fontColor('#A9ACB7').margin({ top: 5 })
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text(record.agentType === 'codex' ? 'Codex' : 'Claude Code')
        .fontSize(10).fontColor('#D99A83')
    }
    .width('100%').padding(15).margin({ top: 10 })
    .backgroundColor('rgba(29,32,36,0.68)').borderRadius(13)
    .border({ width: 1, color: 'rgba(140,144,159,0.12)' })
    .onClick(() => { this.openRecord(record) })
  }

  @Builder
  private auditCard(audit: WritebackAudit): void {
    Row() {
      Column() {
        Text(audit.summary).fontSize(13).fontWeight(550).fontColor('#D7D9E0')
        Text(providerDisplayName(audit.provider) + ' · ' +
          (audit.success ? '远程写入成功' : '远程写入失败'))
          .fontSize(10).fontColor(audit.success ? '#A9ACB7' : '#C89A89').margin({ top: 5 })
        if (!audit.success && audit.error !== '') {
          Text(audit.error).fontSize(10).fontColor('#8C909F').maxLines(2).margin({ top: 4 })
        }
      }.layoutWeight(1).alignItems(HorizontalAlign.Start)
      Text('审计').fontSize(9).fontWeight(650).fontColor('#C89A89')
    }
    .width('100%').padding(14).margin({ top: 9 })
    .backgroundColor('rgba(29,32,36,0.54)').borderRadius(12)
    .border({ width: 1, color: 'rgba(200,154,137,0.11)' })
  }

  @Builder
  private authorizationWebOverlay(): void {
    Column() {
      Row() {
        Column() {
          Text('连接 ' + providerDisplayName(this.authProvider))
            .fontSize(18).fontWeight(650).fontColor('#F0EBE7')
          Text('仅在平台官方页面输入账号信息')
            .fontSize(10).fontColor('#777C8A').margin({ top: 3 })
        }.layoutWeight(1).alignItems(HorizontalAlign.Start)
        Text('浏览器打开').fontSize(10).fontWeight(600).fontColor('#C89A89')
          .padding({ left: 8, right: 8, top: 9, bottom: 9 })
          .onClick(() => { this.openAuthorizationExternally() })
        Text('×').fontSize(25).fontColor('#A9ACB7').padding({ left: 9, right: 4, top: 6, bottom: 6 })
          .onClick(() => { this.closeAuthorizationWeb(true) })
      }
      .width('100%').height(62).padding({ left: 18, right: 14 })
      .backgroundColor('#111419')
      .border({ width: { bottom: 1 }, color: 'rgba(217,119,87,0.13)' })

      if (this.authLoadError !== '') {
        Text(this.authLoadError).fontSize(11).fontColor('#C89A89')
          .width('100%').padding({ left: 18, right: 18, top: 8, bottom: 8 })
          .backgroundColor('rgba(200,154,137,0.08)')
      }

      Web({ src: this.authUrl, controller: this.authWebController })
        .javaScriptAccess(true)
        .domStorageAccess(true)
        .layoutWeight(1)
        .width('100%')
        .backgroundColor('#0B0E12')  // 深色背景：加载态/过渡态与 App 主题一致，避免白底突变
    }
    .width('100%').height('100%')
    .padding({ top: 42 })
    .backgroundColor('#0B0E12')
    .transition(TransitionEffect.move(TransitionEdge.BOTTOM)
      .combine(TransitionEffect.OPACITY).animation({ duration: 260, curve: Curve.FastOutSlowIn }))
  }

  build() {
    Stack() {
      AmbientBackdrop()
      Column() {
      Row() {
        Column() {
          Text('社区').fontSize(25).fontWeight(700).fontColor('#F0EBE7')
          Text('把外部反馈带回本地 Agent').fontSize(11).fontColor('#777C8A').margin({ top: 3 })
        }.alignItems(HorizontalAlign.Start)
        Blank()
        if (this.accountsForProvider(this.activeProvider()).length === 0) {
          Button('添加账号')
            .height(34).fontSize(11).fontWeight(650).fontColor('#F0EBE7')
            .backgroundColor('rgba(217,119,87,0.14)').borderRadius(9)
            .border({ width: 1, color: 'rgba(217,119,87,0.30)' })
            .enabled(this.providerAvailable(this.activeProvider()) && !this.authorizing)
            .onClick(() => { this.beginAuthorization(this.activeProvider()) })
        }
      // MainTabs extends into the system status area. Reserve this page's
      // top inset explicitly so the collaboration title is never covered.
      }.width('100%').padding({ left: 20, right: 14, top: 52, bottom: 12 })

      Row() {
        this.providerTab('github', 0)
        this.providerTab('gitee', 1)
      }
      .height(46).margin({ left: 20, right: 20 })
      .backgroundColor('rgba(29,32,36,0.38)').borderRadius(12)

      Swiper() {
        this.providerPage('github')
        this.providerPage('gitee')
      }
      .layoutWeight(1)
      .index(this.selectedProviderIndex)
      .indicator(false)
      .loop(false)
      .duration(280)
      .curve(Curve.FastOutSlowIn)
      .onChange((index: number) => { this.selectProvider(index) })
    }
      .width('100%').height('100%').backgroundColor('transparent')
      if (this.showWorkDetail) {
        this.workDetailOverlay()
      }
      if (this.showAuthWeb && this.authUrl !== '') {
        this.authorizationWebOverlay()
      }
      if (this.managedAccount !== null) {
        this.manageAccountOverlay()
      }
      if (this.bindingRepository !== null) {
        this.bindingOverlay()
      }
    }.width('100%').height('100%')
  }
}

@Entry
@Component
struct CollaborationPage {
  build() {
    Stack() {
      CollaborationContent()
    }
  }
}
