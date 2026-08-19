﻿/**
 * FileUploadManager — 文件上传管理
 *
 * 从 TerminalPage.TerminalContent 提取，减少主文件代码行数。
 * 负责文件选择、上传到 PC 服务器、等待 WS 确认、超时处理。
 */
import { http } from '@kit.NetworkKit'
import { router } from '@kit.ArkUI'
import picker from '@ohos.file.picker'
import fileIo from '@ohos.file.fs'
import { common } from '@kit.AbilityKit'
import image from '@ohos.multimedia.image'
import { TerminalSession } from './TerminalSession'
import { KEY_CLIENT_TOKEN, handleAuthError } from '../state/AppStore'
import NavPath from '../model/NavPath'
import { currentTheme } from './TerminalTheme'

/** 文件上传管理回调 */
export interface FileUploadCallbacks {
  appendSystem(text: string, color: string): void
  syncLines(): void
  appendError(text: string): void
  submitCommand(cmd: string): void
  /** 直接分发 prompt（绕过 submitCommand 的 dedup 检查） */
  dispatchPrompt(cmd: string): void
  isDestroyed(): boolean
}

/** 文件上传回调绑定 */
export class FileUploadBinding implements FileUploadCallbacks {
  public appendSystem: (text: string, color: string) => void
  public syncLines: () => void
  public appendError: (text: string) => void
  public submitCommand: (cmd: string) => void
  public dispatchPrompt: (cmd: string) => void
  public isDestroyed: () => boolean
  constructor(
    appendSystem: (text: string, color: string) => void,
    syncLines: () => void,
    appendError: (text: string) => void,
    submitCommand: (cmd: string) => void,
    dispatchPrompt: (cmd: string) => void,
    isDestroyed: () => boolean,
  ) {
    this.appendSystem = appendSystem
    this.syncLines = syncLines
    this.appendError = appendError
    this.submitCommand = submitCommand
    this.dispatchPrompt = dispatchPrompt
    this.isDestroyed = isDestroyed
  }
}

export class FileUploadManager {
  private backendUrl: string = ''
  private session: TerminalSession
  private callbacks: FileUploadCallbacks
  private _terminalProject: string = ''
  private _context: common.Context | null = null
  // 文件上传 pending 状态（单文件串行：每次只追踪一个上传结果）
  private _pendingUploadCmdId: string = ''
  private _pendingUploadFileName: string = ''
  private _pendingUploadTimer: number = -1
  // Promise 等待：doUpload 上传成功后阻塞，直到 WS cmd_result 或超时
  private _uploadResolve: (() => void) | null = null
  // 429 重试状态（指数退避）
  private _retryCount: number = 0
  private _maxRetries: number = 3
  private _retryTimer: number = -1
  private _retryUri: string = ''
  private _retryFileName: string = ''
  private _retryBuf: ArrayBuffer = new ArrayBuffer(0)
  private _retrySize: number = 0
  private _retryProject: string = ''
  // 竞态条件修复：relay 的 cmd_result 可能比 HTTP 上传响应先到达
  private _earlyResultCmdId: string = ''
  private _earlyResultSuccess: boolean = false
  private _earlyResultOutput: Record<string, Object> | null = null
  // 计时日志
  private _t0: number = 0
  private _t1: number = 0
  private _t2: number = 0
  // 批量上传：收集所有成功上传的文件名
  private _batchFileNames: string[] = []
  private _batchTotal: number = 0
  private _batchDone: number = 0

  constructor(session: TerminalSession, callbacks: FileUploadCallbacks) {
    this.session = session
    this.callbacks = callbacks
  }

  setBackendUrl(url: string): void {
    this.backendUrl = url
  }

  setProject(project: string): void {
    this._terminalProject = project
  }

  setSession(session: TerminalSession): void {
    this.session = session
  }

  setContext(ctx: common.Context): void {
    this._context = ctx
  }

