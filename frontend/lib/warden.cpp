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
        // Default ports
        monitorPort = 8080;
        terminalPort = 3000;
        
        if (verboseMode) {
            std::cout << "[DEBUG] PortWarden initialized, verbose mode enabled" << std::endl;
            std::cout << "[DEBUG] Monitor port: " << monitorPort << std::endl;
            std::cout << "[DEBUG] Terminal port: " << terminalPort << std::endl;
        }
    }
    
    // Set ports
    void SetPorts(int monitor, int terminal) {
        monitorPort = monitor;
        terminalPort = terminal;
        
        if (verboseMode) {
            std::cout << "[DEBUG] Monitor port set to: " << monitorPort << std::endl;
            std::cout << "[DEBUG] Terminal port set to: " << terminalPort << std::endl;
        }
    }
    
    // Find process ID by port number
    DWORD FindProcessIdByPort(int port) {
        if (verboseMode) {
            std::cout << "[DEBUG] Finding process using port " << port << "..." << std::endl;
        }
        
        SOCKET tempSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (tempSocket == INVALID_SOCKET) {
            if (verboseMode) {
                std::cerr << "[ERROR] Failed to create temporary socket: " << WSAGetLastError() << std::endl;
            }
            return 0;
        }
        
        sockaddr_in service;
        service.sin_family = AF_INET;
        service.sin_addr.s_addr = inet_addr("127.0.0.1");
        service.sin_port = htons(port);
        
        // Try to bind port, if fails then port is occupied
        if (bind(tempSocket, (SOCKADDR*)&service, sizeof(service)) == 0) {
            closesocket(tempSocket);
            if (verboseMode) {
                std::cout << "[DEBUG] Port " << port << " is not occupied" << std::endl;
            }
            return 0;
        }
        
        closesocket(tempSocket);
        
        // Use netstat command to find process using the port
        std::string command = "netstat -ano | findstr :" + std::to_string(port) + " | findstr LISTENING";
        
        if (verboseMode) {
            std::cout << "[DEBUG] Executing command: " << command << std::endl;
        }
        
        FILE* pipe = _popen(command.c_str(), "r");
        if (!pipe) {
            if (verboseMode) {
                std::cerr << "[ERROR] Failed to execute netstat command" << std::endl;
            }
            return 0;
        }
        
        char buffer[128];
        DWORD processId = 0;
        
        while (fgets(buffer, sizeof(buffer), pipe) != NULL) {
            std::string line(buffer);
            if (verboseMode) {
                std::cout << "[DEBUG] netstat output: " << line;
            }
            
            // Parse process ID (last column)
            size_t lastSpace = line.find_last_of(' ');
            if (lastSpace != std::string::npos) {
                std::string pidStr = line.substr(lastSpace + 1);
                pidStr.erase(std::remove(pidStr.begin(), pidStr.end(), '\n'), pidStr.end());
                pidStr.erase(std::remove(pidStr.begin(), pidStr.end(), '\r'), pidStr.end());
                
                try {
                    processId = std::stoul(pidStr);
                    if (processId > 0) {
                        if (verboseMode) {
                            std::cout << "[DEBUG] Found process ID using the port: " << processId << std::endl;
                        }
                        break;
                    }
                } catch (...) {
                    if (verboseMode) {
                        std::cerr << "[ERROR] Failed to parse process ID: " << pidStr << std::endl;
                    }
                }
            }
        }
        
        _pclose(pipe);
        return processId;
    }
    
    // Kill process by process ID
    bool KillProcessByPid(DWORD processId) {
        if (processId == 0) {
            if (verboseMode) {
                std::cout << "[DEBUG] Invalid process ID" << std::endl;
            }
            return false;
        }
        
        std::cout << "Terminating process PID: " << processId << std::endl;
        
        HANDLE hProcess = OpenProcess(PROCESS_TERMINATE, FALSE, processId);
        if (hProcess == NULL) {
            if (verboseMode) {
                std::cerr << "[ERROR] Failed to open process, error code: " << GetLastError() << std::endl;
            }
            return false;
        }
        
        BOOL result = TerminateProcess(hProcess, 0);
        CloseHandle(hProcess);
        
        if (result) {
            std::cout << "Successfully terminated process PID: " << processId << std::endl;
            return true;
        } else {
            if (verboseMode) {
                std::cerr << "[ERROR] Failed to terminate process, error code: " << GetLastError() << std::endl;
            }
            return false;
        }
    }
    
    // Kill process by name
    void KillProcessByName(const std::string& processName) {
        if (verboseMode) {
            std::cout << "[DEBUG] Looking for process to kill: " << processName << std::endl;
        }
        
        HANDLE hSnapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (hSnapshot == INVALID_HANDLE_VALUE) {
            if (verboseMode) {
                std::cerr << "[ERROR] Failed to create snapshot: " << GetLastError() << std::endl;
            }
            return;
        }
        
        PROCESSENTRY32 pe;
        pe.dwSize = sizeof(PROCESSENTRY32);
        
        if (Process32First(hSnapshot, &pe)) {
            do {
                // Simple string comparison
                if (std::string(pe.szExeFile) == processName) {
                    if (verboseMode) {
                        std::cout << "[DEBUG] Found " << processName << " with PID: " << pe.th32ProcessID << std::endl;
                    }
                    KillProcessByPid(pe.th32ProcessID);
                }
            } while (Process32Next(hSnapshot, &pe));
        }
        
        CloseHandle(hSnapshot);
    }

    // Kill process using specified port
    void KillProcessByPort(int port) {
        DWORD processId = FindProcessIdByPort(port);
        if (processId > 0) {
            KillProcessByPid(processId);
        } else {
            std::cout << "No process found using port " << port << std::endl;
        }
    }
    
    // Check if monitor port is reachable
    bool CheckMonitorPort() {
        if (verboseMode) {
            std::cout << "[DEBUG] Checking if monitor port " << monitorPort << " is reachable..." << std::endl;
        }
        
        SOCKET testSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (testSocket == INVALID_SOCKET) {
            if (verboseMode) {
                std::cerr << "[ERROR] Failed to create test socket: " << WSAGetLastError() << std::endl;
            }
            return false;
        }
        
        sockaddr_in service;
        service.sin_family = AF_INET;
        service.sin_addr.s_addr = inet_addr("127.0.0.1");
        service.sin_port = htons(monitorPort);
        
        // Set timeout
        DWORD timeout = 3000; // 3 seconds
        setsockopt(testSocket, SOL_SOCKET, SO_RCVTIMEO, (char*)&timeout, sizeof(timeout));
        setsockopt(testSocket, SOL_SOCKET, SO_SNDTIMEO, (char*)&timeout, sizeof(timeout));
        
        bool result = (connect(testSocket, (SOCKADDR*)&service, sizeof(service)) == 0);
        
        if (verboseMode) {
            std::cout << "[DEBUG] Port connection " << (result ? "successful" : "failed") << std::endl;
        }
        
        closesocket(testSocket);
        return result;
    }
    
    // Start HTTP server
    bool StartHttpServer() {
        if (verboseMode) {
            std::cout << "[DEBUG] Starting HTTP server on port: 3040" << std::endl;
        }
        
        serverSocket = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (serverSocket == INVALID_SOCKET) {
            std::cerr << "[ERROR] Failed to create server socket: " << WSAGetLastError() << std::endl;
            return false;
        }
        
        // Set socket options, allow address reuse
        int optval = 1;
        setsockopt(serverSocket, SOL_SOCKET, SO_REUSEADDR, (char*)&optval, sizeof(optval));
        
        sockaddr_in service;
        service.sin_family = AF_INET;
        service.sin_addr.s_addr = INADDR_ANY;
        service.sin_port = htons(3040);
        
        if (bind(serverSocket, (SOCKADDR*)&service, sizeof(service)) == SOCKET_ERROR) {
            std::cerr << "[ERROR] Failed to bind port: " << WSAGetLastError() << std::endl;
            closesocket(serverSocket);
            return false;
        }
        
        if (listen(serverSocket, 5) == SOCKET_ERROR) {
            std::cerr << "[ERROR] Failed to listen: " << WSAGetLastError() << std::endl;
            closesocket(serverSocket);
            return false;
        }
        
        std::cout << "HTTP server started successfully, listening on port: 3040" << std::endl;
        std::cout << "Waiting for trigger request..." << std::endl;
        
        return true;
    }
    
    // Handle HTTP request
    void HandleHttpRequest(SOCKET clientSocket) {
        char buffer[1024];
        int bytesReceived = recv(clientSocket, buffer, sizeof(buffer) - 1, 0);
        
        if (bytesReceived > 0) {
            buffer[bytesReceived] = '\0';
            
            if (verboseMode) {
                std::cout << "[DEBUG] Received HTTP request:\n" << buffer << std::endl;
            }
            
            // Check if it's a GET request
            if (strstr(buffer, "GET / ") != nullptr) {
                std::cout << "Received trigger request, starting port monitoring..." << std::endl;
                monitoring = true;
                
                // Send success response
                std::string response = 
                    "HTTP/1.1 200 OK\r\n"
                    "Content-Type: text/plain\r\n"
                    "Content-Length: 28\r\n"
                    "Connection: close\r\n"
                    "\r\n"
                    "Monitoring started, checking port";
                
                send(clientSocket, response.c_str(), response.length(), 0);
            } else {
                // Send 404 response
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
    
    // Monitoring loop
    void StartMonitoring() {
        std::cout << "Starting to monitor port " << monitorPort << " ..." << std::endl;
        std::cout << "Check interval: 2 seconds" << std::endl;
        
        int checkCount = 0;
        
        while (monitoring) {
            checkCount++;
            
            if (verboseMode) {
                std::cout << "[DEBUG] Check " << checkCount << " for monitor port..." << std::endl;
            }
            
            if (!CheckMonitorPort()) {
                std::cout << "Monitor port " << monitorPort << " is unreachable, starting cleanup..." << std::endl;
                KillProcessByPort(terminalPort);
                KillProcessByName("COM.exe");
                monitoring = false;
                break;
            } else {
                if (verboseMode) {
                    std::cout << "[DEBUG] Monitor port check passed" << std::endl;
                }
            }
            
            // Wait 2 seconds
            std::this_thread::sleep_for(std::chrono::seconds(2));
        }
        
        std::cout << "Monitoring ended" << std::endl;
    }
    
    // Run main loop
    void Run() {
        if (!StartHttpServer()) {
            std::cerr << "[ERROR] Failed to start HTTP server" << std::endl;
            return;
        }
        
        // Accept connections and handle requests
        while (!monitoring) {
            sockaddr_in clientAddr;
            int clientAddrSize = sizeof(clientAddr);
            
            SOCKET clientSocket = accept(serverSocket, (SOCKADDR*)&clientAddr, &clientAddrSize);
            if (clientSocket == INVALID_SOCKET) {
                if (verboseMode) {
                    std::cerr << "[ERROR] Failed to accept connection: " << WSAGetLastError() << std::endl;
                }
                continue;
            }
            
            // Handle request in new thread
            std::thread([this, clientSocket]() {
                this->HandleHttpRequest(clientSocket);
            }).detach();
        }
        
        // Start monitoring
        StartMonitoring();
    }
    
    // Cleanup resources
    ~PortWarden() {
        if (serverSocket != INVALID_SOCKET) {
            closesocket(serverSocket);
        }
    }
};

int main(int argc, char* argv[]) {
    // Initialize Winsock
    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        std::cerr << "[ERROR] Failed to initialize Winsock: " << WSAGetLastError() << std::endl;
        return 1;
    }
    
    // Parse command line arguments
    bool verboseMode = false;
    int monitorPort = 8080;
    int terminalPort = 3000;
    
    try {
        for (int i = 1; i < argc; ++i) {
            std::string arg = argv[i];
            
            if (arg == "--verbose" || arg == "-v") {
                verboseMode = true;
                std::cout << "[INFO] Verbose mode enabled" << std::endl;
            } else if (arg == "--help" || arg == "-h") {
                std::cout << "Port Warden - Port Monitoring Daemon" << std::endl;
                std::cout << "Usage: warden.exe [options]" << std::endl;
                std::cout << "Options:" << std::endl;
                std::cout << "  --monitor_port <port>  Set monitor port (default: 8080)" << std::endl;
                std::cout << "  --terminal_port <port> Set terminal port (default: 3000)" << std::endl;
                std::cout << "  --verbose, -v          Enable verbose output mode" << std::endl;
                std::cout << "  --help, -h             Show this help message" << std::endl;
                WSACleanup();
                return 0;
            } else if (arg == "--monitor_port" && i + 1 < argc) {
                monitorPort = std::stoi(argv[++i]);
            } else if (arg == "--terminal_port" && i + 1 < argc) {
                terminalPort = std::stoi(argv[++i]);
            } else {
                std::cerr << "Unknown parameter: " << arg << std::endl;
                std::cerr << "Use --help for help information" << std::endl;
                WSACleanup();
                return 1;
            }
        }
        
        // Set console title
        SetConsoleTitle("Port Warden");
        
        if (verboseMode) {
            std::cout << "[DEBUG] Creating PortWarden instance" << std::endl;
        }
        
        PortWarden warden(verboseMode);
        warden.SetPorts(monitorPort, terminalPort);
        
        std::cout << "Port Warden started successfully" << std::endl;
        std::cout << "Monitor port: " << monitorPort << std::endl;
        std::cout << "Terminal port: " << terminalPort << std::endl;
        std::cout << "HTTP server port: 3040" << std::endl;
        std::cout << "Send GET http://localhost:3040/ to start monitoring" << std::endl;
        
        // Run main loop
        warden.Run();
        
    } catch (const std::exception& e) {
        std::cerr << "[ERROR] Exception during program execution: " << e.what() << std::endl;
        WSACleanup();
        return -1;
    } catch (...) {
        std::cerr << "[ERROR] Unknown exception during program execution" << std::endl;
        WSACleanup();
        return -1;
    }
    
    WSACleanup();
    std::cout << "Program exited normally" << std::endl;
    return 0;
}