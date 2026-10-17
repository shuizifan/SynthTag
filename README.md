# SynthTag

亚马逊「AI 生成人物」合规标签批量工具（Windows）。

自 2026 年 7 月起，亚马逊要求：商品图片/视频中若包含 AI 生成的逼真人物，上传前必须在文件的 XMP `dc:subject` 字段写入关键词 `contains-synthetic-performer`。手动逐个改属性太慢，SynthTag 一键批量搞定。

## 功能

- 窗口标题显示 **SynthTag（打AI标签） v1.2.0**，浅色简洁界面
- 文件名前显示等比缩略图，后台按可见行加载；损坏或无解码器时显示占位图，不改变标签处理状态
- 拖入文件或文件夹（递归子目录），批量写入合规标签
- **加入即检测**：列表用文字和状态徽标区分待添加、已有标签和异常，主按钮实时显示待处理数量
- 顶部显示全部 / 待添加 / 已有标签 / 需关注数量；选中一行即可查看、复制完整路径及异常原因
- 继续添加文件会追加到当前列表，保留前一批结果；清空列表、移出选中项均不删除文件
- 写入前查重自动跳过，写入后立即回读验证，重复标签自动归一
- 检查标签：区分 已有标签 / 待添加 / 重复 / 读取失败
- 支持移除标签、导出带完整路径和错误原因的问题清单 CSV
- 设置中打开本地日志目录、导出诊断 ZIP；INFO / WARNING / ERROR 分级，保留近30天
- 支持中文、空格、方括号路径；处理本地目录、UNC/映射共享目录和虚拟挂载盘
- 应用不主动上传日志或诊断包；共享目录/网盘挂载的文件读写由 Windows 和对应客户端执行

### 列表操作

| 操作 | 说明 |
|---|---|
| `Delete` / `Backspace` | 把选中项移出列表（不动文件本身） |
| `Ctrl + V` | 粘贴添加：支持资源管理器里复制的文件/文件夹，或直接粘贴路径文本（可多行） |
| `Ctrl + A` | 全选 |
| `F5` | 重新检测标签状态并刷新缩略图 |
| 双击 | 在资源管理器中定位该文件 |
| 右键 | 打开所在文件夹 / 复制路径 / 移除选中 / 仅保留选中 |
| 点列头 | 按文件名、类型、状态、文件夹排序 |

支持格式：jpg / jpeg / png / tif / tiff / webp / mp4 / mov / m4v / 3gp

## 使用

**方式一（推荐）**：下载 `SynthTag.exe`，双击即用。单文件免安装，首次运行自动解压内置组件（约 35MB）到本机缓存。

**方式二**：克隆仓库后双击 `start.bat`（需 `app.ps1`、`ui.ps1`、`thumbnail-worker.ps1`、`runtime.ps1`、`metadata.ps1`、`VERSION` 与 `exiftool_bin` 在同一目录）。

> 首次运行如遇 SmartScreen 提示，点「更多信息 → 仍要运行」。

操作：拖入文件/文件夹 → 点「开始添加标签」→ 查看结果统计。上传亚马逊前可用「检查标签」再核对一遍。出现异常时选中对应行，底部会显示详细原因，可复制或导出。

⚠ 是否属于"AI 生成的逼真人物"需人工判断：真实人物、影视/游戏角色、卡通形象、无人物的图**不需要**打标签。

## 共享文件夹写入与异常排查（1.1.0）

1. 先把原文件读取到本机工作目录，ExifTool 仅修改本地副本。
2. 校验媒体结构、标签及图片/视频内容 SHA-256；PNG 额外逐块检查 CRC，防止把元数据可读当成图片完整。
3. 将结果写入目标目录独立临时文件，刷盘并核对完整文件 SHA-256，再使用带备份的替换操作提交；回读通过后才显示成功。
4. 存储驱动明确不支持 `File.Replace` 时，尝试“先完整备份，再重命名替换”的兼容路径；权限、占用、断线等其他错误直接失败。

