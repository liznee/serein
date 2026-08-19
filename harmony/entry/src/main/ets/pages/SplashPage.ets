import { router } from '@kit.ArkUI'
import { hasBackendUrl } from '../state/AppStore'

/**
 * SplashPage — 启动页
 * 从 splash.html (Open Design) 转换为 ArkTS 原生组件
 * 还原内容：背景辉光 + 晶体 Logo + 淡入动画 + 加载点脉动 + 底部 monospace 文字
 */

@Entry
@Component
struct SplashPage {
  @State logoOpacity: number = 0
  @State logoOffsetY: number = 8
  @State nameOpacity: number = 0
  @State nameOffsetY: number = 8
  @State loaderOpacity: number = 0
  @State loaderOffsetY: number = 8
  @State dot1Scale: number = 0.8
  @State dot2Scale: number = 0.8
  @State dot3Scale: number = 0.8
  @State dot1Color: string = '#87867F'
  @State dot2Color: string = '#87867F'
  @State dot3Color: string = '#87867F'
  @State footerOpacity: number = 0

  private dotTimer: number = -1
  private settings: RenderingContextSettings = new RenderingContextSettings(true)
  private crystalCtx: CanvasRenderingContext2D = new CanvasRenderingContext2D(this.settings)

  aboutToAppear(): void {
    // ── 淡入动画（缩短版）──
    setTimeout(() => {
      animateTo({ duration: 400, curve: Curve.EaseOut }, () => {
        this.logoOpacity = 1
        this.logoOffsetY = 0
      })
    }, 50)

    setTimeout(() => {
      animateTo({ duration: 400, curve: Curve.EaseOut }, () => {
        this.nameOpacity = 1
        this.nameOffsetY = 0
      })
    }, 150)

    setTimeout(() => {
      animateTo({ duration: 400, curve: Curve.EaseOut }, () => {
        this.loaderOpacity = 1
        this.loaderOffsetY = 0
        this.footerOpacity = 0.5
      })
    }, 250)

    // 加载点脉动动画
    this.startDotPulse()

    // 1.2s 后根据配置状态跳转：
    //   无后端地址 → PairPage（输入地址）
    //   有后端地址 → MainTabs（配对通过扫码 QR 完成）
    setTimeout(() => {
      if (hasBackendUrl()) {
        router.replaceUrl({ url: 'pages/MainTabs' })
      } else {
        router.replaceUrl({ url: 'pages/PairPage' })
      }
    }, 1200)
  }

  aboutToDisappear(): void {
    if (this.dotTimer >= 0) {
      clearInterval(this.dotTimer)
      this.dotTimer = -1
    }
  }

  // ── 加载点脉动（对应 CSS @keyframes dotPulse）──
  // 0%→40%: muted→accent, scale 0.8→1.2
  // 40%→80%: accent→muted, scale 1.2→0.8
  // 80%→100%: muted, scale 0.8
  // 3 个点分别 delay 0/0.2s/0.4s
  private startDotPulse(): void {
    const startTime = Date.now()
    this.dotTimer = setInterval(() => {
      const elapsed = Date.now() - startTime
      this.updateDotState(0, elapsed, 0)
      this.updateDotState(1, elapsed, 200)
      this.updateDotState(2, elapsed, 400)
    }, 50)
  }

  private updateDotState(index: number, elapsed: number, delay: number): void {
    const cycle = 1400
    let t = (elapsed - delay) % cycle
    if (t < 0) t += cycle
    const phase = t / cycle

    let scale: number
    let color: string
    if (phase < 0.4) {
      const p = phase / 0.4
      scale = 0.8 + 0.4 * p
      color = this.lerpColor('#87867F', '#D97757', p)
    } else if (phase < 0.8) {
      const p = (phase - 0.4) / 0.4
      scale = 1.2 - 0.4 * p
      color = this.lerpColor('#D97757', '#87867F', p)
    } else {
      scale = 0.8
      color = '#87867F'
    }

    if (index === 0) { this.dot1Scale = scale; this.dot1Color = color }
    else if (index === 1) { this.dot2Scale = scale; this.dot2Color = color }
    else { this.dot3Scale = scale; this.dot3Color = color }
  }

  private lerpColor(c1: string, c2: string, t: number): string {
    const r1 = parseInt(c1.substring(1, 3), 16)
    const g1 = parseInt(c1.substring(3, 5), 16)
    const b1 = parseInt(c1.substring(5, 7), 16)
    const r2 = parseInt(c2.substring(1, 3), 16)
    const g2 = parseInt(c2.substring(3, 5), 16)
    const b2 = parseInt(c2.substring(5, 7), 16)
    const r = Math.round(r1 + (r2 - r1) * t)
    const g = Math.round(g1 + (g2 - g1) * t)
    const b = Math.round(b1 + (b2 - b1) * t)
    const hex = (v: number) => v.toString(16).padStart(2, '0')
    return '#' + hex(r) + hex(g) + hex(b)
  }

