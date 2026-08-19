"""Install and enable Blender MCP without hard-coding a user profile path.

Run with:
  blender --background --python tools/blender/install_blender_mcp.py -- PATH_TO_ADDON_PY
"""

from __future__ import annotations

import importlib
import shutil
import sys
from pathlib import Path

import bpy


def script_args() -> list[str]:
    if "--" not in sys.argv:
        return []
    return sys.argv[sys.argv.index("--") + 1 :]


def main() -> None:
    args = script_args()
    if len(args) != 1:
        raise SystemExit("Expected one argument: path to Blender MCP addon.py")

    source = Path(args[0]).expanduser().resolve()
    if not source.is_file():
        raise FileNotFoundError(source)

    addons_dir = Path(
        bpy.utils.user_resource("SCRIPTS", path="addons", create=True)
    ).resolve()
    target_dir = addons_dir / "blender_mcp"
    target_dir.mkdir(parents=True, exist_ok=True)
    target = target_dir / "__init__.py"
    shutil.copy2(source, target)

    addons_dir_text = str(addons_dir)
    if addons_dir_text not in sys.path:
        sys.path.insert(0, addons_dir_text)
    importlib.invalidate_caches()
    bpy.ops.preferences.addon_refresh()
    if "blender_mcp" not in bpy.context.preferences.addons:
        bpy.ops.preferences.addon_enable(module="blender_mcp")

    addon = bpy.context.preferences.addons.get("blender_mcp")
    if addon and hasattr(addon.preferences, "telemetry_consent"):
        addon.preferences.telemetry_consent = False

    scene = bpy.context.scene
    if hasattr(scene, "blendermcp_use_polyhaven"):
        scene.blendermcp_use_polyhaven = False
    if hasattr(scene, "blendermcp_use_sketchfab"):
        scene.blendermcp_use_sketchfab = False
    if hasattr(scene, "blendermcp_use_hyper3d"):
        scene.blendermcp_use_hyper3d = False
    if hasattr(scene, "blendermcp_use_hunyuan3d"):
        scene.blendermcp_use_hunyuan3d = False
    if hasattr(scene, "blendermcp_auto_start_server"):
        scene.blendermcp_auto_start_server = True

    bpy.ops.wm.save_userpref()
    print(f"SEREIN_BLENDER_MCP_INSTALLED={target}")


if __name__ == "__main__":
    main()
