# iFudan.stu 自动登录

该工具在 Windows 连接到 `iFudan.stu` 后，调用校园网登录页自身的认证接口完成登录。

## 安装

1. 双击 `Install.cmd`。
2. 接受 Windows UAC 管理员权限提示；这是创建 Wi-Fi 连接事件触发任务所必需的。
3. 按提示输入校园网用户名/学号和密码。密码输入时不会显示。
4. 如果检测到当前出口，直接按回车保留即可。
5. 看到“安装完成”后关闭窗口。

如果前一次安装已经成功保存 DPAPI 密文但在创建计划任务时失败，重新运行时会直接复用密文，不会再次要求输入密码。

安装程序会创建当前用户的计划任务 `iFudan.stu Auto Login`：

- 连接 `iFudan.stu` 后约 5 秒运行。
- Windows 登录后也会检查一次。
- 已经联网或连接其他 Wi-Fi 时不会重复提交登录。
- 登录失败只写本地日志，不会循环快速重试。

## 凭据安全

- 用户名和密码通过 Windows DPAPI 加密，保存在 `%LOCALAPPDATA%\iFudanAutoLogin\secret.bin`。
- 密文只能由当前 Windows 用户在当前用户环境中解密。
- 安装目录 ACL 会限制为当前用户访问。
- 日志不会记录用户名、密码或完整登录响应。
- 密码只会发送到 `http://10.102.250.36/api/v1/login`，与网页登录使用的接口一致。

## 检查状态

日志位置：

```text
%LOCALAPPDATA%\iFudanAutoLogin\AutoLogin.log
```

手动执行只读状态检查：

```powershell
& "$env:LOCALAPPDATA\iFudanAutoLogin\AutoLogin.ps1" -StatusOnly
```

## 修改密码或出口

重新双击 `Install.cmd`，输入新凭据即可覆盖旧配置。

## 卸载

双击 `Uninstall.cmd`。它会删除计划任务、本地脚本、日志及 DPAPI 密文。
