"""serein App 图标生成器
用户图标直接缩放到目标尺寸，填满整画布，无内边距，无额外背景框。
"""
from PIL import Image
import os

import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
USER_ICON = os.path.join(SCRIPT_DIR, "..", "..", "ui", "app", "screen-removebg-preview.png")

LAYERED_DIR = os.path.join(SCRIPT_DIR, "..", "AppScope", "resources", "base", "media")


def scale_to_fill(img: Image.Image, size: int) -> Image.Image:
    """等比例缩放填满整画布，不裁剪。"""
    scaled = img.copy()
    scaled.thumbnail((size, size), Image.LANCZOS)
    canvas = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    x = (size - scaled.width) // 2
    y = (size - scaled.height) // 2
    canvas.paste(scaled, (x, y), scaled)
    return canvas


def main() -> None:
    if not os.path.exists(USER_ICON):
        print(f"ERROR: {USER_ICON}")
        return

    img: Image.Image = Image.open(USER_ICON).convert("RGBA")
    print(f"源图: {img.size[0]}x{img.size[1]}")

    # foreground — Logo 填满 1024
    fg = scale_to_fill(img, 1024)
    fg.save(f"{LAYERED_DIR}/foreground.png", "PNG")
    print(f"foreground.png → 1024x1024")

    # background — 和 foreground 一样（没额外背景框）
    fg.save(f"{LAYERED_DIR}/background.png", "PNG")
    print(f"background.png → 1024x1024")

    # 普通图标 256px
    for path in [
        f"{LAYERED_DIR}/app_icon.png",
        os.path.join(SCRIPT_DIR, "..", "entry", "src", "main", "resources", "base", "media", "app_icon.png"),
        os.path.join(SCRIPT_DIR, "..", "entry", "src", "main", "resources", "base", "media", "icon.png"),
    ]:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        scale_to_fill(img, 256).save(path, "PNG")
        print(f"{os.path.basename(path)} → 256x256")

    # master 1024
    mp = os.path.join(SCRIPT_DIR, "..", "entry", "src", "main", "resources", "base", "media", "icon_master.png")
    scale_to_fill(img, 1024).save(mp, "PNG")
    print(f"icon_master.png → 1024x1024")

    print("完成。")


if __name__ == "__main__":
    main()
