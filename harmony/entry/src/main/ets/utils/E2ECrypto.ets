/**
 * E2ECrypto — 端到端 AES-256-GCM 加密/解密模块（鸿蒙端）
 *
 * 与 agent/serein-e2e.mjs 配对使用。加密格式一致：
 *   base64(iv[12] + ciphertext + authTag[16])
 *
 * 密钥通过项目 QR 码交换（扫码时提取 e2eKey 字段）。
 * 后端只看到加密密文，无法读取明文内容。
 */
import cryptoFramework from '@ohos.security.cryptoFramework'
import buffer from '@ohos.buffer'
import util from '@ohos.util'

const IV_LENGTH = 12
const TAG_LENGTH = 16
const KEY_LENGTH = 32

interface DataBlob {
  data: Uint8Array
}

export class E2ECrypto {
  private key: Uint8Array | null = null
  private base64Helper: util.Base64Helper = new util.Base64Helper()
  private enabled: boolean = false

  /**
   * 设置 E2E 密钥（从 QR 码扫描得到的 base64 字符串）
   */
  setKey(base64Key: string): boolean {
    try {
      const decoded = this.base64Helper.decodeSync(base64Key)
      if (decoded.length !== KEY_LENGTH) {
        console.error('serein e2e: key length mismatch, expected ' + KEY_LENGTH + ' got ' + decoded.length)
        return false
      }
      this.key = decoded
      this.enabled = true
      console.info('serein e2e: encryption enabled, key length=' + decoded.length)
      return true
    } catch (e) {
      console.error('serein e2e: setKey failed: ' + (e as Error).message)
      return false
    }
  }

  /**
   * 清除密钥，禁用 E2E
   */
  clearKey(): void {
    this.key = null
    this.enabled = false
  }

  /**
   * E2E 是否已启用
   */
  get isEnabled(): boolean {
    return this.enabled && this.key !== null
  }

  /**
   * 加密明文，返回 base64(iv + ciphertext + authTag)
   * HarmonyOS GCM 模式 doFinalSync 输出 = ciphertext + authTag(16字节)
   */
  encrypt(plaintext: string): string | null {
    if (!this.isEnabled || !this.key) return null
    try {
      // 生成随机 IV
      const iv = cryptoFramework.createRandom().generateRandomSync(IV_LENGTH).data

      // 创建 SymKey
      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256')
      const keyBlob: DataBlob = { data: this.key }
      const symKey = symKeyGenerator.convertKeySync(keyBlob)

      // 创建 Cipher
      const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding')

      // 构建 GCM 参数（加密时 authTag 留空，加密后通过 getAuthTag 获取）
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv } as DataBlob,
        aad: { data: new Uint8Array(0) } as DataBlob,
        authTag: { data: new Uint8Array(0) } as DataBlob,
        algName: 'GcmParamsSpec'
      }

      cipher.initSync(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, gcmParams)

      // 加密 — HarmonyOS GCM 模式 doFinalSync 返回 ciphertext + authTag
      const plainBytes = new Uint8Array(buffer.from(plaintext, 'utf-8').buffer)
      const encryptedResult = cipher.doFinalSync({ data: plainBytes })
      const encData = encryptedResult.data

      // HarmonyOS crypto framework 不提供 getAuthTag 方法。
      // GCM 的 authTag 是 doFinalSync 输出的最后 16 字节。
      const ciphertext = encData.subarray(0, encData.length - TAG_LENGTH)
      const authTag = encData.subarray(encData.length - TAG_LENGTH)

      // 拼接: iv + ciphertext + authTag
      const blob = new Uint8Array(IV_LENGTH + ciphertext.length + TAG_LENGTH)
      blob.set(iv, 0)
      blob.set(ciphertext, IV_LENGTH)
      blob.set(authTag, IV_LENGTH + ciphertext.length)

      return this.base64Helper.encodeToStringSync(blob)
    } catch (e) {
      console.error('serein e2e: encrypt failed: ' + (e as Error).message)
      return null
    }
  }

  /**
   * 解密 base64(iv + ciphertext + authTag)，返回明文
   */
  decrypt(base64Blob: string): string | null {
    if (!this.isEnabled || !this.key) return null
    try {
      const blob = this.base64Helper.decodeSync(base64Blob)
      if (blob.length < IV_LENGTH + TAG_LENGTH + 1) return null

      // 拆分: iv + ciphertext + authTag
      const iv = blob.subarray(0, IV_LENGTH)
      const authTag = blob.subarray(blob.length - TAG_LENGTH)
      const ciphertext = blob.subarray(IV_LENGTH, blob.length - TAG_LENGTH)

      // 创建 SymKey
      const symKeyGenerator = cryptoFramework.createSymKeyGenerator('AES256')
      const keyBlob: DataBlob = { data: this.key }
      const symKey = symKeyGenerator.convertKeySync(keyBlob)

      // 创建 Cipher
      const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding')

      // 构建 GCM 参数（解密时需要提供 authTag）
      const gcmParams: cryptoFramework.GcmParamsSpec = {
        iv: { data: iv } as DataBlob,
        aad: { data: new Uint8Array(0) } as DataBlob,
        authTag: { data: authTag } as DataBlob,
        algName: 'GcmParamsSpec'
      }

      cipher.initSync(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, gcmParams)

      // 解密
      const decryptedResult = cipher.doFinalSync({ data: ciphertext })
      const plainBytes = decryptedResult.data

      // 转为字符串
      return buffer.from(plainBytes).toString('utf-8')
    } catch (e) {
      console.error('serein e2e: decrypt failed: ' + (e as Error).message)
      return null
    }
  }
}

/**
 * 全局单例
 */
const e2eCrypto = new E2ECrypto()
export default e2eCrypto
