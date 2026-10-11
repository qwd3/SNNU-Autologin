# SNNU 校园网自动认证

陕西师范大学校园网自动登录 + 掉线自动重连。

**纯 Windows PowerShell,零依赖** —— 不需要装 Python、不需要装任何模块、不需要管理员权限。

---

## 快速开始(傻瓜式:双击就行)

**不用记任何命令,也不用懂 PowerShell。**

| 双击这个文件 | 作用 |
|---|---|
| **`一键安装.bat`** | 自动做完 5 步:检查网络 → 配置账号密码 → 校验 → 真实测试 → 装开机自启 |
| **`查看状态.bat`** | 看当前认证状态、守护进程有没有在跑、最近 10 行日志 |
| **`一键卸载.bat`** | 停掉后台守护进程 + 删掉开机自启任务(保留账号配置) |

安装时它会依次问你三件事(只填这一次):

```
请输入校园网账号(学号, 例如 20250001): ____

请选择上网出口(代理商):
  1) 校园网(默认)   走教育网, 有 IPv6, 每月有免费外网额度
  2) 中国联通(代拨) 费用自理, 不限量
  3) 中国移动(代拨) 费用自理, 不限量
  4) 中国电信(代拨) 费用自理, 不限量
请输入 1-4 (直接回车 = 1 校园网): ____

请输入校园网密码(输入时不显示): ____
请再次输入以确认: ____
```

装完之后再也不用碰了。掉线不用管 —— 守护进程每 30 秒检查一次,掉线会在 30 秒内自动重连。

> 想先看看它会做什么、但**不改系统**?设个环境变量再运行,就是「演练模式」:
> ```powershell
> $env:SNNU_WIZARD_DRYRUN = '1'
> .\install-wizard.ps1 -Mode Install
> ```

---

## 命令行用法(进阶)

```powershell
.\SNNU-AutoLogin.ps1 -Setup      # 首次配置 / 改配置(交互式)
.\SNNU-AutoLogin.ps1             # 检查一次,离线就认证
.\SNNU-AutoLogin.ps1 -Status     # 只看状态(不需要账号密码)
.\SNNU-AutoLogin.ps1 -Diagnose   # 完整体检(不需要账号密码,排错先跑这个)
.\SNNU-AutoLogin.ps1 -TestLogin  # 只检查账号是否存在,不断开现有连接
.\SNNU-AutoLogin.ps1 -Force      # 强制重新认证(先 logoff 再 login,会断网约 10 秒)
.\SNNU-AutoLogin.ps1 -Logout     # 主动断开校园网
.\SNNU-AutoLogin.ps1 -Daemon     # 常驻后台,掉线自动重连(开机自启用这个)
```

### 脚本化的无人值守配置

不方便交互时,可以一次把参数给全:

```powershell
.\SNNU-AutoLogin.ps1 -Setup -Account 20250001 -Isp mobile -Password 你的密码
```

`-Isp` 取值:`""` = 校园网默认,`unicom` = 联通,`mobile` = 移动,`telecom` = 电信。

### 密码是怎么存的

默认用 **Windows DPAPI 加密**存进 `config.json` 的 `passwordProtected` 字段,
`password` 字段留空。DPAPI 的密文**只有本机 + 本用户**能解开:

- 换电脑、重装系统、把 `config.json` 拷给别人 → 解不开,需要重新运行 `-Setup`
- 想改回明文保存:`.\Set-Password.ps1 -Plain`

---

## 配置文件

`config.json` 会在首次配置时自动生成。想手工调整的话:

```json
{
  "account": "20250001",
  "password": "",
  "passwordProtected": "<DPAPI 密文>",
  "isp": "mobile",
  "portal": "http://202.117.144.205:8601",
  "portalFallback": "http://202.117.144.205:8602",
  "checkIntervalSeconds": 30,
  "failureRetrySeconds": 60,
  "expectedSsid": "SNNU",
  "accountWithSuffix": "auto",
  "logoffBeforeLogin": false,
  "checkUrls": [
    "http://connect.rom.miui.com/generate_204",
    "http://www.msftconnecttest.com/connecttest.txt",
    "http://captive.apple.com/hotspot-detect.html"
  ]
}
```

| 字段 | 说明 |
|---|---|
| `isp` | 上网出口:`""` 校园网 / `unicom` / `mobile` / `telecom` |
| `portal` | 认证服务地址。学校换端口时改这里(常见 `8601` → `8602`) |
| `checkIntervalSeconds` | 守护模式检查间隔 |
| `expectedSsid` | 只在连到这个 WiFi 时认证;留空 = 不限制 |
| `accountWithSuffix` | `auto` = 先试 `account`,失败再试 `account@isp` |

---

## 它是怎么判断"要不要认证"的

三层判断,不只看能不能上网:

1. **出口连通性**:请求 `generate_204` 探测点。未认证时校园网会 302 劫持到 portal,所以只有拿到 2xx 才算真通。
2. **portal 状态**:读 `login.jsp`,页面出现"当前登录账号"= 已认证;出现密码输入框 = 未认证。
3. **僵死会话检测**:portal 说"已在线"但外网不通(会话过期/网关没放行)→ 先 `logoff` 再重新登录。

