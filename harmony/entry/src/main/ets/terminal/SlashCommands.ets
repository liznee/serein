/**
 * SlashCommands — 终端 / 命令补全表
 *
 * 含三类：
 *  1. 本终端特殊命令（/resume /clear /help）—— 客户端或 agent 专门处理
 *  2. Claude Code 内置斜杠命令 —— 经 do_chat (claude -p) 执行
 *  3. Skills（/skill-name）—— claude -p 下仍可解析触发
 *
 * 远程 shell 用 /! 前缀转义，如 /!ls -la，不在本表内。
 * 内置命令排在前面，便于常用项优先露出；skills 按字母序。
 */

export interface SlashCommandInfo {
  cmd: string
  desc: string
  builtin: boolean // true=终端/CC内置；false=skill
}

export const SLASH_COMMANDS: SlashCommandInfo[] = [
  // ====== 本终端特殊 ======
  { cmd: '/resume', desc: '加载上次会话总结', builtin: true },
  { cmd: '/clear', desc: '清屏', builtin: true },
  { cmd: '/help', desc: '命令帮助', builtin: true },
  { cmd: '/snippets', desc: '命令片段库', builtin: true },
  { cmd: '/workflow', desc: '多步任务编排模板', builtin: true },
  { cmd: '/ai-commit', desc: 'AI 生成 commit message', builtin: true },
  { cmd: '/history', desc: '历史搜索', builtin: true },
  { cmd: '/theme', desc: '切换主题', builtin: true },
  { cmd: '/font', desc: '字号 + / -', builtin: true },
  { cmd: '/diff', desc: '查看 git diff', builtin: true },
  { cmd: '/undo', desc: 'git reset 回滚上次提交', builtin: true },
  { cmd: '/search', desc: '输出内搜索/过滤', builtin: true },
  { cmd: '/nl <描述>', desc: '自然语言转命令序列', builtin: true },
  { cmd: '/batch <命令>', desc: '多项目批量执行命令', builtin: true },
  { cmd: '/release', desc: '全量发版(后端+前端编译上传)', builtin: true },
  { cmd: '/release-backend', desc: '发后端(bump+编译+scp)', builtin: true },
  { cmd: '/release-app', desc: '发前端(编译HAP)', builtin: true },
  // ====== Claude Code 内置 ======
  { cmd: '/init', desc: '初始化 CLAUDE.md', builtin: true },
  { cmd: '/review', desc: '审查 PR', builtin: true },
  { cmd: '/security-review', desc: '安全审查当前改动', builtin: true },
  { cmd: '/code-review', desc: '代码审查当前 diff', builtin: true },
  { cmd: '/simplify', desc: '简化改动代码', builtin: true },
  { cmd: '/run', desc: '启动应用', builtin: true },
  { cmd: '/verify', desc: '验证改动生效', builtin: true },
  { cmd: '/loop', desc: '循环执行任务', builtin: true },
  { cmd: '/update-config', desc: '配置 harness/settings', builtin: true },
  { cmd: '/fewer-permission-prompts', desc: '减少权限提示', builtin: true },
  { cmd: '/resume-session', desc: '恢复上次 session', builtin: true },
  { cmd: '/save-session', desc: '保存当前 session', builtin: true },
  { cmd: '/deep-research', desc: '深度研究报告', builtin: true },
  { cmd: '/claude-api', desc: 'Claude API 开发', builtin: true },
  // ====== Skills ======
  { cmd: '/agent-introspection-debugging', desc: 'Agent 自调试', builtin: false },
  { cmd: '/agent-sort', desc: 'ECC 安装排序', builtin: false },
  { cmd: '/article-writing', desc: '写文章', builtin: false },
  { cmd: '/autonomous-loops', desc: '自治循环模式', builtin: false },
  { cmd: '/backend-patterns', desc: '后端模式', builtin: false },
  { cmd: '/brand-voice', desc: '品牌语态', builtin: false },
  { cmd: '/bun-runtime', desc: 'Bun 运行时', builtin: false },
  { cmd: '/code-tour', desc: '代码导览', builtin: false },
  { cmd: '/codebase-onboarding', desc: '代码库上手', builtin: false },
  { cmd: '/configure-ecc', desc: '配置 ECC', builtin: false },
  { cmd: '/content-engine', desc: '内容引擎', builtin: false },
  { cmd: '/context-budget', desc: '上下文预算审计', builtin: false },
  { cmd: '/continuous-learning-v2', desc: '持续学习', builtin: false },
  { cmd: '/cost-aware-llm-pipeline', desc: '成本优化管线', builtin: false },
  { cmd: '/cost-tracking', desc: '成本追踪', builtin: false },
  { cmd: '/council', desc: '多视角 council', builtin: false },
  { cmd: '/crosspost', desc: '多平台分发', builtin: false },
  { cmd: '/deployment-patterns', desc: '部署模式', builtin: false },
  { cmd: '/dmux-workflows', desc: 'dmux 多 agent', builtin: false },
  { cmd: '/docker-patterns', desc: 'Docker 模式', builtin: false },
  { cmd: '/documentation-lookup', desc: '文档查询', builtin: false },
  { cmd: '/e2e-testing', desc: 'E2E 测试', builtin: false },
  { cmd: '/eval-harness', desc: '评估框架', builtin: false },
  { cmd: '/fal-ai-media', desc: 'fal.ai 媒体生成', builtin: false },
  { cmd: '/frontend-patterns', desc: '前端模式', builtin: false },
  { cmd: '/frontend-slides', desc: '前端幻灯片', builtin: false },
  { cmd: '/investor-materials', desc: '投资人材料', builtin: false },
  { cmd: '/investor-outreach', desc: '投资人触达', builtin: false },
  { cmd: '/iterative-retrieval', desc: '迭代检索', builtin: false },
  { cmd: '/market-research', desc: '市场研究', builtin: false },
  { cmd: '/mcp-server-patterns', desc: 'MCP 服务端模式', builtin: false },
  { cmd: '/mle-workflow', desc: 'ML 工程流程', builtin: false },
  { cmd: '/nextjs-turbopack', desc: 'Next.js Turbopack', builtin: false },
  { cmd: '/plan-orchestrate', desc: '计划编排', builtin: false },
  { cmd: '/postgres-patterns', desc: 'PostgreSQL 模式', builtin: false },
  { cmd: '/prisma-patterns', desc: 'Prisma 模式', builtin: false },
  { cmd: '/production-audit', desc: '生产审计', builtin: false },
  { cmd: '/prompt-optimizer', desc: 'Prompt 优化', builtin: false },
  { cmd: '/python-patterns', desc: 'Python 模式', builtin: false },
  { cmd: '/python-testing', desc: 'Python 测试', builtin: false },
  { cmd: '/repo-scan', desc: '仓库扫描', builtin: false },
  { cmd: '/rules-distill', desc: '规则提炼', builtin: false },
  { cmd: '/security-scan', desc: '安全扫描', builtin: false },
  { cmd: '/skill-stocktake', desc: 'Skill 盘点', builtin: false },
  { cmd: '/strategic-compact', desc: '战略压缩', builtin: false },
  { cmd: '/tdd-workflow', desc: 'TDD 流程', builtin: false },
  { cmd: '/token-budget-advisor', desc: 'Token 预算建议', builtin: false },
  { cmd: '/ui-ux-pro-max', desc: 'UI/UX 设计', builtin: false },
  { cmd: '/video-editing', desc: '视频编辑', builtin: false },
  { cmd: '/x-api', desc: 'X/Twitter API', builtin: false }
]

// 浮层最多显示条数，超出提示进一步输入字母过滤
export const SLASH_HINT_MAX: number = 16
