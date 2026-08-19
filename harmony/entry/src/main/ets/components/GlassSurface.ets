// ===== 暗色表面通用容器（SurfaceCard） =====
// 替代原来的液态玻璃效果，暗色模式用 1px 边框 + 颜色分层
import { SURFACE, RADIUS } from '../utils/DesignTokens'

@Component
export struct GlassSurface {
  @Prop borderRadius: number = RADIUS.md
  /** true=加上 border 分隔, false=纯色面 */
  @Prop bordered: boolean = true
  @BuilderParam content: () => void

  build() {
    Stack() {
      this.content()
    }
    .backgroundColor(SURFACE.card)
    .borderRadius(this.borderRadius)
    .border(this.bordered ? { width: 1, color: SURFACE.border } : { width: 0 })
  }
}
