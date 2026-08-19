/**
 * 文件: PinGuard — PIN/生物识别保护
 *
 * 1. 优先用系统指纹/面部识别
 * 2. 不支持时降级到应用内数字 PIN
 * 3. PBKDF2-SHA256 迭代哈希存储（替代 SHA-256，防止暴力破解 4-6 位数字 PIN）
 */
import { userAuth } from '@kit.UserAuthenticationKit'
import { cryptoFramework } from '@kit.CryptoArchitectureKit'
import { util } from '@kit.ArkTS'

// ── PBKDF2 常量 ──
const PBKDF2_ITERATIONS = 200000  // 20 万次迭代，平衡安全与性能
const PBKDF2_KEY_SIZE = 32        // 输出 256 位
const PBKDF2_ALG = 'PBKDF2|SHA256'
const HASH_VERSION = 2            // 存储格式版本号

/**
 * PBKDF2-SHA256 哈希 PIN 值。
 * 使用随机盐 + 20 万次迭代，存储格式 "2:saltHex:keyHex"。
 * 失败时直接抛出异常（不静默降级），由调用方处理。
 */
export async function hashPin(pin: string): Promise<string> {
  const rand: cryptoFramework.Random = cryptoFramework.createRandom()
  const saltRand: cryptoFramework.DataBlob = await rand.generateRandom(16)
  const salt = saltRand.data

  const kdf = cryptoFramework.createKdf(PBKDF2_ALG)
  const spec: cryptoFramework.PBKDF2Spec = {
    algName: 'PBKDF2',
    password: pin,
    salt: salt,
    iterations: PBKDF2_ITERATIONS,
    keySize: PBKDF2_KEY_SIZE
  }
  const secret: cryptoFramework.DataBlob = await kdf.generateSecret(spec)
  return HASH_VERSION + ':' + bytesToHex(salt) + ':' + bytesToHex(secret.data)
}

/** 验证 PIN：支持 PBKDF2（v2）和旧 SHA-256（v1/v0）向后兼容 */
export async function verifyPin(storedHash: string, enteredPin: string): Promise<boolean> {
  if (!storedHash || !enteredPin) return false
  try {
    const parts = storedHash.split(':')

    // ── PBKDF2 格式: "2:saltHex:keyHex" ──
    if (parts.length === 3 && parts[0] === String(HASH_VERSION)) {
      const saltHex = parts[1]
      const expectedKeyHex = parts[2]
      const saltBytes = hexToBytes(saltHex)
      const kdf = cryptoFramework.createKdf(PBKDF2_ALG)
      const spec: cryptoFramework.PBKDF2Spec = {
        algName: 'PBKDF2',
        password: enteredPin,
        salt: saltBytes,
        iterations: PBKDF2_ITERATIONS,
        keySize: PBKDF2_KEY_SIZE
      }
      const secret: cryptoFramework.DataBlob = await kdf.generateSecret(spec)
      return constantTimeEqual(secret.data, hexToBytes(expectedKeyHex))
    }

    // ── 旧格式兼容：SHA-256 有盐 "saltHex:hashHex" 或 无盐 ":hashHex" / "hashHex" ──
    const encoder = new util.TextEncoder()
    const colonIdx = storedHash.indexOf(':')
    if (colonIdx <= 0) {
      // 无盐旧格式（空 salt 或旧 XOR 格式）
      // colonIdx === 0: fallback 格式 ":hashHex" — 冒号在位置 0，需提取冒号后的 hash
      const hashHex = colonIdx === 0 ? storedHash.substring(1) : storedHash
      const md = cryptoFramework.createMd('SHA256')
      await md.update({ data: encoder.encodeInto(enteredPin) })
      const digest: cryptoFramework.DataBlob = await md.digest()
      return bytesToHex(digest.data) === hashHex
    }
    // 有盐旧格式
    const saltHex = storedHash.substring(0, colonIdx)
    const expectedHash = storedHash.substring(colonIdx + 1)
    const saltBytes = hexToBytes(saltHex)
    const pinBytes = encoder.encodeInto(enteredPin)
    const combined = new Uint8Array(saltBytes.length + pinBytes.length)
    combined.set(saltBytes, 0)
    combined.set(pinBytes, saltBytes.length)
    const md = cryptoFramework.createMd('SHA256')
    await md.update({ data: combined })
    const digest: cryptoFramework.DataBlob = await md.digest()
    return bytesToHex(digest.data) === expectedHash
  } catch (e) {
    console.error('serein pin: verifyPin failed: ' + (e as Error).message)
    return false
  }
}

/** 恒定时间比较两个 Uint8Array，防止时序攻击 */
function constantTimeEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.length !== b.length) return false
  let result = 0
  for (let i = 0; i < a.length; i++) {
    result |= a[i] ^ b[i]
  }
  return result === 0
}

/** 十六进制字符串 → Uint8Array */
function hexToBytes(hex: string): Uint8Array {
  const len = hex.length / 2
  const out = new Uint8Array(len)
  for (let i = 0; i < len; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16) & 0xFF
  }
  return out
}

/** Uint8Array → 小写十六进制字符串（模块级工具函数，避免 ArkTS 严格模式限制内联 lambda） */
function bytesToHex(arr: Uint8Array): string {
  let h = ''
  for (let i = 0; i < arr.length; i++) {
    const b = arr[i].toString(16)
    h += b.length === 1 ? '0' + b : b
  }
  return h
}

export async function verifyAuth(): Promise<boolean> {
  try {
    // 生成随机 challenge（ATL3 生物识别必需，空 challenge 只能回退 PIN）
    const rand = cryptoFramework.createRandom()
    const challengeBlob = await rand.generateRandom(16)
    const authInstance = userAuth.getUserAuthInstance(
      {
        challenge: challengeBlob.data,
        // 生物识别优先：指纹→面容→PIN（PIN 作为最终回退）
        authType: [userAuth.UserAuthType.FINGERPRINT, userAuth.UserAuthType.FACE, userAuth.UserAuthType.PIN],
        authTrustLevel: userAuth.AuthTrustLevel.ATL3
      },
      { title: '验证身份' }
    )
    return new Promise<boolean>((resolve: (result: boolean) => void) => {
      const timer = setTimeout(() => { resolve(false) }, 8000)
      try {
        authInstance.on('result', {
          onResult: (result: userAuth.UserAuthResult) => {
            clearTimeout(timer)
            const ok = result.result === userAuth.UserAuthResultCode.SUCCESS
            if (ok) {
              // 认证成功后延迟更新 UI，等系统弹窗的成功动画（打勾、关闭）走完，
              // 避免 App 主内容在弹窗关闭动画下方提前闪现
              setTimeout(() => { resolve(true) }, 700)
            } else {
              resolve(false)
            }
          }
        })
        authInstance.start()
      } catch (e) {
        clearTimeout(timer)
        resolve(false)
      }
    })
  } catch (e) {
    console.error('[PinGuard] verifyAuth 失败: ' + (e as Error).message)
    return false
  }
}
