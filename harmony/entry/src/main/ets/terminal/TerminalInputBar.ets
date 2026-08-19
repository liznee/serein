/**
 * TerminalInputBar — 终端命令输入栏
 * > 前缀 + TextInput + 圆形按钮（语音/上传/发送）
 *
 * 设计语言（与 terminal-unified.html 对齐）：
 *   - 输入行：> prompt + 透明背景 TextInput + 圆形操作按钮
 *   - 语音/上传按钮：36px 圆形，透明背景，border 边框
 *   - 发送按钮：36px 圆形，珊瑚色填充
 *   - 所有按钮共享 border color、hover glow、press scale 反馈
 *
 * 语音输入：长按"语音"按钮开始录音，松手停止，识别结果填入输入框
 */
import { promptAction } from '@kit.ArkUI'
import { common } from '@kit.AbilityKit'
import { currentTheme } from './TerminalTheme'
import { VoiceInputHelper, VoiceState } from './VoiceInputHelper'

@Component
export struct TerminalInputBar {
  @Prop inputText: string = ''
  @Prop connected: boolean = true
  @Prop executing: boolean = false
  onChange?: (text: string) => void
  onSubmit?: (text: string) => void
  onFilePick?: () => void
  onVoiceError?: (message: string) => void
  private lastSubmitAt: number = 0
  private voiceHelper: VoiceInputHelper = new VoiceInputHelper()
  @State voiceState: VoiceState = VoiceState.IDLE
  @State voiceText: string = ''
  private destroyed: boolean = false
  private uiContext: common.Context | null = null

  // ── 设计 tokens（与 terminal-unified.html 对齐）──
  private readonly BORDER: string = 'rgba(140,144,159,0.15)'
  private readonly BORDER_ACTIVE: string = 'rgba(217,119,87,0.50)'
  private readonly TEXT_DIM: string = '#8C909F'
  private readonly TEXT: string = '#F1F5F9'
  private readonly ACCENT: string = '#D97757'
  private readonly ACCENT_DIM: string = 'rgba(217,119,87,0.08)'
  private readonly BG: string = 'rgba(17,22,29,0.95)'
  private readonly SEP: string = 'rgba(140,144,159,0.10)'
  private readonly BTN_SIZE: number = 36

  aboutToAppear(): void {
    this.uiContext = getContext(this) as common.Context
    this.voiceHelper.setCallbacks({
      onResult: (text: string, isFinal: boolean) => {
        if (this.destroyed) return
        if (isFinal && text.length > 0) {
          this.voiceText = ''
          // 追加到现有文本末尾，而非覆盖整个输入框
          const existing = this.inputText
          const separator = existing.length > 0 && !existing.endsWith(' ') ? ' ' : ''
          const newText = existing + separator + text
          if (this.onChange) { this.onChange(newText) }
          promptAction.showToast({ message: '语音识别完成', duration: 1000 })
        } else if (!isFinal && text.length > 0) {
          this.voiceText = text
        }
      },
      onStateChange: (state: VoiceState) => {
        if (this.destroyed) return
        this.voiceState = state
      },
      onError: (message: string) => {
        if (this.destroyed) return
        console.error('[VoiceInput] ' + message)
        this.voiceText = message
        promptAction.showToast({ message: message, duration: 3000 })
        if (this.onVoiceError) { this.onVoiceError(message) }
      },
    })
  }

  aboutToDisappear(): void {
    this.destroyed = true
    this.voiceHelper.release()
  }

  private trySubmit(): void {
    if (this.inputText.trim() === '') return
    const now = Date.now()
    if (now - this.lastSubmitAt < 500) return
    this.lastSubmitAt = now
    if (this.onSubmit) {
      this.onSubmit(this.inputText)
    }
  }

  private promptColor(): string {
    if (!this.connected) return this.TEXT_DIM
    return this.inputText.startsWith('/!') ? '#d99260' : this.ACCENT
  }
  private promptLabel(): string {
    if (this.inputText.startsWith('/!')) return '!_'
    if (this.inputText.startsWith('/')) return '/_'
    return '>'
  }

  private onMicLongPressStart(): void {
    if (this.voiceState === VoiceState.IDLE) {
      this.voiceHelper.startListening(this.uiContext ?? undefined)
    }
  }
  private onMicLongPressEnd(): void {
    if (this.voiceState === VoiceState.RECORDING) {
      this.voiceHelper.stopListening()
    }
  }
  private async onMicTap(): Promise<void> {
    if (this.voiceState === VoiceState.RECORDING) {
      this.voiceHelper.stopListening()
    } else if (this.voiceState === VoiceState.IDLE) {
      const ok = await this.voiceHelper.startListening(this.uiContext ?? undefined)
      if (!ok) {
        promptAction.showToast({ message: '语音启动失败，请检查 HMS Core 是否安装', duration: 3000 })
      }
    } else if (this.voiceState === VoiceState.ERROR) {
      promptAction.showToast({ message: '语音识别出错，请重试', duration: 2000 })
    } else {
      promptAction.showToast({ message: '语音引擎不可用，请检查设备是否支持', duration: 3000 })
    }
  }

