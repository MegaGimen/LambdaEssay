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
#include <winsock2.h>
#include <ws2tcpip.h>

#pragma comment(lib, "ws2_32.lib")

class PortWarden {
private:
    int monitorPort;
    int terminalPort;
    bool verboseMode;
    bool monitoring;
    SOCKET serverSocket;
    
public:
    PortWarden(bool verbose = false) : verboseMode(verbose), monitoring(false), serverSocket(INVALID_SOCKET) {
        // 默认端口
        monitorPort = 8080;
        terminalPort = 3000;
        
        if (verboseMode) {
            std::cout << "[DEBUG] PortWarden 初始化完成，verbose模式已启用" << std::endl;
            std::cout << "[DEBUG] 监控端口: " << monitorPort << std::endl;
            std::cout << "[DEBUG] 终止端口: " << terminalPort << std::endl;
        }
    }
    
    // 设置端口
    void SetPorts(int monitor, int terminal) {
        monitorPort = monitor;
        terminalPort = terminal;
        
        if (verboseMode) {
            std::cout << "[DEBUG] 设置监控端口: " << monitorPort << std::endl;
            std::cout << "[DEBUG] 设置终止端口: " << terminalPort << std::endl;
        }
    }
    
    // 根据端口号查找进程ID
    DWORD FindProcessIdByPort(int port) {
        if (verboseMode) {
            std::cout << "[DEBUG] 查找占用端口 " << port << " 的进程..." << std::endl;
        }
        
        SOCKET tempSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (tempSocket == INVALID_SOCKET) {
            if (verboseMode) {
                std::cerr << "[ERROR] 创建临时socket失败: " << WSAGetLastError() << std::endl;
            }
            return 0;
        }
        
        sockaddr_in service;
        service.sin_family = AF_INET;
        service.sin_addr.s_addr = inet_addr("127.0.0.1");
        service.sin_port = htons(port);
        
        // 尝试绑定端口，如果失败说明端口被占用
        if (bind(tempSocket, (SOCKADDR*)&service, sizeof(service)) == 0) {
            closesocket(tempSocket);
            if (verboseMode) {
                std::cout << "[DEBUG] 端口 " << port << " 未被占用" << std::endl;
            }
            return 0;
        }
        
        closesocket(tempSocket);
        
        // 使用netstat命令查找占用端口的进程
        std::string command = "netstat -ano | findstr :" + std::to_string(port) + " | findstr LISTENING";
        
        if (verboseMode) {
            std::cout << "[DEBUG] 执行命令: " << command << std::endl;
        }
        
        FILE* pipe = _popen(command.c_str(), "r");
        if (!pipe) {
            if (verboseMode) {
                std::cerr << "[ERROR] 执行netstat命令失败" << std::endl;
            }
            return 0;
        }
        
        char buffer[128];
        DWORD processId = 0;
        
        while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
            std::string line(buffer);
            if (verboseMode) {
                std::cout << "[DEBUG] netstat输出: " << line;
            }
            
            // 解析进程ID（最后一列）
            size_t lastSpace = line.find_last_of(' ');
            if (lastSpace != std::string::npos) {
                std::string pidStr = line.substr(lastSpace + 1);
                pidStr.erase(std::remove(pidStr.begin(), pidStr.end(), '\n'), pidStr.end());
                pidStr.erase(std::remove(pidStr.begin(), pidStr.end(), '\r'), pidStr.end());
                
                try {
                    processId = std::stoul(pidStr);
                    if (processId > 0) {
                        if (verboseMode) {
                            std::cout << "[DEBUG] 找到占用端口的进程ID: " << processId << std::endl;
                        }
                        break;
                    }
                } catch (...) {
                    if (verboseMode) {
                        std::cerr << "[ERROR] 解析进程ID失败: " << pidStr << std::endl;
                    }
                }
            }
        }
        
