; NSIS 安装脚本
!include "MUI2.nsh"
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

; 默认安装选项
Section "主程序" SecMain
    SetOutPath "$INSTDIR"
    
    ; 复制 Release 文件夹所有内容
    File /r "build\windows\x64\runner\Release\*.*"
    
    ; 复制 bin 文件夹
    SetOutPath "$INSTDIR\bin"
    File /r "bin\*.*"
    
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