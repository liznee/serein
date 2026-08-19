/**
 * TerminalOutputArea — 从 TerminalPage.TerminalContent 提取的独立输出区域组件
 *
 * 封装 Scroll + 行渲染 + 手势操作，减少主文件代码行数。
 * Scroller 由父组件创建并传入，父组件通过该 Scroller 直接控制滚动。
 * 滚动状态（userScrolledUp）通过 onScrollChanged 回调通知父组件。
 */
import { type TerminalLineData } from './TerminalSession'
import { TerminalLine } from './TerminalLine'
import { WelcomeBanner } from './WelcomeBanner'
import { currentTheme } from './TerminalTheme'
import { agentDisplayName } from '../store/PrefStore'

@Component
export struct TerminalOutputArea {
  private scroller: Scroller = new Scroller()
  @Link renderLines: TerminalLineData[]
  @Link showBanner: boolean
  @Link executing: boolean
  @Link collapsed: number[]
  @Prop fontSize: number = 13
  @Prop selectedLineKey: string = ''
  @Prop agentType: string = 'claude'
  private projectName: string = ''
  private onToggleCollapse?: (blockId: number) => void
  private onScrollChanged?: (isUserScrolledUp: boolean) => void
  private onFontAdjust?: (delta: number) => void
  private onLineSelect?: (text: string, key: string) => void
  private onSwipeProject?: (dir: 'left' | 'right') => void
  private onChoiceTap?: (num: string, isBlank: boolean, choiceGroupId: number) => void  // 点击选项按钮
  // 内部滚容器尺寸跟踪
  private _scrollContentHeight: number = 0
  private _scrollContainerHeight: number = 0
  private _scrollOffsetY: number = 0
  private _followBottom: boolean = true

  build() {
    Column() {
      // 顶部内发光装饰条
      Row()
        .width('60%').height(2)
        .borderRadius(1)
        .linearGradient({
          direction: GradientDirection.Right,
          colors: [['rgba(217,119,87,0)', 0], ['rgba(217,119,87,0.30)', 0.5], ['rgba(217,119,87,0)', 1]]
        })
        .position({ x: '20%', y: 0 })
        .zIndex(2)

      Scroll(this.scroller) {
        Column() {
          // 启动横幅（独立 @Component）
          if (this.showBanner) {
            WelcomeBanner({ projectPath: this.projectName })
          }
          ForEach(this.renderLines, (line: TerminalLineData, idx: number) => {
            TerminalLine({
              segments: line.segments, kind: line.kind, text: line.text,
              fontSize: this.fontSize,
              copySelected: this.selectedLineKey === line.timestamp.toString() + '_' + idx.toString(),
              thinkingDuration: line.thinkingDuration,
              choiceGroupId: line.choiceGroupId,
              selected: line.selected,
              locked: line.locked,
              collapsible: line.kind === 'prompt',
              collapsed: line.blockId >= 0 && this.collapsed.indexOf(line.blockId) >= 0,
              onToggleCollapse: () => {
                if (this.onToggleCollapse) this.onToggleCollapse(line.blockId)
              },
              onChoiceTap: (num: string, isBlank: boolean, choiceGroupId: number) => {
                if (this.onChoiceTap) this.onChoiceTap(num, isBlank, choiceGroupId)
              },
              onLineTap: (text: string) => {
                if (this.onLineSelect) this.onLineSelect(text, line.timestamp.toString() + '_' + idx.toString())
              }
            })
          }, (line: TerminalLineData, idx: number) => line.timestamp.toString() + '_' + idx.toString())
          if (this.executing) {
            Row() {
              LoadingProgress().width(14).height(14).color(currentTheme().accent)
              Text(' ' + agentDisplayName(this.agentType) + ' is thinking…').fontSize(this.fontSize).fontColor(currentTheme().system).fontFamily('monospace').margin({ left: 8 })
            }.padding({ top: 4, bottom: 4 })
          }
          Row().height(4)
        }.width('100%').padding({ left: 10, right: 10, top: 6, bottom: 6 }).alignItems(HorizontalAlign.Start)
          .onAreaChange((_: Area, newArea: Area) => {
            const h = newArea.height
            const nextHeight = typeof h === 'number' ? h : 0
            const oldMaxScroll = Math.max(0, this._scrollContentHeight - this._scrollContainerHeight)
            const wasAtBottom = this._followBottom || oldMaxScroll <= 0 || this._scrollOffsetY >= oldMaxScroll - 50
            const contentGrew = nextHeight > this._scrollContentHeight
            this._scrollContentHeight = nextHeight
            if (contentGrew && wasAtBottom) {
              setTimeout(() => {
                if (this._followBottom) this.scroller.scrollEdge(Edge.Bottom)
              }, 30)
            }
          })
      }
      .width('100%').layoutWeight(1)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.On)
      .scrollBarColor('rgba(201,139,117,0.72)')
      .scrollBarWidth(3)
      .edgeEffect(EdgeEffect.None).align(Alignment.TopStart)
      .onAreaChange((_: Area, newArea: Area) => {
        const h = newArea.height
        this._scrollContainerHeight = typeof h === 'number' ? h : 0
      })
      .onScroll((_: number, y: number) => {
        this._scrollOffsetY = y
        const maxScrollVp = Math.max(0, this._scrollContentHeight - this._scrollContainerHeight)
        this._followBottom = maxScrollVp <= 0 || y >= maxScrollVp - 50
        if (this.onScrollChanged) {
          this.onScrollChanged(!this._followBottom)
        }
      })
      .gesture(
        GestureGroup(GestureMode.Exclusive,
          PinchGesture({ fingers: 2 })
            .onActionEnd((e: GestureEvent) => {
              if (this.onFontAdjust) this.onFontAdjust(e.scale > 1 ? 1 : -1)
            }),
          PanGesture({ direction: PanDirection.Horizontal, distance: 60 })
            .onActionEnd((e: GestureEvent) => {
              if (this.onSwipeProject) this.onSwipeProject(e.offsetX > 0 ? 'right' : 'left')
            })
        )
      )
    }
    .width('100%').layoutWeight(1)
    .padding(4)
    .backgroundColor('#0F1319')
    .borderRadius(6)
    .border({ width: 1, color: 'rgba(30,37,48,0.80)' })
    .shadow({
      radius: 16,
      color: 'rgba(0,0,0,0.30)',
      offsetX: 0,
      offsetY: 4
    })
  }
}
