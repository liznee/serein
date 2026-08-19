from PIL import Image, ImageDraw
import os

def make_icon(size, output_path):
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    img = Image.new('RGBA', (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    corner = int(size * 0.213)

    # 浅蓝绿渐变 — iOS 风格，不深不透明
    for y in range(size):
        ratio = y / size
        r = int(64 + (10 - 64) * ratio)     # #40 → #0A
        g = int(162 + (189 - 162) * ratio)   # #A2 → #BD
        b = int(235 + (245 - 235) * ratio)   # #EB → #F5
        color = (r, g, b)
        # 圆角裁剪
        if y < corner:
            dy = corner - y
            dx = int((corner*corner - dy*dy) ** 0.5)
            left = corner - dx
            right = size - (corner - dx)
        elif y >= size - corner:
            dy = y - (size - corner)
            dx = int((corner*corner - dy*dy) ** 0.5)
            left = corner - dx
            right = size - (corner - dx)
        else:
            left = 0
            right = size
        draw.line([(left, y), (right, y)], fill=color)

    # 对勾符号 — 简洁绿色审批标识
    cx = size // 2
    cy = int(size * 0.42)
    s = size * 0.28
    # 对勾三条边
    draw.line(
        [(int(cx - s), int(cy - s*0.1)), (int(cx - s*0.3), int(cy + s*0.55))],
        fill=(52, 199, 89, 255), width=max(4, int(size * 0.06))
    )
    draw.line(
        [(int(cx - s*0.3), int(cy + s*0.55)), (int(cx + s), int(cy - s*0.9))],
        fill=(52, 199, 89, 255), width=max(4, int(size * 0.06))
    )

    img.save(output_path, "PNG")
    print(f"OK: {output_path}")


if __name__ == "__main__":
    import os
    base = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
    for p in [
        f"{base}/entry/src/main/resources/base/media/app_icon.png",
        f"{base}/entry/src/main/resources/base/media/icon.png",
        f"{base}/AppScope/resources/base/media/app_icon.png",
    ]:
        make_icon(256, p)
    make_icon(1024, f"{base}/entry/src/main/resources/base/media/icon_master.png")
    print("All done.")