失败项会标红，选中后在底部查看具体原因，并可导出问题清单。列表不再悬停弹出长诊断浮窗。“文件检查异常”表示文件读取或标签/媒体校验未通过，不等于图片已损坏；缩略图可否显示单独判断，不改变写入校验结果。既存 `_original` / `_exiftool_tmp` 不会被自动覆盖或清理，需先人工确认。发生提交异常时，本地工作目录和恢复记录会保留，下次启动提醒核对；请保留提示的恢复路径。替换期间若发现其他程序修改了原图，会保留备份供核对。

这些措施不能替代远程服务器、网盘客户端的存储可靠性或云端同步状态检查。对不支持安全写入的存储会明确报错。当前验证覆盖 Windows PowerShell 5.1、中文路径、本地文件、本机 SMB/UNC、锁定/只读/损坏输入和写入/替换失败注入；另在实际网盘挂载测试空间验证了PNG/JPEG各6张副本的添加、备份、移除及内容校验。**尚未在美工现场的远程共享目录复现原问题**。视频格式保留支持，本轮未做视频实测。

## 日志与诊断包

- 日志：`%LOCALAPPDATA%\SynthTag\Logs`，按本地日期记录，保留今天及前29天；启动及跨日记录时清理过期日志。
- 严重等级：`INFO`（正常操作）、`WARNING`（警告/兼容处理）、`ERROR`（读取、写入、校验或运行异常）。包含时间、会话、软件版本和必要文件路径。
- 软件中点 **设置 → 打包诊断压缩包**，选择保存位置即可得到 ZIP。ZIP含近30天应用/启动器日志、软件/ExifTool版本、Windows/PowerShell/.NET、架构、语言、时区、磁盘类型/文件系统和 Dokan 安装证据及问题状态。
- 诊断包不含图片、视频、恢复副本或凭证文件；用户名目录和识别到的敏感字段脱敏。文件名、共享路径可能保留，分享前请确认。
- 故障恢复副本与日志分开保存于本机 `%LOCALAPPDATA%\SynthTag\Work`；它们可能含原始图片，不随诊断包导出，也不会套用30天日志清理。
- 单文件组件缓存：`%LOCALAPPDATA%\SynthTag\Cache\1.2.0-<payload SHA256>`，升级不会仅凭包大小复用旧代码。

## 从源码构建

依赖：[Zig](https://ziglang.org/)（交叉编译启动器）+ Python 3。

```powershell
# 1. 编译图标资源
zig rc build/app.rc build/app.res

# 2. 编译启动器 (任意平台均可交叉编译出 Windows exe)
zig cc -target x86_64-windows-gnu -O2 -s '-Wl,--subsystem,windows' -o launcher.exe build/launcher.c build/app.res -lbcrypt

# 3. 打包: launcher + 应用脚本 + 版本 + 图标 + exiftool_bin -> 单文件 exe
python build/make_payload.py launcher.exe SynthTag.exe .
```

如果通过 `python -m pip install ziglang` 安装编译器，将上述 `zig` 替换为 `python -m ziglang`。

Windows 回归测试：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests/metadata.tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests/runtime.tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests/app.tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests/thumbnail-worker.tests.ps1
powershell -NoProfile -ExecutionPolicy Bypass -STA -File tests/thumbnails.tests.ps1 -StressCache
zig cc -target x86_64-windows-gnu -O2 -DTEST_CLI '-Wl,--subsystem,console' -o build/launcher_test.exe build/launcher.c -lbcrypt
python build/test_launcher.py build/launcher_test.exe
python build/test_packaging.py launcher.exe
```

## 目录结构

```
SynthTag.exe        单文件版（launcher + app.ps1 + ExifTool 自解压包）
app.ps1             主程序（PowerShell + WinForms 图形界面）
ui.ps1              窗口布局、现代控件与设置页
thumbnail-worker.ps1 独立只读缩略图进程
metadata.ps1        安全文件读写、校验、恢复流程
runtime.ps1         本地日志、环境诊断、ZIP导出
VERSION             应用版本
start.bat           文件夹版启动入口
exiftool_bin/       内置 ExifTool（亚马逊官方指南推荐的元数据引擎）
assets/             图标源文件（icon.svg + 多尺寸 ICO）
build/launcher.c    自解压启动器源码（C）
build/app.rc        图标资源脚本
build/make_payload.py  打包脚本
tests/              Windows PowerShell 回归测试
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