  // ── 绘制晶体 Logo（Canvas 还原 SVG polygon）──
  // SVG group translate(60,58) 已合并到各顶点坐标
  // v0(60,14) v1(102,49) v2(96,82) v3(55,96) v4(22,78) v5(20,42) vc(68,92)
  private drawCrystal(): void {
    const ctx = this.crystalCtx
    ctx.clearRect(0, 0, 120, 120)

    // 辉光椭圆
    ctx.fillStyle = 'rgba(217,119,87,0.08)'
    ctx.beginPath()
    ctx.arc(60, 60, 36, 0, Math.PI * 2)
    ctx.fill()

    // top face — v0, v1, vc
    ctx.fillStyle = '#e18260'
    ctx.beginPath()
    ctx.moveTo(60, 14); ctx.lineTo(102, 49); ctx.lineTo(68, 92)
    ctx.closePath(); ctx.fill()

    // right face — v1, v2, vc
    ctx.fillStyle = '#c96442'
    ctx.beginPath()
    ctx.moveTo(102, 49); ctx.lineTo(96, 82); ctx.lineTo(68, 92)
    ctx.closePath(); ctx.fill()

    // br face — v2, v3, vc
    ctx.fillStyle = '#af4e32'
    ctx.beginPath()
    ctx.moveTo(96, 82); ctx.lineTo(55, 96); ctx.lineTo(68, 92)
    ctx.closePath(); ctx.fill()

    // bottom face — v3, v4, vc
    ctx.fillStyle = '#963e28'
    ctx.beginPath()
    ctx.moveTo(55, 96); ctx.lineTo(22, 78); ctx.lineTo(68, 92)
    ctx.closePath(); ctx.fill()

    // bl face — v4, v5, vc
    ctx.fillStyle = '#af4e32'
    ctx.beginPath()
    ctx.moveTo(22, 78); ctx.lineTo(20, 42); ctx.lineTo(68, 92)
    ctx.closePath(); ctx.fill()

    // tl face — v5, v0, vc
    ctx.fillStyle = '#c96442'
    ctx.beginPath()
    ctx.moveTo(20, 42); ctx.lineTo(60, 14); ctx.lineTo(68, 92)
    ctx.closePath(); ctx.fill()

    // 中心核圆
    ctx.fillStyle = '#e18260'
    ctx.beginPath()
    ctx.arc(68, 92, 4.5, 0, Math.PI * 2)
    ctx.fill()
  }

  build() {
    Stack() {
      // ── 主内容（居中）──
      Column() {
        // 晶体 Logo
        Canvas(this.crystalCtx)
          .width(120)
          .height(120)
          .onReady(() => { this.drawCrystal() })
          .opacity(this.logoOpacity)
          .offset({ y: this.logoOffsetY })

        // 应用名称
        Column() {
          Text('Serein')
            .fontSize(36)
            .fontWeight(700)
            .fontColor('#FAF9F5')
            .letterSpacing(-1.08)
          Text('远程审批 · 命令行工具')
            .fontSize(14)
            .fontColor('#87867F')
            .margin({ top: 8 })
            .letterSpacing(0.28)
        }
        .alignItems(HorizontalAlign.Center)
        .margin({ top: 32 })
        .opacity(this.nameOpacity)
        .offset({ y: this.nameOffsetY })

        // 加载点
        Row() {
          Circle({ width: 6, height: 6 })
            .fill(this.dot1Color)
            .scale({ x: this.dot1Scale, y: this.dot1Scale, centerX: '50%', centerY: '50%' })

          Circle({ width: 6, height: 6 })
            .fill(this.dot2Color)
            .scale({ x: this.dot2Scale, y: this.dot2Scale, centerX: '50%', centerY: '50%' })
            .margin({ left: 10 })

          Circle({ width: 6, height: 6 })
            .fill(this.dot3Color)
            .scale({ x: this.dot3Scale, y: this.dot3Scale, centerX: '50%', centerY: '50%' })
            .margin({ left: 10 })
        }
        .margin({ top: 32 })
        .opacity(this.loaderOpacity)
        .offset({ y: this.loaderOffsetY })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      // ── 底部信息 ──
      Text('>_ initializing secure channel')
        .fontSize(12)
        .fontColor('#87867F')
        .fontFamily('monospace')
        .letterSpacing(0.72)
        .opacity(this.footerOpacity)
        .margin({ bottom: 48 })
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#0B0E12')
    .alignContent(Alignment.Bottom)
  }
}