        _pclose(pipe);
        return processId;
    }
    
    // 根据进程ID杀死进程
    bool KillProcessByPid(DWORD processId) {
        if (processId == 0) {
            if (verboseMode) {
                std::cout << "[DEBUG] 无效的进程ID" << std::endl;
            }
            return false;
        }
        
        std::cout << "正在终止进程 PID: " << processId << std::endl;
        
        HANDLE hProcess = OpenProcess(PROCESS_TERMINATE, FALSE, processId);
        if (hProcess == NULL) {
            if (verboseMode) {
                std::cerr << "[ERROR] 打开进程失败，错误代码: " << GetLastError() << std::endl;
            }
            return false;
        }
        
        BOOL result = TerminateProcess(hProcess, 0);
        CloseHandle(hProcess);
        
        if (result) {
            std::cout << "成功终止进程 PID: " << processId << std::endl;
            return true;
        } else {
            if (verboseMode) {
                std::cerr << "[ERROR] 终止进程失败，错误代码: " << GetLastError() << std::endl;
            }
            return false;
        }
    }
    
    // 杀死占用指定端口的进程
    void KillProcessByPort(int port) {
        DWORD processId = FindProcessIdByPort(port);
        if (processId > 0) {
            KillProcessByPid(processId);
        } else {
            std::cout << "未找到占用端口 " << port << " 的进程" << std::endl;
        }
    }
    
    // 检查监控端口是否可达
    bool CheckMonitorPort() {
        if (verboseMode) {
            std::cout << "[DEBUG] 检查监控端口 " << monitorPort << " 是否可达..." << std::endl;
        }
        
        SOCKET testSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (testSocket == INVALID_SOCKET) {
            if (verboseMode) {
                std::cerr << "[ERROR] 创建测试socket失败: " << WSAGetLastError() << std::endl;
            }
            return false;
        }
        
        sockaddr_in service;
        service.sin_family = AF_INET;
        service.sin_addr.s_addr = inet_addr("127.0.0.1");
        service.sin_port = htons(monitorPort);
        
        // 设置超时
        DWORD timeout = 3000; // 3秒
        setsockopt(testSocket, SOL_SOCKET, SO_RCVTIMEO, (char*)&timeout, sizeof(timeout));
        setsockopt(testSocket, SOL_SOCKET, SO_SNDTIMEO, (char*)&timeout, sizeof(timeout));
        
        bool result = (connect(testSocket, (SOCKADDR*)&service, sizeof(service)) == 0);
        
        if (verboseMode) {
            std::cout << "[DEBUG] 端口连接" << (result ? "成功" : "失败") << std::endl;
        }
        
        closesocket(testSocket);
        return result;
    }
    
    // 启动HTTP服务器
    bool StartHttpServer() {
        if (verboseMode) {
            std::cout << "[DEBUG] 启动HTTP服务器，端口: 3040" << std::endl;
        }
        
        serverSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (serverSocket == INVALID_SOCKET) {
            std::cerr << "[ERROR] 创建服务器socket失败: " << WSAGetLastError() << std::endl;
            return false;
        }
        
        // 设置socket选项，允许地址重用
        int optval = 1;
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, (char*)&optval, sizeof(optval));
        
        sockaddr_in service;
        service.sin_family = AF_INET;
        service.sin_addr.s_addr = INADDR_ANY;
        service.sin_port = htons(3040);
        
        if (bind(serverSocket, (SOCKADDR*)&service, sizeof(service)) == SOCKET_ERROR) {
            std::cerr << "[ERROR] 绑定端口失败: " << WSAGetLastError() << std::endl;
            closesocket(serverSocket);
            return false;
        }
        
        if (listen(serverSocket, 5) == SOCKET_ERROR) {
            std::cerr << "[ERROR] 监听失败: " << WSAGetLastError() << std::endl;
            closesocket(serverSocket);
            return false;
        }
        
        std::cout << "HTTP服务器启动成功，监听端口: 3040" << std::endl;
        std::cout << "等待触发请求..." << std::endl;
        
        return true;
    }
    
    // 处理HTTP请求
    void HandleHttpRequest(SOCKET clientSocket) {
        char buffer[1024];
        int bytesReceived = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
        
        if (bytesReceived > 0) {
            buffer[bytesReceived] = '\0';
            
            if (verboseMode) {
                std::cout << "[DEBUG] 收到HTTP请求:\n" << buffer << std::endl;
            }
            
            // 检查是否是GET请求
            if (strstr(buffer, "GET / ") != nullptr) {
                std::cout << "收到触发请求，开始监控端口..." << std::endl;
                monitoring = true;
                
                // 发送成功响应
                std::string response = 
                    "HTTP/1.1 200 OK\r\n"
                    "Content-Type: text/plain\r\n"
                    "Content-Length: 28\r\n"
                    "Connection: close\r\n"
                    "\r\n"
                    "监控已启动，开始检查端口";
                
                send(clientSocket, response.c_str(), response.length(), 0);
            } else {
                // 发送404响应
                std::string response = 
                    "HTTP/1.1 404 Not Found\r\n"
                    "Content-Type: text/plain\r\n"
                    "Content-Length: 13\r\n"
                    "Connection: close\r\n"
                    "\r\n"
                    "404 Not Found";
                
                send(clientSocket, response.c_str(), response.length(), 0);
            }
        }
        
        closesocket(clientSocket);
    }
    
    // 监控循环
    void StartMonitoring() {
        std::cout << "开始监控端口 " << monitorPort << " ..." << std::endl;
        std::cout << "检查间隔: 2秒" << std::endl;
        
        int checkCount = 0;
        
        while (monitoring) {
            checkCount++;
            
            if (verboseMode) {
                std::cout << "[DEBUG] 第 " << checkCount << " 次检查监控端口..." << std::endl;
            }
            
            if (!CheckMonitorPort()) {
                std::cout << "监控端口 " << monitorPort << " 不可达，开始清理..." << std::endl;
                KillProcessByPort(terminalPort);
                monitoring = false;
                break;
            } else {
                if (verboseMode) {
                    std::cout << "[DEBUG] 监控端口检查通过" << std::endl;
                }
            }
            
            // 等待2秒
            std::this_thread::sleep_for(std::chrono::seconds(2));
        }
        
        std::cout << "监控结束" << std::endl;
    }
    
    // 运行主循环
    void Run() {
        if (!StartHttpServer()) {
            std::cerr << "[ERROR] 无法启动HTTP服务器" << std::endl;
            return;
        }
        
        // 接受连接和处理请求
        while (!monitoring) {
            sockaddr_in clientAddr;
            int clientAddrSize = sizeof(clientAddr);
            
            SOCKET clientSocket = accept(serverSocket, (SOCKADDR*)&clientAddr, &clientAddrSize);
            if (clientSocket == INVALID_SOCKET) {
                if (verboseMode) {
                    std::cerr << "[ERROR] 接受连接失败: " << WSAGetLastError() << std::endl;
                }
                continue;
            }
            
            // 在新线程中处理请求
            std::thread([this, clientSocket]() {
                this->HandleHttpRequest(clientSocket);
            }).detach();
        }
        
        // 开始监控
        StartMonitoring();
    }
    
    // 清理资源
    ~PortWarden() {
        if (serverSocket != INVALID_SOCKET) {
            closesocket(serverSocket);
        }
    }
};

