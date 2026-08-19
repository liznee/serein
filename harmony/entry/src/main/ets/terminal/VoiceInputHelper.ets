/**
 * VoiceInputHelper — 语音输入辅助类
 *
 * 封装 HMS CoreSpeechKit 语音识别能力 (API 11+ @kit.CoreSpeechKit)，
 * 提供长按录音 → 语音转文字 → 回调返回识别文本。
 *
 * 核心流程：createEngine → setListener → startListening → AudioCapturer 采集麦克风 →
 *           writeAudio 喂给引擎 → finish → onResult 回调
 *
 * 权限: ohos.permission.MICROPHONE (已在 module.json5 配置)
 * 系统能力: SystemCapability.AI.SpeechRecognizer + SystemCapability.Multimedia.Audio.Capturer
 */
import { abilityAccessCtrl, common } from '@kit.AbilityKit'
import { speechRecognizer } from '@kit.CoreSpeechKit'
import { audio } from '@kit.AudioKit'
import { BusinessError } from '@kit.BasicServicesKit'

interface PermissionRequestResult {
  authResults: number[]
}

export enum VoiceState {
  IDLE = 'idle',
  RECORDING = 'recording',
  ERROR = 'error',
  UNAVAILABLE = 'unavailable',
}

export interface VoiceCallbacks {
  onResult: (text: string, isFinal: boolean) => void
  onStateChange: (state: VoiceState) => void
  onError: (message: string) => void
}

export class VoiceInputHelper {
  private callbacks: VoiceCallbacks | null = null
  private state: VoiceState = VoiceState.IDLE
  private engine: speechRecognizer.SpeechRecognitionEngine | null = null
  private engineFailed: boolean = false
  private sessionId: string = ''
  private lastPartialText: string = ''  // 最后一次部分识别结果
  private gotFinalResult: boolean = false  // 是否已收到最终结果
  // 音频采集器：从麦克风读取 PCM 数据喂给识别引擎
  private audioCapturer: audio.AudioCapturer | null = null
  private captureActive: boolean = false  // 采集循环控制标志
  private finishing: boolean = false  // stopListening 防重入：finish 调用后到 onComplete 前的窗口

  get currentState(): VoiceState { return this.state }
  get isAvailable(): boolean { return !this.engineFailed }

  setCallbacks(cb: VoiceCallbacks): void { this.callbacks = cb }

  private async loadEngine(): Promise<boolean> {
    if (this.engine) return true
    if (this.engineFailed) return false
    // 先尝试在线识别，失败回退离线
    // online 参数类型为 number：1=在线, 0=离线。先在线(1)后离线(0)。
    for (const onlineMode of [1, 0]) {
      try {
        this.engine = await speechRecognizer.createEngine({
          language: 'zh-CN',
          online: onlineMode
        }) as Object as speechRecognizer.SpeechRecognitionEngine
        console.info('[VoiceInput] 引擎创建成功 mode=' + (onlineMode === 1 ? 'online' : 'offline'))
        return true
      } catch (e) {
        const err = e as BusinessError
        console.error('[VoiceInput] 引擎创建失败 mode=' + (onlineMode === 1 ? 'online' : 'offline') + ' code=' + err.code + ' msg=' + err.message)
        // 1002200001=创建失败 100220021=服务不可用(HMS Core未装/版本低)
      }
    }
    this.engineFailed = true
    this.state = VoiceState.UNAVAILABLE
    this.callbacks?.onStateChange(VoiceState.UNAVAILABLE)
    this.callbacks?.onError('语音引擎不可用：请确认已安装 HMS Core 并更新到最新版本')
    return false
  }

  private async requestPermission(context: common.Context): Promise<boolean> {
    try {
      const atMan = abilityAccessCtrl.createAtManager()
      const granted = await atMan.checkAccessToken(
        context.applicationInfo.accessTokenId,
        'ohos.permission.MICROPHONE'
      )
      if (granted === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) return true
      const data: PermissionRequestResult = await atMan.requestPermissionsFromUser(
        context, ['ohos.permission.MICROPHONE']
      ) as PermissionRequestResult
      return data?.authResults?.[0] === 0
    } catch (e) {
      console.error('[VoiceInput] 权限申请失败: ' + (e as Error).message)
      return false
    }
  }

