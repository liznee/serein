# Serein 官网实现与维护说明

> 更新日期：2026-08-18
>
> 适用目录：`ui/`

## 1. 当前定位

官网是面向桌面浏览器的四章节宣传页，目标顺序为：

1. 先建立产品印象；
2. 再解释完整工作流与差异化；
3. 给出可核验的工程、安全和鸿蒙原生信息；
4. 最后引导阅读文档、查看源码和联系维护者。

页面默认中文，支持英文切换。当前不以手机网页适配为目标，HarmonyOS 原生 App 才是移动端产品。

## 2. 四个全屏章节

| 章节 | 主要内容 | 关键交互 |
|---|---|---|
| 首页 | 品牌文案与五张真实 App 截图 | 截图在 3D 轨道持续旋转，经过正前方时平行展示 |
| 工作流 | Serein Studio 3D 场景、显示器宣传视频、Issue 全流程 | 鼠标轻微视差；点击显示器后镜头推进、视频开启声音 |
| 工程能力 | 移动工作流、鸿蒙原生、语言选型、工程规模和安全边界 | 章节进入时使用三层曲面幕布转场 |
| 开源与联系 | 自托管边界、部署入口、GitHub 联系方式 | 章节进入时使用三层曲面幕布转场 |

页面通过整屏章节导航控制滚轮，每次有效滚动只前进或后退一个章节。第一、二章保持内容本身的交互；第三、四章在内容切换前播放幕布。

## 3. 动效实现

- GSAP 与 ScrollTrigger 位于 `ui/assets/`，用于截图轨道、文字揭幕和页面动效。
- `ui/landing.js` 负责整屏章节导航、三层幕布、截图轨道和交互卡片。
- 幕布由三块有限宽度的曲面色带组成，依次追赶而不交叉：
  - 向下浏览时从上往下覆盖；
  - 向上浏览时从下往上覆盖；
  - 新页面在完全遮住旧页面后切换；
  - 收尾阶段仅最后一小段由曲线自然收直，不会出现整屏单色停顿。
- `prefers-reduced-motion` 下应保留可用性，避免强制播放复杂动效。

调整幕布时优先修改 `ui/landing.js` 中的章节转场时间线，不要用页面实际滚动距离驱动，否则会先露出下一章再播放遮罩。

## 4. 3D 场景与视频

场景源文件与产物：

- `tools/blender/create_serein_studio.py`：原创场景生成脚本；
- `ui/assets/models/serein-studio.blend`：Blender 可编辑源文件；
- `ui/assets/models/serein-studio.glb`：官网运行时模型；
- `ui/assets/models/serein-studio-preview.png`：场景预览；
- `ui/workflow-scene.js`：Three.js 场景加载、视差、显示器热点和镜头推进；
- `ui/assets/workflow-scene.bundle.js`：浏览器运行包，由 `npm run build:web` 生成。

模型中的 `SereinVideoSurface` 是显示器画面专用网格。宣传视频通过网页视频元素和 Three.js 纹理共同播放：

- 场景远景中，视频持续静音循环；
- 点击显示器后，镜头先移动到显示器，再切换为聚焦状态；
- 聚焦状态允许播放声音；
- 退出聚焦后恢复静音，避免浏览器自动播放策略阻止页面初始化。

宣传视频位于 `ui/assets/serein-workflow.mp4`。原始生成视频和原始手机截图不进入公开仓库；如果需要重做画面替换，使用：

```powershell
python tools/video/replace_promo_screens.py `
  --input "path\to\watermark-free-promo.mp4" `
  --ffmpeg "path\to\ffmpeg.exe" `
  --capture project="path\to\project.jpg" `
  --capture terminal="path\to\terminal.jpg" `
  --capture community="path\to\community.jpg" `
  --capture approval="path\to\approval.jpg" `
  --capture remote="path\to\remote.jpg"
```

脚本不保存个人目录、账号或固定截图路径。提交前只保留处理后的成片，并再次检查视频画面是否包含 Token、服务器地址、设备 ID、私人仓库路径或无权公开的素材。

## 5. 品牌与素材

- 浏览器标签页、页头和页脚统一使用 `ui/assets/serein-mark.png`。
- 主色保持与 App 一致的珊瑚色，搭配暖白、深蓝灰和少量对比色。
- 官网使用的 App 截图是经过人工检查的公开展示图。
- 第三方运行库及许可记录在 `ui/assets/THIRD_PARTY_NOTICES.md`。
- 试验阶段下载的 3D 素材不属于最终场景，不应进入公开提交；公开站点提交的 `serein-studio` 场景由项目脚本生成。
- 对外文案先说明产品能力、适用边界和成熟度，再保留少量个人化表达；不要把设计指令、写作过程或数据取舍过程写成宣传语。

## 6. 本地预览与验证

不要直接依赖 `file://` 验证模块、视频和缓存行为，使用本地 HTTP 服务：

```powershell
npm run preview:web
```

保持这个终端窗口运行。预览脚本会从 `ui/` 提供静态文件，并为 MP4 正确处理 HTTP Range 请求；关闭窗口后 `127.0.0.1:4173` 就无法继续访问。

浏览器打开：

```text
http://127.0.0.1:4173/index.html
```

提交前至少执行：

```powershell
node --check ui/landing.js
node --check ui/water-buttons.js
node --check ui/workflow-scene.js
python -m py_compile tools/video/replace_promo_screens.py
npm run build:web
git diff --check
```

人工检查：

1. 连续向下四次与向上四次，确认每次只切换一个章节；
2. 正反方向幕布均完整播放，三色不交叉、不出现整屏单色停顿；
3. 五张截图都能经过正前方，且不会被浏览器顶部裁切；
4. 3D 场景视频远景持续播放，聚焦后居中并能开启声音；
5. 中文、英文切换后没有溢出或残留；
6. 浏览器控制台没有资源 404、模块错误或自动播放异常。

若页面能打开但视频无法播放：

1. 确认 `npm run preview:web` 仍在运行；
2. 确认 `ui/assets/serein-workflow.mp4` 存在；
3. 在浏览器网络面板检查视频请求是否返回 `200` 或 `206`，拖动/续播请求应返回 `206 Partial Content`；
4. 强制刷新，避免旧视频查询参数或缓存继续生效；
5. 不要用 `file://` 的结果判断正式网站的视频能力。

## 7. 发布边界

- 官网只展示真实能力，不写无法核验的稳定性、唯一性或百分比数据。
- “鸿蒙原生”可以作为差异化重点，但对市场唯一性的表述必须在发布时重新核验。
- 个人服务器地址、OAuth Secret、Token、设备信息、私人路径和未脱敏截图不得进入公开版。
- `ui/assets/serein-workflow.mp4` 约 18 MB，低于 GitHub 单文件限制；部署时仍建议启用静态资源压缩、缓存和 Range 请求。
- 官网只呈现一个完整的开源版本；当前已有功能全部开放，稳定核心与实验功能仅按成熟度区分。
