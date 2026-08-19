#!/usr/bin/env python3
"""serein Agent 注册表 — 多 Agent 类型抽象层。

定义支持的 AI Agent 类型（Claude Code、Codex），
每种类型包含二进制名、会话目录模式、JSONL 解析方式等配置。

当前实现：
- claude (Claude Code): 完整支持
- codex (OpenAI Codex CLI): 结构化会话适配，审批能力仍为实验性

使用方式：
    from agent_config import get_agent_config, AGENT_TYPES
    config = get_agent_config("claude")  # 返回 AgentConfig
    config.binary_name  # "claude.exe"
    config.session_dir_pattern  # "~/.claude/projects/{slug}"
"""
import os
import shutil
from dataclasses import dataclass


@dataclass(frozen=True)
class AgentConfig:
    """单个 Agent 类型的配置。"""
    name: str                          # 类型名（claude / codex）
    display_name: str                  # 手机端显示名
    binary_name: str                   # Windows 二进制名
    binary_name_unix: str              # Linux/Mac 二进制名
    session_dir_pattern: str           # 会话目录模式（{home} / {slug} 占位符）
    session_file_ext: str              # 会话文件扩展名（.jsonl）
    env_var_exe: str                   # 自定义路径的环境变量名
    supports_jsonl: bool               # 是否支持 JSONL 结构化事件解析
    supports_approval_hook: bool       # 是否支持完整的工具调用审批 Hook
    support_level: str                 # full / experimental
    default_args: tuple[str, ...] = ()  # 默认启动参数


# ═══ Agent 类型注册表 ═══

_REGISTRY: dict[str, AgentConfig] = {
    "claude": AgentConfig(
        name="claude",
        display_name="Claude Code",
        binary_name="claude.exe",
        binary_name_unix="claude",
        session_dir_pattern="{home}/.claude/projects/{slug}",
        session_file_ext=".jsonl",
        env_var_exe="CLAUDE_EXE",
        supports_jsonl=True,
        supports_approval_hook=True,
        support_level="full",
        default_args=(),
    ),
    "codex": AgentConfig(
        name="codex",
        display_name="OpenAI Codex",
        binary_name="codex.exe",
        binary_name_unix="codex",
        session_dir_pattern="{home}/.codex/sessions",
        session_file_ext=".jsonl",
        env_var_exe="CODEX_EXE",
        supports_jsonl=True,
        supports_approval_hook=False,
        support_level="experimental",
        default_args=(),
    ),
}

# 所有支持的 agent 类型名
AGENT_TYPES: list[str] = list(_REGISTRY.keys())

# 默认 agent 类型
DEFAULT_AGENT_TYPE = "claude"


def get_agent_config(agent_type: str = "") -> AgentConfig:
    """获取指定类型的 AgentConfig；未知类型必须显式报错。"""
    if not agent_type:
        agent_type = DEFAULT_AGENT_TYPE
    normalized = agent_type.strip().lower()
    if normalized not in _REGISTRY:
        raise ValueError(
            f"unsupported agent type: {normalized or '(empty)'}; "
            f"expected one of: {', '.join(AGENT_TYPES)}"
        )
    return _REGISTRY[normalized]


def resolve_binary(agent_type: str = "", user_home: str = "") -> str:
    """解析 agent 二进制路径。
    优先级：环境变量 > which/where > 常见安装路径
    返回空字符串表示未找到。"""
    config = get_agent_config(agent_type)

    # 1. 环境变量
    exe = os.environ.get(config.env_var_exe, "")
    if exe and os.path.isfile(exe):
        return exe

    # 2. which/where
    binary = config.binary_name if os.name == 'nt' else config.binary_name_unix
    found = shutil.which(binary)
    if found:
        return found

    # 3. npm 全局路径（Windows）
    if os.name == 'nt' and user_home:
        npm_cmd = os.path.join(user_home, 'AppData', 'Roaming', 'npm', binary)
        if os.path.isfile(npm_cmd):
            return npm_cmd

    return ""


def get_session_dir(agent_type: str, project_path: str, user_home: str) -> str:
    """根据 agent 类型和项目路径计算 session 目录。
    项目路径 C:/workspace/serein → slug: C--workspace-serein"""
    config = get_agent_config(agent_type)
    slug = project_path.replace('/\\+$', '').replace('/[\\/]/g', '-').replace(':', '-')
    # Python 版本的 slug 生成
    slug = project_path.rstrip('\\/').replace('\\', '-').replace('/', '-').replace(':', '-')
    return config.session_dir_pattern.format(home=user_home, slug=slug)


def is_supported(agent_type: str) -> bool:
    """检查 agent 类型是否受支持。"""
    return agent_type in _REGISTRY
