import { http } from '@kit.NetworkKit'

/**
 * 部署配置 — 集中管理部署命令中引用的环境变量键名。
 *
 * == 安全说明（反编译防护） ==
 *
 * HAP 包可被反编译提取。本文件编译入 HAP 后，攻击者可：
 * 1. 获取服务器部署所需的环境变量名（DEPLOY_HOST、SEREIN_PROJECT_ROOT 等）
 * 2. 了解部署脚本逻辑（Python inline 代码）
 * 3. 推测后端基础设施架构
 *
 * 开发者 PC 本地路径（Python、DevEco、项目目录等）已从本文件移除，
 * 改为在服务端运行部署时通过环境变量读取。详见 commit 记录。
 *
 * 使用方式：
 * - 开发者需在 PC 上设置环境变量（与 DEPLOY_HOST/DEPLOY_USER/DEPLOY_TARGET_PATH 同一组）
 * - 未设置时报错退出，不会使用默认值
 * - 手机端项目选择器显示的路径来自后端 /agent/profile 接口，不再硬编码
 *
 * 未来改进方向（P3）：
 * - 将环境变量键名从 HAP 移除，改为后端 /deploy/config API 返回部署模板
 * - 避免在 HAP 中硬编码任何服务器部署细节
 */

/**
 * 环境变量键名（Python inline 脚本通过 os.environ.get() 读取）
 * 部署时 PC 端必须设置以下环境变量：
 *   SEREIN_PROJECT_ROOT  - 项目根目录 (运行部署的 PC 需设置)
 *   SEREIN_PYTHON        - Python 解释器路径
 *   SEREIN_HARMONY_PROJECT - Harmony 项目目录
 *   SEREIN_HVIGOR_BAT    - DevEco hvigorw.bat 路径
 *   SEREIN_JBR_BIN        - DevEco JBR bin 目录
 *   SEREIN_SDK_HOME       - DevEco SDK 目录
 */
export const ENV_PROJECT_ROOT = 'SEREIN_PROJECT_ROOT'
export const ENV_PYTHON_EXE = 'SEREIN_PYTHON'
export const ENV_HARMONY_PROJECT = 'SEREIN_HARMONY_PROJECT'
export const ENV_HVIGOR_BAT = 'SEREIN_HVIGOR_BAT'
export const ENV_JBR_BIN = 'SEREIN_JBR_BIN'
export const ENV_SDK_HOME = 'SEREIN_SDK_HOME'

/**
 * AppStorage 中的后端 URL 键名
 * 前端页面通过设置页连接后端后写入 AppStorage，此处不做默认值，避免服务器地址硬编码进 HAP
 */
export const BACKEND_URL_KEY = 'backendUrl'

/**
 * 项目路径映射（仅用于手机端项目选择器显示项目名称，不包含实际路径）
 *
 * 当前永远为空，项目列表来自后端 /agent/projects API（ProjectsPage.ets line 289）。
 * 此常量保留用于未来可能的本地项目选择优化。
 * TODO: 如发现实际使用场景，从后端配置填充此映射。
 */
export const PROJECT_PATHS: Record<string, string> = {}

/**
 * 从后端 /agent/deploy-config API 获取部署命令字符串。
 * 将部署命令构造移到服务端，HAP 仅做 API 调用，消除 HAP 侧 Python 内联命令注入面。
 *
 * 流程：
 * 1. HAP 发送 POST /agent/deploy-config {type: "backend"|"app"|"full"}
 * 2. 后端返回 {"command": "python -c \"...\""}
 * 3. HAP 将 command 通过 exec action 发送到 agent 在 PC 端执行
 * 4. PC 端的部署环境变量（DEPLOY_HOST、SEREIN_PROJECT_ROOT 等）在运行时读取
 *
 * @param backendUrl - 后端地址（从 AppStorage 读取）
 * @param type - 部署类型
 * @returns 部署命令字符串，或 null（失败时）
 */

export async function fetchDeployCommand(backendUrl: string, type: 'backend' | 'app' | 'full'): Promise<string | null> {
  if (!backendUrl) {
    console.error('[DEPLOY] backendUrl 为空')
    return null
  }
  const VALID_TYPES: string[] = ['backend', 'app', 'full']
  if (!VALID_TYPES.includes(type)) {
    console.error('[DEPLOY] 无效的部署类型: ' + type)
    return null
  }
  const hc = http.createHttp()
  try {
    const resp = await hc.request(backendUrl + '/agent/deploy-config', {
      method: http.RequestMethod.POST,
      extraData: JSON.stringify({ type: type }),
      header: { 'Content-Type': 'application/json' },
      connectTimeout: 5000,
      readTimeout: 5000,
    })
    if (resp.responseCode === 200) {
      const data = JSON.parse(resp.result as string) as Record<string, string>
      if (data['command']) {
        return data['command']
      }
      console.error('[DEPLOY] 响应缺少 command 字段')
    } else {
      console.error('[DEPLOY] HTTP ' + resp.responseCode + ': ' + (resp.result as string))
    }
  } catch (e) {
    console.error('[DEPLOY] 请求失败: ' + (e as Error).message)
  } finally {
    hc.destroy()
  }
  return null
}

/**
 * buildDeployCmd 已迁移到后端 /agent/deploy-config API。
 * HAP 侧不再构造 Python 内联命令，改为调用 fetchDeployCommand() 获取。
 * 保留此注释作为安全审计追踪——这是已知攻击面的关闭记录。
 *
 * 迁移历史：
 * - 之前：buildDeployCmd() 在 HAP 内联 Python 命令字符串，标记为 CRITICAL 攻击面
 * - 现在：命令由后端 admin_handler.go buildDeployCmd() 构造，HAP 仅调用 API
 * - 风险等级：从 CRITICAL 降至 LOW（命令模板在服务端，HAP 反编译不暴露部署逻辑）
 */