  build() {
    Column() {
      // ── 主输入行：> prompt + TextInput + 圆形按钮 ──
      Row() {
        // 提示符 >
        Text(this.promptLabel())
          .fontSize(15)
          .fontColor(this.promptColor())
          .fontFamily('monospace')
          .fontWeight(700)
          .margin({ left: 12, right: 6 })

        // 命令输入
        TextInput({ text: this.inputText, placeholder: 'type or speak...' })
          .fontSize(14)
          .fontColor(this.TEXT)
          .placeholderColor('#475569')
          .fontFamily('monospace')
          .layoutWeight(1)
          .height(44)
          .backgroundColor(Color.Transparent)
          .borderRadius(0)
          .enterKeyType(EnterKeyType.Send)
          .onChange((value: string) => {
            if (this.onChange) {
              this.onChange(value)
            }
          })
          .onSubmit(() => {
            this.trySubmit()
          })

        // ── 语音按钮（圆形）──
        Row() {
          // 麦克风 SVG 图标（录音中切换为 accent 色）
          Image(this.voiceState === VoiceState.RECORDING
            ? $r('app.media.mic_recording')
            : $r('app.media.mic_idle'))
            .width(15).height(15)
            .objectFit(ImageFit.Contain)
            .opacity(this.voiceState === VoiceState.UNAVAILABLE ? 0.4 : 1.0)
        }
        .width(this.BTN_SIZE)
        .height(this.BTN_SIZE)
        .justifyContent(FlexAlign.Center)
        .borderRadius(this.BTN_SIZE / 2)
        .backgroundColor(this.voiceState === VoiceState.RECORDING ? 'rgba(217,119,87,0.10)' : Color.Transparent)
        .border({ width: 1, color: this.voiceState === VoiceState.RECORDING ? this.ACCENT : this.BORDER })
        .margin({ left: 6 })
        .opacity(this.voiceState === VoiceState.UNAVAILABLE ? 0.4 : 1.0)
        .onClick(() => { this.onMicTap() })
        .gesture(
          LongPressGesture({ duration: 400 })
            .onAction(() => { this.onMicLongPressStart() })
            .onActionEnd(() => { this.onMicLongPressEnd() })
        )

        // ── 文件上传按钮（圆形）──
        Row() {
          Image($r('app.media.upload'))
            .width(15).height(15)
            .objectFit(ImageFit.Contain)
        }
        .width(this.BTN_SIZE)
        .height(this.BTN_SIZE)
        .justifyContent(FlexAlign.Center)
        .borderRadius(this.BTN_SIZE / 2)
        .backgroundColor(Color.Transparent)
        .border({ width: 1, color: this.BORDER })
        .margin({ left: 6 })
        .onClick(() => {
          if (this.onFilePick) {
            this.onFilePick()
          }
        })

        // ── 发送按钮（圆形，珊瑚色填充）──
        // 思考中不阻塞发送：用户可随时输入补充问题
        Row() {
          Image(this.connected ? $r('app.media.send') : $r('app.media.send_dim'))
            .width(15).height(15)
            .objectFit(ImageFit.Contain)
        }
        .width(this.BTN_SIZE)
        .height(this.BTN_SIZE)
        .justifyContent(FlexAlign.Center)
        .borderRadius(this.BTN_SIZE / 2)
        .backgroundColor(this.ACCENT)
        .border({ width: 1, color: this.ACCENT })
        .margin({ left: 6, right: 10 })
        .onClick(() => {
          this.trySubmit()
        })
      }
      .width('100%')
      .height(52)
      .alignItems(VerticalAlign.Center)
      .backgroundColor(this.BG)

      // ── 语音状态行（录音中/错误/识别文本）──
      if (this.voiceText !== '' || this.voiceState === VoiceState.RECORDING) {
        Row() {
          if (this.voiceState === VoiceState.RECORDING && this.voiceText === '') {
            Text('正在听...')
              .fontSize(12).fontColor(this.ACCENT).fontFamily('monospace')
          } else {
            Text(this.voiceText)
              .fontSize(12).fontColor(
                this.voiceState === VoiceState.ERROR ? '#b53333' : '#d99260'
              ).fontFamily('monospace')
              .maxLines(2).textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
        }
        .width('100%')
        .height(28)
        .padding({ left: 12, right: 12 })
        .alignItems(VerticalAlign.Center)
        .backgroundColor(this.BG)
      }
    }
    .width('100%')
    .backgroundColor(this.BG)
    .backdropBlur(12)
    .border({ width: { top: 1 }, color: this.SEP })
  }
}
