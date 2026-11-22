# 萤石云录像批量导出工具

直接使用已登录的萤石云客户端，通过界面自动提交录像下载。不需要 AppKey，不读取账号密码，不关闭客户端。

## 开始前

1. 打开并登录萤石云客户端，保持运行。
2. 打开设备 `K68413322` 的通道 `1`，进入“回放”页面。
3. 客户端停在哪个日期都行，脚本会自己切换。

## 启动

最简单：双击 `start-export.cmd`，按提示输入：

- 日期：`yyyyMMdd`，例如 `20261121`
- 开始时间：`9:15`、`09:15`、`0915`、`09:15:00` 均可
- 结束时间：同上

也可以直接带参数：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\codes\ezviz-export\start-export.ps1 -Day 20261121 -FromTime 15:03 -ToTime 15:41
```

处理过 `fatal.txt` 之后明确重试：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\codes\ezviz-export\start-export.ps1 -Day 20261121 -FromTime 15:03 -ToTime 15:41 -ResetFatal
```

启动成功后会显示控制器 PID、看门狗 PID 和状态目录，下载在后台继续。

## 日期处理（重点）

- 开始前自动点开“日期选择”日历，切换到参数指定的日期。
- 用系统 OCR 回读底部日期，确认确实是目标日期才开始提交。
- 每次提交前再回读一次日期；不是目标日期就拒绝提交并停止，绝不会在错误日期上继续下载。
- 跨月也会自动翻页（左右箭头）。

## 工作方式

- 每 5 分钟切一段，默认同时保持 4 个下载任务。
- 同一时间只允许一个导出控制器操作客户端。
- 时间框采用“剪贴板粘贴 + 复制回读校验”，回读不一致不会点下载。
- 下载成功后会收起萤石窗口。
- 遇到“继续播放”提示时自动关闭并暂停画面。
- 提交是否成功只以 `PLUG.log` 中的下载键为准，不靠截图判断。
- 同一段提交失败达到重试上限后停止并写入 `fatal.txt`，不会无限重提。
- 出现 `fatal.txt` 后默认拒绝再次启动，确认后再加 `-ResetFatal`。
- 每段完成后用 `ffprobe` 校验；损坏或时长不足不计入完成。
- 断点保存在 `done.txt`，重复启动同一时会自动续跑。
- 校验失败的段写入 `invalid.txt`，不会被伪装成完整。

## 查看进度

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\codes\ezviz-export\status.ps1 -Day 20261121 -FromTime 15:03 -ToTime 15:41
```

自定义过 `Tag` 时追加 `-Tag 你的Tag`。

## 停止

```powershell
New-Item -ItemType File -Force -Path "E:\codes\ezviz-export\state\day20261121_150300-154100\stop"
```

已经提交到萤石客户端的下载会继续完成。

## 合并

合并为一个文件：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\codes\ezviz-export\merge.ps1 -Day 20261121 -FromTime 15:03 -ToTime 15:41
```

按小时分组合并：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File E:\codes\ezviz-export\merge.ps1 -Day 20261121 -FromTime 9:00 -ToTime 20:00 -Hourly
```

需要完整解码检查时在命令末尾加 `-FullDecode`。合并前逐段校验，缺失或损坏的段会直接报错。

输出目录：`E:\codes\ezviz-export\output\<Tag>\`

## 文件说明

- `start-export.ps1`：参数输入、环境预检、启动后台任务
- `start-export.cmd`：双击入口
- `export.ps1`：分批提交、断点、日志校验、下载结果校验
- `watch.ps1`：控制器异常退出后自动续跑
- `ui-helper.ps1`：唯一负责萤石界面操作的脚本（含日期选择与 OCR 校验）
- `run-ui-task.ps1`：隔离桌面中运行界面任务，并强制超时回收
- `status.ps1`：进度与逐段状态
- `merge.ps1`：校验并合并

运行数据在 `state\<Tag>\`，合并结果在 `output\<Tag>\`。

## 固定路径

- 原始录像：`E:\ezviz-record`
- 萤石日志：`D:\Program Files (x86)\Ezviz Studio\log\PLUG.log`
- ffmpeg：`D:\ffmpeg\bin\ffmpeg.exe`
- ffprobe：`D:\ffmpeg\bin\ffprobe.exe`

这些路径变化时需要修改对应脚本顶部参数。