  private genSessionId(): string {
    const chars = 'abcdefghijklmnopqrstuvwxyz0123456789'
    let id = ''
    for (let i = 0; i < 16; i++) id += chars.charAt(Math.floor(Math.random() * chars.length))
    return 'voice_' + id
  }

  async startListening(context?: common.Context): Promise<boolean> {
    if (this.state === VoiceState.RECORDING) return true
    this.finishing = false  // 重置防重入标志
    // context 必须提供（权限检查需要）
    if (!context) {
      this.callbacks?.onError('无法获取应用上下文')
      return false
    }
    const ok = await this.requestPermission(context)
    if (!ok) {
      this.callbacks?.onError('需要麦克风权限')
      return false
    }
    const loaded = await this.loadEngine()
    if (!loaded) return false

    // 重置状态
    this.lastPartialText = ''
    this.gotFinalResult = false

    try {
      this.sessionId = this.genSessionId()
      const eng = this.engine!
      eng.setListener({
        onStart: (_sid: string, _msg: string) => {
          console.info('[VoiceInput] 引擎 onStart')
        },
        onEvent: (_sid: string, _code: number, _msg: string) => {},
        onResult: (_sid: string, result: speechRecognizer.SpeechRecognitionResult) => {
          // 直接访问 SpeechRecognitionResult 的属性
          const text: string = result.result ?? ''
          const isLast: boolean = result.isLast ?? false
          console.info('[VoiceInput] onResult text=' + text + ' isLast=' + isLast)
          if (text.length > 0) {
            this.lastPartialText = text
          }
          if (isLast) {
            this.gotFinalResult = true
            if (text.length > 0) {
              this.callbacks?.onResult(text, true)
            } else if (this.lastPartialText.length > 0) {
              // 最终结果为空但之前有部分结果：用部分结果作为最终结果
              this.callbacks?.onResult(this.lastPartialText, true)
            }
          } else if (text.length > 0) {
            this.callbacks?.onResult(text, false)
          }
        },
        onComplete: (_sid: string, _msg: string) => {
          console.info('[VoiceInput] onComplete')
          this.finishing = false
          // 如果未收到最终结果但有部分结果，用部分结果作为最终结果
          if (!this.gotFinalResult && this.lastPartialText.length > 0) {
            this.callbacks?.onResult(this.lastPartialText, true)
          }
          this.state = VoiceState.IDLE
          this.callbacks?.onStateChange(VoiceState.IDLE)
        },
        onError: (_sid: string, code: number, msg: string) => {
          console.error('[VoiceInput] 识别错误 code=' + code + ' msg=' + msg)
          this.finishing = false
          this.stopAudioCapture()
          this.state = VoiceState.ERROR
          this.callbacks?.onError('识别失败(code=' + code + ')')
          this.callbacks?.onStateChange(VoiceState.ERROR)
        },
      })

      eng.startListening({
        sessionId: this.sessionId,
        audioInfo: {
          audioType: 'pcm',
          sampleRate: 16000,
          soundChannel: 1,
          sampleBit: 16,
        }
      })

      this.state = VoiceState.RECORDING
      this.callbacks?.onStateChange(VoiceState.RECORDING)
      console.info('[VoiceInput] 开始录音 session=' + this.sessionId)

      // 启动麦克风音频采集，将 PCM 数据喂给识别引擎
      await this.startAudioCapture()

      return true
    } catch (e) {
      const err = e as BusinessError
      console.error('[VoiceInput] 启动失败: code=' + err.code + ' msg=' + err.message)
      this.state = VoiceState.ERROR
      this.callbacks?.onError('启动录音失败(code=' + err.code + ')')
      this.callbacks?.onStateChange(VoiceState.ERROR)
      return false
    }
  }