int main(int argc, char* argv[]) {
    // 初始化Winsock
    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        std::cerr << "[ERROR] 初始化Winsock失败: " << WSAGetLastError() << std::endl;
        return 1;
    }
    
    // 解析命令行参数
    bool verboseMode = false;
    int monitorPort = 8080;
    int terminalPort = 3000;
    
    try {
        for (int i = 1; i < argc; ++i) {
            std::string arg = argv[i];
            
            if (arg == "--verbose" || arg == "-v") {
                verboseMode = true;
                std::cout << "[INFO] 启用详细输出模式" << std::endl;
            } else if (arg == "--help" || arg == "-h") {
                std::cout << "Port Warden - 端口监控守护者" << std::endl;
                std::cout << "用法: warden.exe [选项]" << std::endl;
                std::cout << "选项:" << std::endl;
                std::cout << "  --monitor_port <端口>  设置监控端口（默认: 8080）" << std::endl;
                std::cout << "  --terminal_port <端口> 设置终止端口（默认: 3000）" << std::endl;
                std::cout << "  --verbose, -v          启用详细输出模式" << std::endl;
                std::cout << "  --help, -h             显示此帮助信息" << std::endl;
                WSACleanup();
                return 0;
            } else if (arg == "--monitor_port" && i + 1 < argc) {
                monitorPort = std::stoi(argv[++i]);
            } else if (arg == "--terminal_port" && i + 1 < argc) {
                terminalPort = std::stoi(argv[++i]);
            } else {
                std::cerr << "未知参数: " << arg << std::endl;
                std::cerr << "使用 --help 查看帮助信息" << std::endl;
                WSACleanup();
                return 1;
            }
        }
        
        // 设置控制台标题
        SetConsoleTitle("Port Warden");
        
        if (verboseMode) {
            std::cout << "[DEBUG] 开始创建PortWarden实例" << std::endl;
        }
        
        PortWarden warden(verboseMode);
        warden.SetPorts(monitorPort, terminalPort);
        
        std::cout << "Port Warden 启动成功" << std::endl;
        std::cout << "监控端口: " << monitorPort << std::endl;
        std::cout << "终止端口: " << terminalPort << std::endl;
        std::cout << "HTTP服务器端口: 3040" << std::endl;
        std::cout << "发送 GET http://localhost:3040/ 来开始监控" << std::endl;
        
        // 运行主循环
        warden.Run();
        
    } catch (const std::exception& e) {
        std::cerr << "[ERROR] 程序执行过程中发生异常: " << e.what() << std::endl;
        WSACleanup();
        return -1;
    } catch (...) {
        std::cerr << "[ERROR] 程序执行过程中发生未知异常" << std::endl;
        WSACleanup();
        return -1;
    }
    
    WSACleanup();
    std::cout << "程序正常退出" << std::endl;
    return 0;
}