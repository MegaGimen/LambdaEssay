#include <windows.h>
#include <tlhelp32.h>
#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <chrono>
#include <algorithm>
#include <io.h>
#include <fcntl.h>

class ProcessWarden {
private:
    std::string monitorProcessName;
    std::vector<std::string> targetProcesses;
    bool verboseMode;
    
public:
    ProcessWarden(bool verbose = false) : monitorProcessName("notalone.exe"), verboseMode(verbose) {
        // 初始化需要清理的进程列表
        targetProcesses = {"record.exe", "censorship.exe", "receiver.exe", "voice.exe"};
        
        if (verboseMode) {
            std::cout << "[DEBUG] ProcessWarden 初始化完成，verbose模式已启用" << std::endl;
            std::cout << "[DEBUG] 监控目标进程: " << monitorProcessName << std::endl;
            std::cout << "[DEBUG] 清理目标进程列表: ";
            for (size_t i = 0; i < targetProcesses.size(); ++i) {
                std::cout << targetProcesses[i];
                if (i < targetProcesses.size() - 1) std::cout << ", ";
            }
            std::cout << std::endl;
        }
    }
    
    // 检查指定进程名是否存在
    bool IsProcessRunning(const std::string& processName) {
        if (verboseMode) {
            std::cout << "[DEBUG] 检查进程是否运行: " << processName << std::endl;
        }
        
        HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (hSnapshot == INVALID_HANDLE_VALUE) {
            if (verboseMode) {
                std::cerr << "[ERROR] 创建进程快照失败，错误代码: " << GetLastError() << std::endl;
            }
            return false;
        }

        PROCESSENTRY32 pe32;
        pe32.dwSize = sizeof(PROCESSENTRY32);

        if (!Process32First(hSnapshot, &pe32)) {
            if (verboseMode) {
                std::cerr << "[ERROR] 获取第一个进程信息失败，错误代码: " << GetLastError() << std::endl;
            }
            CloseHandle(hSnapshot);
            return false;
        }

        do {
            // 将进程名转换为小写进行比较
            std::string currentProcessName = pe32.szExeFile;
            std::transform(currentProcessName.begin(), currentProcessName.end(), 
                         currentProcessName.begin(), ::tolower);
            
            std::string targetName = processName;
            std::transform(targetName.begin(), targetName.end(), 
                         targetName.begin(), ::tolower);
            
            if (currentProcessName == targetName) {
                if (verboseMode) {
                    std::cout << "[DEBUG] 找到目标进程: " << processName << " (PID: " << pe32.th32ProcessID << ")" << std::endl;
                }
                CloseHandle(hSnapshot);
                return true;
            }
        } while (Process32Next(hSnapshot, &pe32));

        if (verboseMode) {
            std::cout << "[DEBUG] 未找到目标进程: " << processName << std::endl;
        }
        
        CloseHandle(hSnapshot);
        return false;
    }
    
