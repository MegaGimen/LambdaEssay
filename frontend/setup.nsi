; NSIS 安装脚本
!include "MUI2.nsh"
!include "LogicLib.nsh"
Icon "windows/runner/resources/app_icon.ico"
UninstallIcon  "windows/runner/resources/app_icon.ico"

; 基本设置
!define APP_NAME "LambdaEssay"
!define APP_VERSION "1.0"
!define APP_PUBLISHER "LambdaLinker"
!define APP_CONTACT "megagimen@gmail.com"
!define EXE_NAME "LambdaEssay.exe"

; 压缩设置
SetCompressor /SOLID lzma
SetCompressorDictSize 32

; 名称
Name "${APP_NAME} ${APP_VERSION}"
OutFile "build\nsis\LambdaEssay.exe"
InstallDir "$PROGRAMFILES64\${APP_NAME}"

; 请求管理员权限
RequestExecutionLevel admin

; 引入现代界面
!define MUI_ABORTWARNING

; 安装向导页面
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_LICENSE "../LICENSE"  ; 如果有许可文件
!insertmacro MUI_PAGE_DIRECTORY
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

; 卸载向导页面
!insertmacro MUI_UNPAGE_CONFIRM
!insertmacro MUI_UNPAGE_INSTFILES

; 设置语言
!insertmacro MUI_LANGUAGE "SimpChinese"

; VC++ 运行库检测与安装
Section "VC++ 运行库" SecVCRedist
    SectionIn RO
    
    ; 初始化检测结果变量
    StrCpy $0 0
    
    ; 检测 VC++ 2015-2022 x64 运行库
    ReadRegDWORD $0 HKLM "SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64" "Installed"
    
    ${If} $0 != 1
        DetailPrint "未检测到 VC++ 运行库，准备下载..."
        
        ; 下载 VC_redist.x64.exe
        NSISdl::download "https://download.visualstudio.microsoft.com/download/pr/6f02464a-5e9b-486d-a506-c99a17db9a83/8995548DFFFCDE7C49987029C764355612BA6850EE09A7B6F0FDDC85BDC5C280/VC_redist.x64.exe" "$TEMP\VC_redist.x64.exe"
        
        Pop $0
        ${If} $0 == "success"
            DetailPrint "下载成功，正在安装 VC++ 运行库..."
            ExecWait '"$TEMP\VC_redist.x64.exe" /install /quiet /norestart'
            Delete "$TEMP\VC_redist.x64.exe"
            DetailPrint "VC++ 运行库安装完成"
        ${Else}
            MessageBox MB_OK|MB_ICONEXCLAMATION "VC++ 运行库下载失败: $0。程序可能无法正常运行，请手动安装 VC++ Redistributable。"
        ${EndIf}
    ${Else}
        DetailPrint "已检测到 VC++ 运行库。"
    ${EndIf}
SectionEnd

; 默认安装选项
Section "主程序" SecMain
    SetOutPath "$INSTDIR"
    
    ; 复制 Release 文件夹所有内容
    File /r "build\windows\x64\runner\Release\*.*"
    
    ; 创建卸载程序
    WriteUninstaller "$INSTDIR\Uninstall.exe"
    
    ; 写入注册表信息
    WriteRegStr HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
        "DisplayName" "${APP_NAME}"
    WriteRegStr HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
        "DisplayVersion" "${APP_VERSION}"
    WriteRegStr HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
        "Publisher" "${APP_PUBLISHER}"
    WriteRegStr HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
        "Contact" "${APP_CONTACT}"
    WriteRegStr HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
        "UninstallString" '"$INSTDIR\Uninstall.exe"'
    WriteRegStr HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
        "InstallLocation" "$INSTDIR"
    WriteRegDWORD HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
        "NoModify" 1
    WriteRegDWORD HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}" \
        "NoRepair" 1
    
SectionEnd

; 创建快捷方式
Section "快捷方式" SecShortcuts
    ; 开始菜单快捷方式
    CreateDirectory "$SMPROGRAMS\${APP_NAME}"
    CreateShortcut "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk" "$INSTDIR\${EXE_NAME}"
    CreateShortcut "$SMPROGRAMS\${APP_NAME}\卸载.lnk" "$INSTDIR\Uninstall.exe"
    
    ; 桌面快捷方式
    CreateShortcut "$DESKTOP\${APP_NAME}.lnk" "$INSTDIR\${EXE_NAME}"
SectionEnd

; 卸载程序
Section "Uninstall"
    ; 删除程序文件
    RMDir /r "$INSTDIR"
    
    ; 删除快捷方式
    Delete "$SMPROGRAMS\${APP_NAME}\${APP_NAME}.lnk"
    Delete "$SMPROGRAMS\${APP_NAME}\卸载.lnk"
    RMDir "$SMPROGRAMS\${APP_NAME}"
    Delete "$DESKTOP\${APP_NAME}.lnk"
    
    ; 删除注册表
    DeleteRegKey HKLM "SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\${APP_NAME}"
    
SectionEnd