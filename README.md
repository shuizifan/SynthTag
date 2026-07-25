# SynthTag

亚马逊「AI 生成人物」合规标签批量工具（Windows）。

自 2026 年 7 月起，亚马逊要求：商品图片/视频中若包含 AI 生成的逼真人物，上传前必须在文件的 XMP `dc:subject` 字段写入关键词 `contains-synthetic-performer`。手动逐个改属性太慢，SynthTag 一键批量搞定。

## 功能

- 拖入文件或文件夹（递归子目录），批量写入合规标签
- **加入即检测**：列表直接标出标签状态，已有标签的文件划删除线置灰，主按钮实时显示待处理数量
- 写入前查重自动跳过，写入后立即回读验证，重复标签自动归一
- 体检扫描：区分 已打标签 / 未打标签 / 重复 / 读取失败
- 支持移除标签、导出问题清单 CSV
- 本地离线运行，不联网、不上传；中文/空格路径无压力

### 列表操作

| 操作 | 说明 |
|---|---|
| `Delete` / `Backspace` | 把选中项移出列表（不动文件本身） |
| `Ctrl + V` | 粘贴添加：支持资源管理器里复制的文件/文件夹，或直接粘贴路径文本（可多行） |
| `Ctrl + A` | 全选 |
| `F5` | 重新检测标签状态 |
| 双击 | 在资源管理器中定位该文件 |
| 右键 | 打开所在文件夹 / 复制路径 / 移除选中 / 仅保留选中 |
| 点列头 | 按文件名、类型、状态、文件夹排序 |

支持格式：jpg / jpeg / png / tif / tiff / webp / mp4 / mov / m4v / 3gp

## 使用

**方式一（推荐）**：下载 `SynthTag.exe`，双击即用。单文件免安装，首次运行自动解压内置组件（约 35MB）到本机缓存。

**方式二**：克隆仓库后双击 `start.bat`（需 `app.ps1` 与 `exiftool_bin` 在同一目录）。

> 首次运行如遇 SmartScreen 提示，点「更多信息 → 仍要运行」。

操作：拖入文件/文件夹 → 点「开始添加标签」→ 查看结果统计。上传亚马逊前可用「体检扫描」再核对一遍。

⚠ 是否属于"AI 生成的逼真人物"需人工判断：真实人物、影视/游戏角色、卡通形象、无人物的图**不需要**打标签。

## 从源码构建

依赖：[Zig](https://ziglang.org/)（交叉编译启动器）+ Python 3。

```bash
# 1. 编译图标资源
zig rc build/app.rc build/app.res

# 2. 编译启动器 (任意平台均可交叉编译出 Windows exe)
zig cc -target x86_64-windows-gnu -O2 -s -Wl,--subsystem,windows \
  -o launcher.exe build/launcher.c build/app.res

# 3. 打包: launcher + app.ps1 + 图标 + exiftool_bin -> 单文件 exe
python3 build/make_payload.py launcher.exe SynthTag.exe .
```

## 目录结构

```
SynthTag.exe        单文件版（launcher + app.ps1 + ExifTool 自解压包）
app.ps1             主程序（PowerShell + WinForms 图形界面）
start.bat           文件夹版启动入口
exiftool_bin/       内置 ExifTool（亚马逊官方指南推荐的元数据引擎）
assets/             图标源文件（icon.svg + 多尺寸 ICO）
build/launcher.c    自解压启动器源码（C）
build/app.rc        图标资源脚本
build/make_payload.py  打包脚本
```

图标基于 [Lucide](https://lucide.dev)（ISC License）的 tag / sparkle 图形二次设计。

## 技术说明

标签写入 XMP `dc:subject`（与 Windows 资源管理器"标记"字段同一位置），底层调用 [ExifTool](https://exiftool.org)。验证方式与亚马逊官方一致：

```
exiftool -G1 文件名
# [XMP-dc] Subject : contains-synthetic-performer
```

## License

MIT。内置的 ExifTool 遵循其自身的 [Perl Artistic License](https://exiftool.org)。