    // 使用taskkill杀死指定进程（静默执行，不弹窗）
    void KillProcess(const std::string& processName) {
        std::string command = "taskkill /F /IM " + processName + " >nul 2>&1";
        std::cout << "正在终止进程: " << processName << std::endl;
        
        if (verboseMode) {
            std::cout << "[DEBUG] 执行命令: " << command << std::endl;
        }
        
        // 使用CreateProcess来静默执行命令，避免弹窗
        STARTUPINFOA si;
        PROCESS_INFORMATION pi;
        ZeroMemory(&si, sizeof(si));
        si.cb = sizeof(si);
        si.dwFlags = STARTF_USESHOWWINDOW;
        si.wShowWindow = SW_HIDE; // 隐藏窗口
        ZeroMemory(&pi, sizeof(pi));
        
        // 创建进程执行taskkill命令
        std::string cmdLine = "cmd /c " + command;
        
        if (verboseMode) {
            std::cout << "[DEBUG] 创建进程执行: " << cmdLine << std::endl;
        }
        
        BOOL success = CreateProcessA(
            NULL,                   // 应用程序名称
            (LPSTR)cmdLine.c_str(), // 命令行
            NULL,                   // 进程安全属性
            NULL,                   // 线程安全属性
            FALSE,                  // 继承句柄
            CREATE_NO_WINDOW,       // 创建标志：不创建窗口
            NULL,                   // 环境变量
            NULL,                   // 当前目录
            &si,                    // 启动信息
            &pi                     // 进程信息
        );
        
        if (success) {
            if (verboseMode) {
                std::cout << "[DEBUG] 进程创建成功，等待执行完成..." << std::endl;
            }
            
            // 等待进程完成
            DWORD waitResult = WaitForSingleObject(pi.hProcess, 10000); // 10秒超时
            
            if (waitResult == WAIT_TIMEOUT) {
                if (verboseMode) {
                    std::cerr << "[ERROR] 等待进程完成超时" << std::endl;
                }
                TerminateProcess(pi.hProcess, 1);
            } else if (waitResult == WAIT_FAILED) {
                if (verboseMode) {
                    std::cerr << "[ERROR] 等待进程失败，错误代码: " << GetLastError() << std::endl;
                }
            }
            
            // 获取退出代码
            DWORD exitCode;
            if (GetExitCodeProcess(pi.hProcess, &exitCode)) {
                if (verboseMode) {
                    std::cout << "[DEBUG] 进程退出代码: " << exitCode << std::endl;
                }
                
                if (exitCode == 0) {
                    std::cout << "成功终止进程: " << processName << std::endl;
                } else {
                    std::cout << "终止进程失败或进程不存在: " << processName << std::endl;
                }
            } else {
                if (verboseMode) {
                    std::cerr << "[ERROR] 获取进程退出代码失败，错误代码: " << GetLastError() << std::endl;
                }
                std::cout << "终止进程状态未知: " << processName << std::endl;
            }
            
            // 关闭句柄
            CloseHandle(pi.hProcess);
            CloseHandle(pi.hThread);
        } else {
            DWORD error = GetLastError();
            std::cout << "执行终止命令失败: " << processName << std::endl;
            if (verboseMode) {
                std::cerr << "[ERROR] CreateProcess失败，错误代码: " << error << std::endl;
            }
        }
    }
    
    // 清理所有目标进程
    void CleanupProcesses() {
        std::cout << "开始清理目标进程..." << std::endl;
        
        // 首先尝试终止所有目标进程
        for (const auto& processName : targetProcesses) {
            KillProcess(processName);
        }
        
        // 持续检测直到所有目标进程都被清理干净
        bool allProcessesCleaned = false;
        while (!allProcessesCleaned) {
            allProcessesCleaned = true;
            
            for (const auto& processName : targetProcesses) {
                if (IsProcessRunning(processName)) {
                    allProcessesCleaned = false;
                    std::cout << "进程 " << processName << " 仍在运行，继续清理..." << std::endl;
                    KillProcess(processName);
                    break; // 发现还有进程在运行，跳出内层循环继续检测
                }
            }
            
            if (!allProcessesCleaned) {
                // 短暂等待后再次检测
                std::this_thread::sleep_for(std::chrono::milliseconds(500));
            }
        }
        
        std::cout << "进程清理完成" << std::endl;
    }
    
    // 初始化守护进程
    bool Initialize() {
        // 设置控制台编码为UTF-8以正确显示中文
        SetConsoleOutputCP(CP_UTF8);
        SetConsoleCP(CP_UTF8);
        
        std::cout << "守护进程启动" << std::endl;
        std::cout << "监控目标进程: " << monitorProcessName << std::endl;
        
        // 检查目标进程是否存在
        if (!IsProcessRunning(monitorProcessName)) {
            std::cout << "目标进程 " << monitorProcessName << " 不存在，执行清理操作..." << std::endl;
            CleanupProcesses();
            std::cout << "清理完成，守护进程退出" << std::endl;
            return false; // 返回false表示需要退出
        } else {
            std::cout << "目标进程 " << monitorProcessName << " 正在运行" << std::endl;
            std::cout << "开始监控..." << std::endl;
        }
        
        return true;
    }
    