  /** 从手机选择文件并上传到 PC 服务器（支持多选） */
  async handleFilePick(): Promise<void> {
    try {
      const ctx: common.Context = this._context ?? getContext(this) as common.Context
      const documentPicker = new picker.DocumentViewPicker(ctx)
      const selectOptions = new picker.DocumentSelectOptions()
      const uris: string[] = await documentPicker.select(selectOptions)
      if (uris.length === 0) return

      this._t0 = Date.now()
      this._batchFileNames = []
      this._batchTotal = uris.length
      this._batchDone = 0

      if (uris.length > 1) {
        this.callbacks.appendSystem('[文件上传] 选择了 ' + uris.length + ' 个文件，开始批量上传...', currentTheme().tool)
        this.callbacks.syncLines()
      }

      // 逐个处理每个文件（串行：每个文件上传+等待写入完成后才处理下一个）
      for (let i = 0; i < uris.length; i++) {
        const uri: string = uris[i]
        if (uri === '') continue
        await this.processOneFile(uri, i + 1, uris.length)
      }
    } catch (e) {
      const errMsg: string = (e as Error).message || ''
      if (errMsg.indexOf('cancel') >= 0 || errMsg.indexOf('取消') >= 0) {
        return
      }
      this.callbacks.appendError('[文件上传] ' + ((e as Error).message || '选择文件失败'))
      this.callbacks.syncLines()
    }
  }

