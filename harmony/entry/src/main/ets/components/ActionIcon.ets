// ===== 矢量图标组件 =====
import { IconPaths } from '../utils/IconPaths'
import { ICON, TOUCH } from '../utils/DesignTokens'

export enum ActionIconType {
  BACK = 'back', STATUS = 'status', REFRESH = 'refresh',
  HISTORY = 'history', SETTINGS = 'settings', CLOSE = 'close'
}

@Component
export struct ActionIcon {
  @Prop iconType: ActionIconType = ActionIconType.STATUS
  @Prop connected: boolean = true
  @Prop iconSize: number = ICON.action
  @Prop color: string = ''
  @Prop withPadding: boolean = true

  private strokeClr(): string {
    if (this.color !== '') return this.color
    if (this.iconType === ActionIconType.BACK) return '#0A84FF'
    if (this.iconType === ActionIconType.STATUS) return this.connected ? '#22C55E' : '#F59E0B'
    return '#6E6E73'
  }

  private clr(): string { return this.strokeClr() }

  build() {
    Row() {
      Shape() {
        if (this.iconType === ActionIconType.BACK) {
          Path().commands(IconPaths.BACK).stroke(this.clr()).strokeWidth(2.5).strokeLineJoin(LineJoinStyle.Round).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
        } else if (this.iconType === ActionIconType.REFRESH) {
          Path().commands(IconPaths.REFRESH_ARROW).stroke(this.clr()).strokeWidth(2.5).strokeLineJoin(LineJoinStyle.Round).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands(IconPaths.REFRESH_ARROW2).stroke(this.clr()).strokeWidth(2.5).strokeLineJoin(LineJoinStyle.Round).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
        } else if (this.iconType === ActionIconType.HISTORY) {
          Path().commands(IconPaths.HISTORY_CLOCK).stroke(this.clr()).strokeWidth(2.5).strokeLineJoin(LineJoinStyle.Round).fillOpacity(0)
          Path().commands(IconPaths.HISTORY_HAND).stroke(this.clr()).strokeWidth(2.5).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands(IconPaths.HISTORY_MHAND).stroke(this.clr()).strokeWidth(2).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands(IconPaths.HISTORY_REV_ARC).stroke(this.clr()).strokeWidth(2.5).strokeLineJoin(LineJoinStyle.Round).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands(IconPaths.HISTORY_REV_HEAD).stroke(this.clr()).strokeWidth(2.5).strokeLineJoin(LineJoinStyle.Round).strokeLineCap(LineCapStyle.Round).fill(this.clr())
        } else if (this.iconType === ActionIconType.SETTINGS) {
          Path().commands(IconPaths.SLIDER1_LINE).stroke(this.clr()).strokeWidth(2.5).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands(IconPaths.SLIDER1_DOT).stroke(this.clr()).strokeWidth(2.5).fill(this.clr())
          Path().commands(IconPaths.SLIDER2_LINE).stroke(this.clr()).strokeWidth(2.5).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands(IconPaths.SLIDER2_DOT).stroke(this.clr()).strokeWidth(2.5).fill(this.clr())
          Path().commands(IconPaths.SLIDER3_LINE).stroke(this.clr()).strokeWidth(2.5).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands(IconPaths.SLIDER3_DOT).stroke(this.clr()).strokeWidth(2.5).fill(this.clr())
        } else if (this.iconType === ActionIconType.STATUS) {
          Path().commands('M3 19 L3 15').stroke(this.clr()).strokeWidth(2.5).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands('M8 19 L8 9').stroke(this.clr()).strokeWidth(2.5).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands('M13 19 L13 4').stroke(this.clr()).strokeWidth(2.5).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
          Path().commands('M18 19 L18 11').stroke(this.clr()).strokeWidth(2.5).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
        } else if (this.iconType === ActionIconType.CLOSE) {
          Path().commands(IconPaths.CLOSE).stroke(this.clr()).strokeWidth(2.5).strokeLineJoin(LineJoinStyle.Round).strokeLineCap(LineCapStyle.Round).fillOpacity(0)
        }
      }
      .width(this.iconSize)
      .height(this.iconSize)
      .viewPort({ x: 0, y: 0, width: 24, height: 24 })
    }
    .width(this.withPadding ? TOUCH.min : this.iconSize)
    .height(this.withPadding ? TOUCH.min : this.iconSize)
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }
}
