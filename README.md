# WeChat Cache Cleaner

适用于 Windows 微信的命令行清理工具。扫描当前用户的 `%APPDATA%\Tencent\xwechat`，无需管理员权限。需要 Python 3.10 或更新版本，无第三方依赖。

## 使用

在项目目录打开 PowerShell，先预览默认清理项。

```powershell
python cleaner.py
```

从系统托盘退出微信后，执行默认清理。

```powershell
python cleaner.py --apply
```

默认清理范围包括 `log` 下的 `.xlog` 日志、小程序代码缓存和图标，以及网页配置文件中的 HTTP、代码和 GPU 缓存。聊天记录、登录配置、小程序本地数据、网页存储和插件元数据保留。

## 可选清理

```powershell
python cleaner.py --packages --plugins
```

- `--packages` 加入小程序安装包目录。再次使用小程序时，微信可能需要重新下载安装包。
- `--plugins` 加入 `XPlugin/Plugins` 中的已安装插件文件。OCR、播放器等功能可能暂时不可用，直到微信重新下载所需插件。插件恢复取决于微信版本和下载服务。

可以单独使用任意一个选项。确认预览结果后，在相同命令末尾加 `--apply` 才会永久删除文件。工具会跳过符号链接、目录联接和带有其他硬链接的文件，保留目录结构。扫描显示的是文件逻辑大小，实际释放空间以 Windows 为准。

## 测试

```powershell
python -B -m unittest -v
```

## 许可证

源码按 [PolyForm Noncommercial 1.0.0](LICENSE) 授权。许可证允许非商业用途下使用、修改和分发。商业使用须另行获得授权，具体范围以许可证条款为准。