  /** 处理单个文件：读取 → 压缩 → 上传 → 等待写入完成 */
  private async processOneFile(uri: string, index: number, total: number): Promise<void> {
    const prefix: string = total > 1 ? '[' + index + '/' + total + '] ' : ''
    this.callbacks.appendSystem(prefix + '正在读取文件...', currentTheme().tool)
    this.callbacks.syncLines()

    // 从 URI 提取文件名
    const segments: string[] = uri.split('/')
    const rawName: string = segments[segments.length - 1] || 'uploaded_file'
    const fileName: string = decodeURIComponent(rawName)

    // 读取文件
    const file: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)
    let bufSize: number = 2 * 1024 * 1024
    let maxBuf: ArrayBuffer = new ArrayBuffer(bufSize)
    let bytesRead: number
    try {
      bytesRead = await fileIo.read(file.fd, maxBuf)
      if (bytesRead >= bufSize) {
        maxBuf = new ArrayBuffer(10 * 1024 * 1024 + 1)
        await fileIo.close(file)
        const file2: fileIo.File = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)
        bytesRead = await fileIo.read(file2.fd, maxBuf)
        await fileIo.close(file2)
      } else {
        await fileIo.close(file)
      }
    } catch (readErr) {
      await fileIo.close(file)
      this.callbacks.appendError(prefix + '文件读取失败，跳过')
      this.callbacks.syncLines()
      this.onFileDone(fileName, false, prefix)
      return
    }

    if (bytesRead > 10 * 1024 * 1024) {
      this.callbacks.appendError(prefix + '文件过大（最大 10MB），跳过')
      this.callbacks.syncLines()
      this.onFileDone(fileName, false, prefix)
      return
    }

    let fileBuf: ArrayBuffer = maxBuf.slice(0, bytesRead)
    let uploadFileName: string = fileName
    let uploadSize: number = bytesRead

    // 图片压缩
    const lowerName: string = fileName.toLowerCase()
    const isImage: boolean = lowerName.endsWith('.jpg') || lowerName.endsWith('.jpeg') ||
      lowerName.endsWith('.png') || lowerName.endsWith('.bmp') || lowerName.endsWith('.webp')
    if (isImage && bytesRead > 200 * 1024) {
      this.callbacks.appendSystem(prefix + '正在 WebP 压缩...', currentTheme().tool)
      this.callbacks.syncLines()
      try {
        const compressed: ArrayBuffer | null = await this.compressImage(uri, bytesRead)
        if (compressed !== null) {
          const ratio: number = Math.round((1 - compressed.byteLength / bytesRead) * 100)
          fileBuf = compressed
          uploadSize = compressed.byteLength
          const dotIdx: number = fileName.lastIndexOf('.')
          uploadFileName = (dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName) + '.webp'
          this.callbacks.appendSystem(prefix + 'WebP: ' + Math.ceil(bytesRead / 1024) + 'KB → ' + Math.ceil(uploadSize / 1024) + 'KB (-' + ratio + '%)', currentTheme().result)
          this.callbacks.syncLines()
        }
      } catch (compressErr) {
        this.callbacks.appendSystem(prefix + '压缩失败，使用原始文件', currentTheme().warning)
        this.callbacks.syncLines()
      }
    }

    this._t1 = Date.now()
    this.callbacks.appendSystem(prefix + '正在上传 (' + Math.ceil(uploadSize / 1024) + ' KB)...', currentTheme().tool)
    this.callbacks.syncLines()

    const token: string = AppStorage.get<string>(KEY_CLIENT_TOKEN) ?? ''
    // 保存重试参数
    this._retryUri = uri
    this._retryFileName = uploadFileName
    this._retryBuf = fileBuf
    this._retrySize = uploadSize
    this._retryProject = this._terminalProject
    this._retryCount = 0
    await this.doUpload(token, prefix)
  }

  /** 执行文件上传 HTTP 请求（原始二进制，无 Base64），附带 429 重试 */
  private async doUpload(token: string, prefix: string): Promise<void> {
    const fileName: string = this._retryFileName
    const fileBuf: ArrayBuffer = this._retryBuf
    const project: string = this._retryProject
    const hc: http.HttpRequest = http.createHttp()
    try {
      const hdr: Record<string, string> = {
        'Content-Type': 'application/octet-stream',
        'X-File-Name': fileName,
        'X-Project': project,
      }
      if (token !== '') hdr['Authorization'] = 'Bearer ' + token
      const resp = await hc.request(this.backendUrl + '/agent/upload', {
        method: http.RequestMethod.POST,
        header: hdr,
        extraData: fileBuf,
        connectTimeout: 60000,
        readTimeout: 120000,
      })
      if (resp.responseCode === 200) {
        this._retryCount = 0
        this._t2 = Date.now()
        const httpMs: number = this._t2 - this._t1
        const result: Record<string, Object> = JSON.parse(resp.result as string) as Record<string, Object>
        const fileId: string = (result['file_id'] as string) ?? ''
        const cmdId: string = (result['cmd_id'] as string) ?? ''
        const via: string = (result['via'] as string) ?? 'agent'
        const pendingId: string = cmdId !== '' ? cmdId : fileId
        this._pendingUploadCmdId = pendingId
        this._pendingUploadFileName = fileName
        const viaMsg: string = via === 'relay' ? ' [快速通道]' : ' [队列]'
        console.info('[serein-upload] project=' + project + ' via=' + via + ' cmdId=' + cmdId + ' fileId=' + fileId)
        this.callbacks.appendSystem(prefix + '✓ 已接收 (' + httpMs + 'ms)' + viaMsg, currentTheme().result)
        this.callbacks.syncLines()

        // 竞态修复：检查早期 cmd_result
        if (this._earlyResultCmdId !== '' && this._earlyResultCmdId === pendingId) {
          const earlySuccess: boolean = this._earlyResultSuccess
          const earlyOutput: Record<string, Object> = this._earlyResultOutput ?? {}
          this._earlyResultCmdId = ''
          this._earlyResultOutput = null
          setTimeout(() => {
            this.handleFileUploadResult(pendingId, earlySuccess, earlyOutput)
          }, 0)
        }

        // === 关键：阻塞等待 WS cmd_result 或超时 ===
        // 确保当前文件完全处理完才返回，避免下一个文件覆盖 pendingId/timer
        const waitMs: number = via === 'relay' ? 10000 : 2000
        await new Promise<void>((resolve: () => void) => {
          this._uploadResolve = resolve
          if (this._pendingUploadTimer >= 0) { clearTimeout(this._pendingUploadTimer) }
          this._pendingUploadTimer = setTimeout(() => {
            if (this.callbacks.isDestroyed()) { resolve(); return }
            console.info('[serein-upload] timeout waiting for cmd_result, treating as success: ' + fileName)
            this._pendingUploadCmdId = ''
            this._pendingUploadTimer = -1
            this.onFileDone(fileName, true, prefix)
            resolve()
          }, waitMs)
        })
      } else if (resp.responseCode === 401) {
        handleAuthError()
        router.replaceUrl({ url: NavPath.PAIR })
      } else if (resp.responseCode === 429 && this._retryCount < this._maxRetries) {
        this._retryCount++
        const delay: number = Math.pow(2, this._retryCount) * 1000
        this.callbacks.appendSystem(prefix + '服务器限流 (429)，' + (delay / 1000) + 's 后重试 (' + this._retryCount + '/' + this._maxRetries + ')', currentTheme().warning)
        this.callbacks.syncLines()
        if (this._retryTimer >= 0) { clearTimeout(this._retryTimer) }
        this._retryTimer = setTimeout(() => {
          if (this.callbacks.isDestroyed()) return
          this._retryTimer = -1
          this.doUpload(token, prefix)
        }, delay)
      } else if (resp.responseCode === 503 && this._retryCount < this._maxRetries) {
        this._retryCount++
        const delay: number = Math.pow(2, this._retryCount) * 1000
        this.callbacks.appendSystem(prefix + '服务器繁忙 (503)，' + (delay / 1000) + 's 后重试 (' + this._retryCount + '/' + this._maxRetries + ')', currentTheme().warning)
        this.callbacks.syncLines()
        if (this._retryTimer >= 0) { clearTimeout(this._retryTimer) }
        this._retryTimer = setTimeout(() => {
          if (this.callbacks.isDestroyed()) return
          this._retryTimer = -1
          this.doUpload(token, prefix)
        }, delay)
      } else {
        this.callbacks.appendError(prefix + '上传失败 (HTTP ' + resp.responseCode + ')')
        this.callbacks.syncLines()
        this.onFileDone(fileName, false, prefix)
      }
    } catch (e) {
      this.callbacks.appendError(prefix + '上传失败: ' + ((e as Error).message || '网络错误'))
      this.callbacks.syncLines()
      this.onFileDone(fileName, false, prefix)
    } finally {
      hc.destroy()
    }
  }

  /**
   * 单个文件上传完成（成功或失败）。
   * 如果是批量上传，等所有文件完成后再发送 prompt。
   */
  private onFileDone(fileName: string, success: boolean, prefix: string): void {
    this._batchDone++
    if (success) {
      this._batchFileNames.push(fileName)
    }
    if (this._pendingUploadTimer >= 0) { clearTimeout(this._pendingUploadTimer); this._pendingUploadTimer = -1 }
    console.info('[serein-upload] onFileDone: ' + fileName + ' success=' + success + ' batchDone=' + this._batchDone + '/' + this._batchTotal)
    if (this._batchDone >= this._batchTotal) {
      // 所有文件处理完毕，发送 prompt
      this.sendBatchPrompt()
    }
  }

  /** 批量上传完成后发送 prompt */
  private sendBatchPrompt(): void {
    if (this._batchFileNames.length === 0) {
      this.callbacks.appendError('[文件上传] 所有文件上传失败')
      this.callbacks.syncLines()
      console.error('[serein-upload] sendBatchPrompt: all files failed, no prompt sent')
      return
    }
    const names: string[] = this._batchFileNames
    let prompt: string
    if (names.length === 1) {
      prompt = '请分析我刚上传的文件: uploads/' + names[0]
    } else {
      const fileList: string = names.map((n: string) => 'uploads/' + n).join(', ')
      prompt = '请分析我刚上传的 ' + names.length + ' 个文件: ' + fileList
    }
    const totalMs: number = Date.now() - this._t0
    this.callbacks.appendSystem('[文件上传] ✓ 完成 ' + names.length + ' 个文件 (' + totalMs + 'ms)', currentTheme().success)
    this.callbacks.syncLines()
    console.info('[serein-upload] batch done: ' + names.length + ' files, ' + totalMs + 'ms, prompt="' + prompt.substring(0, 80) + '"')
    try {
      this.callbacks.dispatchPrompt(prompt)
      console.info('[serein-upload] dispatchPrompt called OK')
    } catch (e) {
      console.error('[serein-upload] dispatchPrompt threw: ' + ((e as Error).message ?? 'Unknown'))
      this.callbacks.appendError('[文件上传] prompt 发送异常: ' + ((e as Error).message ?? 'Unknown'))
      this.callbacks.syncLines()
    }
    // 清空批量状态
    this._batchFileNames = []
    this._batchTotal = 0
    this._batchDone = 0
  }

  /** WS cmd_result 确认文件写入完成后的回调 */
  handleFileUploadResult(cmdId: string, success: boolean, output: Record<string, Object>): void {
    if (this.callbacks.isDestroyed()) return
    // 竞态修复：如果 _pendingUploadCmdId 还没设置，缓冲早期结果
    if (this._pendingUploadCmdId === '') {
      console.info('[serein-upload] 早期 cmd_result 到达，pending ID 未设置，缓冲: cmdId=' + cmdId + ' success=' + success)
      this._earlyResultCmdId = cmdId
      this._earlyResultSuccess = success
      this._earlyResultOutput = output
      return
    }
    if (cmdId !== this._pendingUploadCmdId) return
    const t3: number = Date.now()
    const totalMs: number = t3 - this._t0
    const relayMs: number = t3 - this._t2
    // 清除超时定时器
    if (this._pendingUploadTimer >= 0) { clearTimeout(this._pendingUploadTimer); this._pendingUploadTimer = -1 }
    const fileName: string = this._pendingUploadFileName
    this._pendingUploadCmdId = ''
    this._pendingUploadFileName = ''
    if (success) {
      this.callbacks.appendSystem('[文件上传] ✓ 写入成功: ' + fileName + ' (relay ' + relayMs + 'ms, 总计 ' + totalMs + 'ms)', currentTheme().success)
      this.callbacks.syncLines()
      console.info('[serein-upload] 上传完成: total=' + totalMs + 'ms relay=' + relayMs + 'ms')
    } else {
      const errMsg = (output['error'] as string) ?? ''
      this.callbacks.appendError('[文件上传] 写入失败: ' + fileName + (errMsg ? ' - ' + errMsg : ''))
      this.callbacks.syncLines()
    }
    this.onFileDone(fileName, success, '')
    // resolve Promise，让 doUpload 返回，继续处理下一个文件
    if (this._uploadResolve !== null) {
      const r = this._uploadResolve
      this._uploadResolve = null
      r()
    }
  }

  /**
   * 压缩图片为 WebP 格式。
   * WebP q80 对截图文字视觉无损，编码速度比 PNG 快 5-10 倍。
   */
  private async compressImage(uri: string, originalSize: number): Promise<ArrayBuffer | null> {
    if (originalSize < 200 * 1024) {
      return null
    }
    let file: fileIo.File | null = null
    try {
      file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY)
      const imageSource: image.ImageSource = image.createImageSource(file.fd)

      const pixelMap: image.PixelMap = await imageSource.createPixelMap()
      const info = await pixelMap.getImageInfo()
      const origW: number = info.size.width
      const origH: number = info.size.height
      pixelMap.release()

      const maxDim: number = 1920
      let sampleSize: number = 1
      const longerSide: number = Math.max(origW, origH)
      if (longerSide > maxDim) {
        sampleSize = Math.pow(2, Math.floor(Math.log2(longerSide / maxDim)))
        if (sampleSize < 1) sampleSize = 1
        if (sampleSize > 8) sampleSize = 8
      }

      const decodeOpts: image.DecodingOptions = {
        sampleSize: sampleSize,
      }
      const scaledPixelMap: image.PixelMap = await imageSource.createPixelMap(decodeOpts)
      const scaledInfo = await scaledPixelMap.getImageInfo()
      const scaledW: number = scaledInfo.size.width
      const scaledH: number = scaledInfo.size.height

      if (scaledW > maxDim || scaledH > maxDim) {
        let scaleRatio: number = scaledW >= scaledH ? maxDim / scaledW : maxDim / scaledH
        await scaledPixelMap.scale(scaleRatio, scaleRatio)
      }

      const imagePacker: image.ImagePacker = image.createImagePacker()
      const packOpts: image.PackingOption = {
        format: 'image/webp',
        quality: 80,
      }
      const packedData: ArrayBuffer = await imagePacker.packing(scaledPixelMap, packOpts)
      scaledPixelMap.release()
      imageSource.release()
      imagePacker.release()

      if (packedData.byteLength >= originalSize) {
        return null
      }
      return packedData
    } catch (e) {
      console.info('[serein-upload] compressImage error: ' + ((e as Error).message || ''))
      return null
    } finally {
      if (file !== null) {
        try { await fileIo.close(file) } catch (_) {}
      }
    }
  }

  /** 清除所有定时器 */
  clearTimers(): void {
    if (this._pendingUploadTimer >= 0) { clearTimeout(this._pendingUploadTimer); this._pendingUploadTimer = -1 }
    if (this._retryTimer >= 0) { clearTimeout(this._retryTimer); this._retryTimer = -1 }
  }
}