    // 主监控循环
    void StartMonitoring() {
        const int CHECK_INTERVAL_MS = 1000; // 每秒检查一次
        bool wasRunning = IsProcessRunning(monitorProcessName);
        
        if (verboseMode) {
            std::cout << "[DEBUG] 开始监控循环，检查间隔: " << CHECK_INTERVAL_MS << "ms" << std::endl;
            std::cout << "[DEBUG] 初始状态 - " << monitorProcessName << " 运行状态: " << (wasRunning ? "是" : "否") << std::endl;
        }
        
        int checkCount = 0;
        
        while (true) {
            try {
                bool isRunning = IsProcessRunning(monitorProcessName);
                checkCount++;
                
                if (verboseMode && checkCount % 60 == 0) { // 每分钟输出一次状态
                    std::cout << "[DEBUG] 监控状态检查 #" << checkCount << " - " << monitorProcessName << " 运行状态: " << (isRunning ? "是" : "否") << std::endl;
                }
                
                // 如果进程从运行状态变为不运行状态
                if (wasRunning && !isRunning) {
                    std::cout << "检测到目标进程 " << monitorProcessName << " 已结束" << std::endl;
                    if (verboseMode) {
                        std::cout << "[DEBUG] 进程状态变化：运行 -> 停止，开始清理操作" << std::endl;
                    }
                    CleanupProcesses();
                    std::cout << "守护进程即将退出..." << std::endl;
                    break;
                }
                
                wasRunning = isRunning;
                
                // 等待下次检查
                std::this_thread::sleep_for(std::chrono::milliseconds(CHECK_INTERVAL_MS));
            }
            catch (const std::exception& e) {
                std::cerr << "[ERROR] 监控循环中发生异常: " << e.what() << std::endl;
                if (verboseMode) {
                    std::cerr << "[DEBUG] 异常发生在第 " << checkCount << " 次检查时" << std::endl;
                }
                throw; // 重新抛出异常
            }
            catch (...) {
                std::cerr << "[ERROR] 监控循环中发生未知异常" << std::endl;
                if (verboseMode) {
                    std::cerr << "[DEBUG] 未知异常发生在第 " << checkCount << " 次检查时" << std::endl;
                }
                throw; // 重新抛出异常
            }
        }
        
        if (verboseMode) {
            std::cout << "[DEBUG] 监控循环结束，总共执行了 " << checkCount << " 次检查" << std::endl;
        }
    }
};

int main(int argc, char* argv[]) {
    // 解析命令行参数
    bool verboseMode = false;
    
    try {
        for (int i = 1; i < argc; ++i) {
            std::string arg = argv[i];
            if (arg == "--verbose" || arg == "-v") {
                verboseMode = true;
                std::cout << "[INFO] 启用详细输出模式" << std::endl;
            } else if (arg == "--help" || arg == "-h") {
                std::cout << "Process Warden - 进程守护者" << std::endl;
                std::cout << "用法: warden.exe [选项]" << std::endl;
                std::cout << "选项:" << std::endl;
                std::cout << "  --verbose, -v    启用详细输出模式，显示调试信息" << std::endl;
                std::cout << "  --help, -h       显示此帮助信息" << std::endl;
                return 0;
            } else {
                std::cerr << "未知参数: " << arg << std::endl;
                std::cerr << "使用 --help 查看帮助信息" << std::endl;
                return 1;
            }
        }
        
        // 设置控制台标题
        SetConsoleTitle("Process Warden");
        
        if (verboseMode) {
            std::cout << "[DEBUG] 开始创建ProcessWarden实例" << std::endl;
        }
        
        ProcessWarden warden(verboseMode);
        
        if (verboseMode) {
            std::cout << "[DEBUG] 开始初始化守护进程" << std::endl;
        }
        
        // 初始化守护进程
        if (!warden.Initialize()) {
            // 如果初始化返回false，说明需要退出（已经执行了清理）
            if (verboseMode) {
                std::cout << "[DEBUG] 初始化返回false，程序即将退出" << std::endl;
            }
            return 0;
        }
        
        if (verboseMode) {
            std::cout << "[DEBUG] 初始化成功，开始监控循环" << std::endl;
        }
        
        // 开始监控
        warden.StartMonitoring();
        
        if (verboseMode) {
            std::cout << "[DEBUG] 监控循环正常结束" << std::endl;
        }
    }
    catch (const std::exception& e) {
        std::cerr << "[ERROR] 程序执行过程中发生异常: " << e.what() << std::endl;
        if (verboseMode) {
            std::cerr << "[DEBUG] 异常类型: " << typeid(e).name() << std::endl;
        }
        return -1;
    }
    catch (...) {
        std::cerr << "[ERROR] 程序执行过程中发生未知异常" << std::endl;
        if (verboseMode) {
            std::cerr << "[DEBUG] 捕获到未知类型的异常" << std::endl;
        }
        return -1;
    }
    
    std::cout << "守护进程正常退出" << std::endl;
    return 0;
}