另外会校验当前 WiFi SSID 是否为配置里的值,不在校园网时直接跳过,避免在家做无效登录。

---

## 防账号锁定

校园网 portal 对连续失败登录可能触发验证码或临时锁定。脚本做了三层保护:

- **登录前先校验账号存在性**(走非会话接口,不影响现有连接),账号都查不到就直接放弃
- **断路器**:连续失败 3 次后指数退避(60s → 120s → 240s…最高 30 分钟一次)
- **配置缺失时拒绝登录**:不会拿占位符去试密码

如果日志反复出现"登录未成功",**先用浏览器手动登录一次**,确认是密码错了还是被要求输验证码 —— 脚本无法自动过验证码。

---

## 开机自启是怎么配的

`install-autostart.ps1` 注册一个名为 `SNNU-AutoLogin` 的计划任务:

- **触发**:① 登录后延迟 15 秒;② **每 1 分钟重复一次**(自愈)
- **动作**:`wscript.exe //nologo SNNU-AutoLogin-hidden.vbs`
  —— 由 VBS 以窗口样式 0 拉起 PowerShell。**不用 `powershell.exe -WindowStyle Hidden` 是因为那个参数在控制台创建之后才隐藏,每次启动会闪一下窗;`wscript` 自己不带控制台,所以真正无窗口。**
- **设置**:隐藏窗口、失败自动重启 3 次、不限运行时长、电池供电也启动
- **权限**:当前用户身份、最低权限(所以不需要管理员)

**自愈**:守护进程被杀/崩溃/被安全软件误杀后,最多 **1 分钟**会被重复触发器重新拉起。
健康时这个触发器**零开销** —— VBS 会一直等到守护进程退出,所以任务始终是 Running,
`IgnoreNew` 会让重复触发直接跳过,不会起第二个实例、也不会闪窗。

守护进程带**单实例互斥锁**,重复启动不会抢认证。

> 注册/覆盖任务后脚本会**立刻启动**守护进程并等它起来(实测整个安装 3 秒),
> 所以装完马上就有保护,不会留下"装好了但还没跑"的空窗。

---

## 排错

**Q: 日志说"两个 portal 地址都不可达"**
不在校园网内,或连的不是 `SNNU`。先跑 `-Diagnose` 看 portal 可达性那一节。

**Q: 日志说"登录未成功"**
跑 `-Diagnose` 看配置;然后用浏览器手动登录一次,确认密码对不对、有没有验证码、账号有没有欠费。

**Q: 端口 8601 连不上**
学校偶尔换端口。把 `portal` 改成 `8602`(脚本本身也会自动尝试备用端口)。

**Q: 手动运行正常,开机不会自动连**
跑 `.\install-autostart.ps1 -Status` 看计划任务是否 Ready。被组策略拦住的话用 `-Method Startup`。

**Q: `查看状态.bat` 说守护进程没在跑**
不用慌,手动跑 `.\install-autostart.ps1` 立刻拉起;即使不管,1 分钟内也会自动被拉起来。

**Q: 会不会每 30 秒登录一次把账号搞锁**
不会。已联网时脚本完全不发登录请求;只有掉线才登录,且失败会指数退避。

**Q: 首次运行时提示"当前环境没有可用的交互控制台"**
说明不是在普通 PowerShell 窗口里跑的(比如输出被重定向了)。直接在窗口里运行,或用 `-Setup` 带参数一次性给出配置。

---

## 文件说明

```
SNNU-AutoLogin/
├── 一键安装.bat            双击:完整安装(检查→配置→校验→测试→装自启)
├── 查看状态.bat            双击:看状态 + 守护进程 + 最近日志
├── 一键卸载.bat            双击:停守护进程 + 删开机自启
├── install-wizard.ps1      上面三个 .bat 背后的逻辑
├── SNNU-AutoLogin.ps1      主脚本(认证 / 守护 / 诊断 / 配置引导)
├── install-autostart.ps1   安装 / 卸载 / 查看开机自启
├── Set-Password.ps1        单独改密码或账号
├── config.example.json     配置示例(实际用的是 config.json,首次配置时生成)
├── .gitignore              已排除 config.json / logs / 生成的 vbs
└── 相关-B站卡顿修复/        (可选)校园网下 B站 卡顿的浏览器端修复
```

> `config.json`、`logs\`、`SNNU-AutoLogin-hidden.vbs` 都不会随仓库分发:
> 前两个含个人账号与网络信息,第三个含本机绝对路径且在安装时自动生成。

---

## 说明

- 这是基于实测写出来的第三方脚本,**非学校官方工具**,请自行判断是否符合学校网络使用规定。
- 认证接口随时可能被学校调整。真变了的话,改 `config.json` 里的 `portal`,或参考 `SNNU-AutoLogin.ps1` 里的接口说明。
- 许可:见 `LICENSE`。
