/**
 * MetricTile — 监控指标卡片组件
 *
 * 显示 CPU/RAM/DISK/GPU 等系统监控指标的迷你卡片，含数值、标签、sparkline 折线图和进度条。
 * 从 ProjectsPage.ets 提取为独立组件以减少页面文件体积。
 */
import { COLOR, SPACE, WEIGHT } from '../utils/DesignTokens'

@Component
export struct MetricTile {
  @Prop label: string
  @Prop value: string
  @Prop sub: string
  @Prop pct: number
  @Prop @Watch('onSparkChange') spark: number[] = []
  @Prop invertColor: boolean = false
  @Prop temp: string = ''  // 温度显示（如 '72°C'），空字符串隐藏
  private sparkSettings: RenderingContextSettings = new RenderingContextSettings(true)
  private sparkCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.sparkSettings)

  // 按 pct 阈值返回告警色。
  // 默认(CPU/DISK): 保持珊瑚色主视觉，仅在负载升高时逐步加深。
  // invert(TOKENS 命中率): 越高越接近主珊瑚色，低值使用克制的警示红。
  private alertColor(): string {
    if (this.invertColor) {
      if (this.pct >= 80) return '#D97757'
      if (this.pct >= 60) return '#E08A6A'
      return '#C85F52'
    }
    if (this.pct >= 80) return '#C85F52'
    if (this.pct >= 60) return '#E08A6A'
    return '#D97757'
  }

  build() {
    Column() {
      Row() {
        Text(this.label)
          .fontSize(11)
          .fontColor(COLOR.textTertiary)
          .fontWeight(WEIGHT.medium)
          .letterSpacing(1)
        Blank()
        Text('[' + (this.pct > 0 ? Math.floor(this.pct) + '%' : '--') + ']')
          .fontSize(11)
          .fontColor(this.alertColor())
          .fontFamily('monospace')
      }
      .width('100%')
      .margin({ bottom: SPACE.xs })

      Text(this.value)
        .fontSize(17)
        .fontWeight(WEIGHT.bold)
        .fontColor(COLOR.textPrimary)
        .fontFamily('monospace')
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .margin({ bottom: 2 })

      Text(this.sub)
        .fontSize(11)
        .fontColor(COLOR.textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      // sparkline 折线图（CPU/RAM/GPU 有趋势数据时显示）
      // 无数据时保留等高占位，确保 DISK 等无折线卡片的进度条与有折线卡片对齐
      if (this.spark.length > 1) {
        Canvas(this.sparkCtx)
          .width('100%')
          .height(24)
          .margin({ top: SPACE.sm })
          .onReady(() => { this.drawSpark() })
      } else {
        Row().width('100%').height(24).margin({ top: SPACE.sm })
      }

      // Progress bar（0% 也显示空线保证所有卡片对齐）
      Row() {
        Row() {
        }
        .width(Math.min(this.pct > 0 ? this.pct : 1, 100).toString() + '%')
        .height('100%')
        .backgroundColor(this.alertColor())
        .borderRadius(1)
      }
      .width('100%')
      .height(4)
      .backgroundColor(COLOR.divider)
      .borderRadius(2)
      .margin({ top: SPACE.sm })

      // 温度（固定高度 14vp，所有卡片一致）
      Row().height(14).width('100%').margin({ top: 2 }).alignItems(VerticalAlign.Center) {
        Text(this.temp !== '' ? this.temp : ' ').fontSize(9).fontColor('#C2C6D6')
      }
    }
    .width('100%')
    .height('100%')
    .padding(SPACE.sm)
    .justifyContent(FlexAlign.SpaceBetween)
  }

  /** @Watch: spark 数据变化时重绘 Canvas（onReady 仅首次挂载触发） */
  onSparkChange(): void {
    this.drawSpark()
  }

  /** 在 Canvas 上画迷你折线图 */
  private drawSpark(): void {
    const ctx = this.sparkCtx
    const w = ctx.width
    const h = ctx.height
    if (w <= 0 || h <= 0 || this.spark.length < 2) return
    ctx.clearRect(0, 0, w, h)
    const data = this.spark
    const n = data.length
    // 找最大最小值，忽略 0（0 = 无数据/未采集，不是真实利用率）
    // 否则 GPU 早期全 0 数据会把折线压成横线
    let min = -1
    let max = -1
    for (let i = 0; i < n; i++) {
      if (data[i] <= 0) continue
      if (min < 0 || data[i] < min) min = data[i]
      if (max < 0 || data[i] > max) max = data[i]
    }
    if (min < 0) { min = 0; max = 1 }  // 全是 0 的兜底
    if (min === max) { min = 0 }  // 单值时从 0 起，避免除零
    const range = max - min
    const pad = 3 // 上下留白
    const usableH = h - pad * 2
    const stepX = w / (n - 1)
    const color = this.alertColor()
    // 折线
    ctx.strokeStyle = color
    ctx.lineWidth = 1.5
    ctx.beginPath()
    for (let i = 0; i < n; i++) {
      const x = i * stepX
      const norm = range > 0 ? (data[i] - min) / range : 0.5
      const y = pad + usableH - norm * usableH
      if (i === 0) ctx.moveTo(x, y)
      else ctx.lineTo(x, y)
    }
    ctx.stroke()
    // 末端点（当前值高亮）
    const lastX = (n - 1) * stepX
    const lastNorm = range > 0 ? (data[n - 1] - min) / range : 0.5
    const lastY = pad + usableH - lastNorm * usableH
    ctx.fillStyle = color
    ctx.beginPath()
    ctx.arc(lastX, lastY, 2, 0, Math.PI * 2)
    ctx.fill()
  }
}
