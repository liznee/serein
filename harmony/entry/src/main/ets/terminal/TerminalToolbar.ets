/**
 * TerminalToolbar — 特殊键扩展工具栏
 * 提供终端常用特殊键：Tab, Esc, |, /, ↑, ↓, ←, →
 * 位于输入栏上方，手机无物理键盘的补偿方案
 *
 * 设计语言（与 terminal-unified.html 对齐）：
 *   - 所有按键共享统一的 border / color / press 反馈
 *   - 按键为紧凑圆角矩形（keyboard feel）
 *   - 分隔符为 1px 竖线
 */
@Component
export struct TerminalToolbar {
  onKeyTap?: (key: string) => void
  private readonly BORDER: string = 'rgba(140,144,159,0.12)'
  private readonly BORDER_ACTIVE: string = 'rgba(217,119,87,0.50)'
  private readonly TEXT_DIM: string = '#8C909F'
  private readonly TEXT_ACTIVE: string = '#D97757'
  private readonly BG: string = 'rgba(17,22,29,0.95)'
  private readonly SEP: string = 'rgba(140,144,159,0.10)'

  build() {
    Row() {
      // 修改键组
      this.keyBtn('Tab', 14)
      this.keyBtn('Esc', 14)

      // 分隔
      Row().width(1).height(12).backgroundColor(this.SEP).margin({ left: 6, right: 6 })

      // 管道/路径
      this.keyBtn('|', 14)
      this.keyBtn('/', 14)

      // 分隔
      Row().width(1).height(12).backgroundColor(this.SEP).margin({ left: 6, right: 6 })

      // 方向键（Unicode 箭头在等宽字体中渲染偏小，用更大字号补偿）
      this.keyBtn('↑', 18)
      this.keyBtn('↓', 18)
      this.keyBtn('←', 18)
      this.keyBtn('→', 18)
    }
    .width('100%')
    .height(40)
    .padding({ left: 12, right: 12 })
    .backgroundColor(this.BG)
    .justifyContent(FlexAlign.Start)
    .alignItems(VerticalAlign.Center)
    .border({ width: { top: 1 }, color: this.SEP })
  }

  @Builder
  keyBtn(label: string, fSize: number) {
    Text(label)
      .fontSize(fSize)
      .fontColor(this.TEXT_DIM)
      .fontFamily('monospace')
      .textAlign(TextAlign.Center)
      .constraintSize({ minWidth: label.length > 1 ? 36 : 32 })
      .height(32)
      .padding({ left: 8, right: 8 })
      .borderRadius(6)
      .backgroundColor(Color.Transparent)
      .border({ width: 1, color: this.BORDER })
      .margin({ right: 4 })
      .onClick(() => {
        if (this.onKeyTap) {
          this.onKeyTap(label)
        }
      })
      .hoverEffect(HoverEffect.Highlight)
      .stateStyles({
        pressed: {
          .backgroundColor('rgba(217,119,87,0.08)')
          .border({ width: 1, color: this.BORDER_ACTIVE })
          .fontColor(this.TEXT_ACTIVE)
        }
      })
  }
}
