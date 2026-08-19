/**
 * 使用 HUKS AES-256-GCM 加密 clientToken。
 *
 * 密钥由 HUKS 管理，Preferences 只保存随机 nonce 和带认证标签的密文。
 * 当前格式：__huk2:base64(nonce(12) + ciphertext + tag(16))。
 */

import { huks } from '@kit.UniversalKeystoreKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'

const KEY_ALIAS = 'rdp_ctrl_token_v1'
const PREFIX = '__huk2:'
const NONCE_LENGTH = 12
const TAG_LENGTH = 16

function keyProperties(): huks.HuksParam[] {
  return [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
    {
      tag: huks.HuksTag.HUKS_TAG_PURPOSE,
      value: huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT |
        huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT
    }
  ]
}

function cipherProperties(purpose: huks.HuksKeyPurpose, nonce: Uint8Array,
  tag?: Uint8Array): huks.HuksParam[] {
  const properties: huks.HuksParam[] = [
    { tag: huks.HuksTag.HUKS_TAG_ALGORITHM, value: huks.HuksKeyAlg.HUKS_ALG_AES },
    { tag: huks.HuksTag.HUKS_TAG_KEY_SIZE, value: huks.HuksKeySize.HUKS_AES_KEY_SIZE_256 },
    { tag: huks.HuksTag.HUKS_TAG_PURPOSE, value: purpose },
    { tag: huks.HuksTag.HUKS_TAG_PADDING, value: huks.HuksKeyPadding.HUKS_PADDING_NONE },
    { tag: huks.HuksTag.HUKS_TAG_BLOCK_MODE, value: huks.HuksCipherMode.HUKS_MODE_GCM },
    { tag: huks.HuksTag.HUKS_TAG_NONCE, value: nonce }
  ]
  if (tag) {
    properties.push({ tag: huks.HuksTag.HUKS_TAG_AE_TAG, value: tag })
  }
  return properties
}

async function ensureKey(alias: string): Promise<void> {
  if (await huks.hasKeyItem(alias, { properties: [] })) {
    return
  }
  await huks.generateKeyItem(alias, { properties: keyProperties() })
}

async function randomNonce(): Promise<Uint8Array> {
  const random: cryptoFramework.Random = cryptoFramework.createRandom()
  const data: cryptoFramework.DataBlob = await random.generateRandom(NONCE_LENGTH)
  if (!data.data || data.data.length !== NONCE_LENGTH) {
    throw new Error('TokenCipher: 无法生成 12 字节安全随机 nonce')
  }
  return data.data
}

async function abortQuietly(handle: number): Promise<void> {
  try {
    await huks.abortSession(handle, { properties: [] })
  } catch (_) {
    // 会话可能已经由 finishSession 释放。
  }
}

/** 加密并返回可持久化字符串。 */
export async function encryptToken(plainText: string): Promise<string> {
  if (!plainText) return ''
  return encryptSecret(plainText, KEY_ALIAS)
}

/**
 * 使用指定 HUKS 别名加密敏感数据。
 *
 * 与旧 clientToken 兼容逻辑不同，本函数不提供明文降级；调用方必须在失败时
 * 中止保存。协作中心的平台凭证和私有缓存使用此入口。
 */
export async function encryptSecret(plainText: string, keyAlias: string): Promise<string> {
  if (!plainText) return ''
  if (!keyAlias || keyAlias.length > 64 || !/^[a-zA-Z0-9_.-]+$/.test(keyAlias)) {
    throw new Error('TokenCipher: 非法 HUKS key alias')
  }
  await ensureKey(keyAlias)

  const nonce = await randomNonce()
  const plainBytes = new util.TextEncoder().encodeInto(plainText)
  const options: huks.HuksOptions = {
    properties: cipherProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_ENCRYPT, nonce),
    inData: plainBytes
  }
  const session = await huks.initSession(keyAlias, options)

  try {
    // 对 token 这类短数据，官方示例直接在 finishSession 中一次性处理。
    // GCM 加密输出为 ciphertext + 16-byte authentication tag。
    const result = await huks.finishSession(session.handle, options)
    const cipherAndTag = result.outData ?? new Uint8Array(0)
    if (cipherAndTag.length !== plainBytes.length + TAG_LENGTH) {
      throw new Error('TokenCipher: HUKS GCM 输出长度异常')
    }

    const combined = new Uint8Array(NONCE_LENGTH + cipherAndTag.length)
    combined.set(nonce, 0)
    combined.set(cipherAndTag, NONCE_LENGTH)
    return PREFIX + new util.Base64Helper().encodeToStringSync(combined, util.Type.BASIC)
  } catch (error) {
    await abortQuietly(session.handle)
    throw error as Error
  }
}