  /**
   * 创建 AudioCapturer 采集麦克风 PCM 数据，循环读取并喂给识别引擎。
   * 音频格式：16kHz / 单声道 / 16-bit PCM，与 startListening 的 audioInfo 一致。
   */
  private async startAudioCapture(): Promise<void> {
    try {
      const streamInfo: audio.AudioStreamInfo = {
        samplingRate: audio.AudioSamplingRate.SAMPLE_RATE_16000,
        channels: audio.AudioChannel.CHANNEL_1,
        sampleFormat: audio.AudioSampleFormat.SAMPLE_FORMAT_S16LE,
        encodingType: audio.AudioEncodingType.ENCODING_TYPE_RAW
      }
      const capturerInfo: audio.AudioCapturerInfo = {
        source: audio.SourceType.SOURCE_TYPE_MIC,
        capturerFlags: 0
      }
      const options: audio.AudioCapturerOptions = {
        streamInfo: streamInfo,
        capturerInfo: capturerInfo
      }

      this.audioCapturer = await audio.createAudioCapturer(options)
      await this.audioCapturer.start()
      this.captureActive = true
      console.info('[VoiceInput] AudioCapturer 启动成功')

      // 开始循环读取音频数据
      this.feedAudioLoop()
    } catch (e) {
      console.error('[VoiceInput] AudioCapturer 启动失败: ' + (e as Error).message)
      this.callbacks?.onError('麦克风采集启动失败: ' + (e as Error).message)
    }
  }

  /**
   * 循环读取麦克风音频数据并喂给识别引擎。
   * 每次 read 100ms 音频（16kHz × 16bit × mono = 3200 bytes/100ms），
   * 通过 setTimeout(0) 避免递归调用栈溢出。
   */
  private feedAudioLoop(): void {
    if (!this.captureActive || !this.audioCapturer || !this.engine || this.state !== VoiceState.RECORDING) {
      return
    }
    // 100ms of 16kHz 16-bit mono = 16000 * 2 * 1 * 0.1 = 3200 bytes
    const bufferSize = 3200
    try {
      this.audioCapturer.read(bufferSize, true).then((audioData: ArrayBuffer) => {
        if (audioData.byteLength > 0 && this.engine && this.state === VoiceState.RECORDING) {
          this.engine.writeAudio(this.sessionId, new Uint8Array(audioData))
        }
        if (this.captureActive && this.state === VoiceState.RECORDING) {
          setTimeout(() => this.feedAudioLoop(), 0)
        }
      }).catch((e: Error) => {
        console.error('[VoiceInput] 音频读取失败: ' + e.message)
        if (this.captureActive && this.state === VoiceState.RECORDING) {
          setTimeout(() => this.feedAudioLoop(), 0)
        }
      })
    } catch (e) {
      console.error('[VoiceInput] 音频读取异常: ' + (e as Error).message)
      if (this.captureActive && this.state === VoiceState.RECORDING) {
        setTimeout(() => this.feedAudioLoop(), 0)
      }
    }
  }

  /**
   * 停止音频采集：先标记 captureActive=false 终止循环，再 stop+release capturer。
   */
  private stopAudioCapture(): void {
    this.captureActive = false
    if (this.audioCapturer) {
      try {
        this.audioCapturer.stop()
      } catch (_) {}
      try {
        this.audioCapturer.release()
      } catch (_) {}
      this.audioCapturer = null
      console.info('[VoiceInput] AudioCapturer 已释放')
    }
  }

  stopListening(): void {
    if (this.state !== VoiceState.RECORDING || !this.engine) return
    if (this.finishing) return  // 防重入：已在等待 onComplete
    this.finishing = true
    // 先停止音频采集，确保不再喂入新数据
    this.stopAudioCapture()
    try {
      this.engine.finish(this.sessionId)
      console.info('[VoiceInput] 停止录音，等待最终识别结果')
    } catch (e) {
      console.error('[VoiceInput] 停止失败: ' + (e as Error).message)
      this.finishing = false
      this.state = VoiceState.IDLE
      this.callbacks?.onStateChange(VoiceState.IDLE)
    }
    // 注意：不立即将状态设为 IDLE，等 onComplete 回调来设置
    // 这样可以确保最终识别结果能被正确回调
  }

  release(): void {
    this.stopAudioCapture()
    try {
      this.stopListening()
      this.engine?.shutdown()
    } catch (_) {}
    this.engine = null
    this.state = VoiceState.UNAVAILABLE
  }
}
