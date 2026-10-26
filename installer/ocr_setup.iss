; 字迹 Windows 安装包脚本（仿照 mingji_flutter/installer/mingji_setup.iss）
; 编译方式：运行同目录 build_installer.bat（自动读版本号 + 编译 Flutter + 调 ISCC），
; 或手动：ISCC /DMyAppVersion=1.0.0 ocr_setup.iss
#define MyAppName "字迹"
#define MyAppExeName "ziji.exe"
#define MyAppSourceDir "..\flutter_app\build\windows\x64\runner\Release"
#define MyAppIconFile "..\flutter_app\windows\runner\resources\app_icon.ico"
#ifndef MyAppVersion
  ; 单独用 ISCC 编译而未传 /DMyAppVersion 时的兜底版本号
  #define MyAppVersion "1.0.3"
#endif

[Setup]
AppId={{B7F3E2A1-8C45-4D69-9E0A-53F1D2B87C66}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppName}
; 安装到用户目录而不是 Program Files：运行时识别服务要在自己的 python_service
; 目录里写 Kraken 模型下载、训练数据集、模型注册表等，Program Files 没有写权限。
; 目录名用英文 ZiJi（1.0.0+103 前为 GujiBT；同 AppId 升级安装会沿用旧目录，
; 全新安装进 ZiJi），避免 conda/uvicorn 对中文路径的兼容问题。
DefaultDirName={localappdata}\Programs\ZiJi
PrivilegesRequired=lowest
DefaultGroupName={#MyAppName}
AllowNoIcons=yes
OutputDir=output
OutputBaseFilename=ziji_setup_{#MyAppVersion}
SetupIconFile={#MyAppIconFile}
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
; 最低要求 Windows 10
MinVersion=10.0
ArchitecturesInstallIn64BitMode=x64compatible
ArchitecturesAllowed=x64compatible
; 安装后不强制重启
RestartIfNeededByRun=no
; 卸载时显示图标
UninstallDisplayIcon={app}\{#MyAppExeName}
UninstallDisplayName={#MyAppName}

[Languages]
; 中文语言包随仓库自带（installer/ChineseSimplified.isl，Inno Setup 官方非官方翻译）
Name: "chinesesimplified"; MessagesFile: "ChineseSimplified.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加图标:"; Flags: unchecked

[Files]
; VC++ 2015-2022 运行库（解决部分系统缺少 VCRUNTIME140_1.dll 的问题）
Source: "vc_redist.x64.exe"; DestDir: "{tmp}"; Flags: deleteafterinstall
; 主程序和所有 DLL
Source: "{#MyAppSourceDir}\{#MyAppExeName}"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MyAppSourceDir}\*.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#MyAppSourceDir}\native_assets.json"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
; data 目录（含 flutter_assets、icudtl.dat、app.so 等）
Source: "{#MyAppSourceDir}\data\*"; DestDir: "{app}\data"; Flags: ignoreversion recursesubdirs createallsubdirs
; 识别服务（Python 后端）。排除开发用内容：本地虚拟环境、Python 缓存、
; 训练数据集、日志、下划线开头的临时图、可行性调研报告、测试脚本、
; 旧版手动安装 bat；模型一律走下面的 .zjpack 发行包，散装模型/权重/
; 管理员私钥/物化缓存/逐项目墨迹模板全部排除在外。
Source: "..\python_service\*"; DestDir: "{app}\python_service"; \
  Excludes: ".venv,.venv\*,__pycache__,__pycache__\*,datasets,datasets\*,models\*,*.log,_*,kraken_feasibility*,test_*,install*.bat,*.pt,kraken_models,kraken_models\*,release_keys,release_keys\*,.model_cache,.model_cache\*,verify_templates,verify_templates\*,models_release*.zjpack,*.zjpack.tmp"; \
  Flags: ignoreversion recursesubdirs createallsubdirs skipifsourcedoesntexist
; 发版模型包（Ed25519 签名的 .zjpack）：用户机的各层 YOLO 与 Kraken 识别
; 模型都从这里验签物化（上面已排除全部散装模型），装完即可离线识别。
; 未打包时跳过（开发/测试安装包）：Kraken 模型首次识别时在线下载兜底。
Source: "..\python_service\models_release.zjpack"; DestDir: "{app}\python_service"; \
  Flags: ignoreversion skipifsourcedoesntexist
; 更新日志（应用内「设置 → 说明 → 更新日志」读取；安装目录即
; python_service 上级，与客户端的路径探测一致）
Source: "..\CHANGELOG.md"; DestDir: "{app}"; Flags: ignoreversion skipifsourcedoesntexist
; （说明：墨迹校验用的楷体字形 resources\fonts\LXGWWenKai-Regular.ttf
; 约 24.7 MB，随上面 python_service\* 的递归拷贝一并进包，无需单列）

[Dirs]
; 训练模型注册表（models/registry.json）的写入位置，目录为空不会被上面
; 的通配符带出来，预先创建
Name: "{app}\python_service\models"

[Icons]
; 开始菜单快捷方式
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"
Name: "{group}\卸载 {#MyAppName}"; Filename: "{uninstallexe}"
; 桌面快捷方式（可选）
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; IconFilename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
; 静默安装 VC++ 2015-2022 运行库（/install=静默安装，/quiet=无UI，/norestart=不重启）
Filename: "{tmp}\vc_redist.x64.exe"; Parameters: "/install /quiet /norestart"; StatusMsg: "正在安装 Visual C++ 运行库..."; Flags: waituntilterminated
; 安装完成后可选择立即启动
Filename: "{app}\{#MyAppExeName}"; Description: "立即启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

; 说明：卸载只删除安装目录。书籍项目（文档\GujiBT）、conda 环境、
; 已训练的模型数据都保留，不受卸载影响。已导入的插件装在用户应用
; 数据目录，同样不受卸载影响。

[Code]
// ── WebView2 运行库（插件系统内嵌网页用） ─────────────────────────
// Win10（较新补丁）/Win11 系统自带；检测 per-user 与 per-machine 两种
// 安装位置，缺失时在线引导安装官方 Evergreen 运行库。
function WebView2Installed(): Boolean;
begin
  Result :=
    RegKeyExists(HKLM, 'SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') or
    RegKeyExists(HKLM, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}') or
    RegKeyExists(HKCU, 'SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}');
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  resultCode: Integer;
begin
  Result := '';
  if WebView2Installed() then exit;
  try
    // 签名（Inno 6.7）：Url, BaseName, SHA256（空 = 不校验）, 进度回调。
    DownloadTemporaryFile(
      'https://go.microsoft.com/fwlink/p/?LinkId=2124703',
      'MicrosoftEdgeWebview2Setup.exe', '', nil);
  except
    Result := '下载 WebView2 运行库失败（插件系统需要它显示插件页面）。' + #13#10 +
      '请联网后重试，或先手动安装后再运行本安装包：' + #13#10 +
      'https://developer.microsoft.com/microsoft-edge/webview2/';
    exit;
  end;
  Exec(ExpandConstant('{tmp}\MicrosoftEdgeWebview2Setup.exe'),
    '/install /quiet /norestart', '', SW_SHOW, ewWaitUntilTerminated, resultCode);
  if not WebView2Installed() then begin
    Result := 'WebView2 运行库安装未完成（退出码 ' + IntToStr(resultCode) + '）。' + #13#10 +
      '软件仍可安装，但插件功能需要该运行库；可稍后从以下地址手动安装：' + #13#10 +
      'https://developer.microsoft.com/microsoft-edge/webview2/';
  end;
end;