/** 解密持久化字符串。失败返回空字符串并触发重新配对。 */
export async function decryptToken(cipherText: string): Promise<string> {
  if (!cipherText) return ''
  if (cipherText.startsWith('__plain:')) {
    return cipherText.substring(8)
  }

  // 只把严格匹配的旧版明文 JWT 当作升级兼容数据。
  if (!cipherText.startsWith(PREFIX)) {
    const jwtRe: RegExp = /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/
    return jwtRe.test(cipherText) ? cipherText : ''
  }

  let sessionHandle: number | null = null
  try {
    const raw = new util.Base64Helper().decodeSync(
      cipherText.substring(PREFIX.length), util.Type.BASIC)
    if (raw.length <= NONCE_LENGTH + TAG_LENGTH) return ''

    const nonce = raw.slice(0, NONCE_LENGTH)
    const cipherAndTag = raw.slice(NONCE_LENGTH)
    const cipherBytes = cipherAndTag.slice(0, cipherAndTag.length - TAG_LENGTH)
    const tag = cipherAndTag.slice(cipherAndTag.length - TAG_LENGTH)

    await ensureKey(KEY_ALIAS)
    const options: huks.HuksOptions = {
      properties: cipherProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, nonce, tag),
      inData: cipherBytes
    }
    const session = await huks.initSession(KEY_ALIAS, options)
    sessionHandle = session.handle
    const result = await huks.finishSession(session.handle, options)
    sessionHandle = null

    return new util.TextDecoder().decodeToString(result.outData ?? new Uint8Array(0))
  } catch (error) {
    if (sessionHandle !== null) {
      await abortQuietly(sessionHandle)
    }
    console.warn('serein: HUKS decrypt failed: ' + (error as Error).message)
    return ''
  }
}

/**
 * 严格解密敏感数据。只接受当前 HUKS 密文格式，失败时抛错，不兼容任何明文。
 */
export async function decryptSecret(cipherText: string, keyAlias: string): Promise<string> {
  if (!cipherText) return ''
  if (!keyAlias || keyAlias.length > 64 || !/^[a-zA-Z0-9_.-]+$/.test(keyAlias)) {
    throw new Error('TokenCipher: 非法 HUKS key alias')
  }
  if (!cipherText.startsWith(PREFIX)) {
    throw new Error('TokenCipher: 拒绝解密非 HUKS 密文')
  }

  let sessionHandle: number | null = null
  try {
    const raw = new util.Base64Helper().decodeSync(
      cipherText.substring(PREFIX.length), util.Type.BASIC)
    if (raw.length <= NONCE_LENGTH + TAG_LENGTH) {
      throw new Error('TokenCipher: 密文长度异常')
    }

    const nonce = raw.slice(0, NONCE_LENGTH)
    const cipherAndTag = raw.slice(NONCE_LENGTH)
    const cipherBytes = cipherAndTag.slice(0, cipherAndTag.length - TAG_LENGTH)
    const tag = cipherAndTag.slice(cipherAndTag.length - TAG_LENGTH)

    await ensureKey(keyAlias)
    const options: huks.HuksOptions = {
      properties: cipherProperties(huks.HuksKeyPurpose.HUKS_KEY_PURPOSE_DECRYPT, nonce, tag),
      inData: cipherBytes
    }
    const session = await huks.initSession(keyAlias, options)
    sessionHandle = session.handle
    const result = await huks.finishSession(session.handle, options)
    sessionHandle = null
    return new util.TextDecoder().decodeToString(result.outData ?? new Uint8Array(0))
  } catch (error) {
    if (sessionHandle !== null) {
      await abortQuietly(sessionHandle)
    }
    throw error as Error
  }
}

/** 删除一类敏感数据对应的 HUKS 密钥。 */
export async function deleteSecretKey(keyAlias: string): Promise<void> {
  if (!keyAlias || keyAlias.length > 64 || !/^[a-zA-Z0-9_.-]+$/.test(keyAlias)) {
    throw new Error('TokenCipher: 非法 HUKS key alias')
  }
  if (await huks.hasKeyItem(keyAlias, { properties: [] })) {
    await huks.deleteKeyItem(keyAlias, { properties: [] })
  }
}
