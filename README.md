# Beamer Projector

适用于 macOS 26 及更新版本的 Beamer PDF 放映应用。支持丰富的批注功能,并且可以将幻灯片投放到其他屏幕、窗口或者 OBS。

## 源码结构

| 目录 | 职责 |
| --- | --- |
| `Sources/BeamerProjector/App` | 应用入口、窗口生命周期和当前文档的会话状态 |
| `Sources/BeamerProjector/Annotations` | 批注模型、笔迹几何、撤销历史和画笔工具 |
| `Sources/BeamerProjector/Documents` | PDF 读取、导航、保存、导出和批注恢复 |
| `Sources/BeamerProjector/Presentation` | 演讲者界面、画布手势和观众窗口 |
| `Sources/BeamerProjector/Rendering` | 输出布局、页面预览和 Syphon |
| `Sources/BeamerProjector/Settings` | 首选项、快捷键和输出设置 |
| `Sources/NativePDF` | 供 Swift 调用的 qpdf 桥接 |

## 构建和测试

用 Xcode 打开工程，或运行 `./Scripts/build.sh`。完整回归测试使用 `./Scripts/build.sh --test-all`。测试会在运行时生成临时课件，日常课件和导出的 PDF 由 Git 忽略。
