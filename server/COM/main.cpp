#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <winhttp.h>
#include <ole2.h>
#include <wincrypt.h>
#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <map>
#include <queue>
#include <mutex>
#include <atomic>
#include <fstream>
#include <functional>
#include <algorithm>

using namespace std;

// --- Logger ---
void Log(const string& msg) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    printf("[%02d:%02d:%02d] %s\n", st.wHour, st.wMinute, st.wSecond, msg.c_str());
}

// --- Minimal JSON Parser ---
enum JsonType { J_NULL, J_STRING, J_NUMBER, J_BOOL, J_OBJECT, J_ARRAY };

struct JsonValue {
    JsonType type = J_NULL;
    string s_val;
    double n_val = 0;
    bool b_val = false;
    map<string, JsonValue> o_val;
    vector<JsonValue> a_val;
};

class JsonParser {
    const char* p;
public:
    JsonValue parse(const string& json) {
        p = json.c_str();
        skipSpace();
        return parseValue();
    }

private:
    void skipSpace() { while (*p && isspace((unsigned char)*p)) p++; }
    
    JsonValue parseValue() {
        skipSpace();
        JsonValue v;
        if (*p == '"') v = parseString();
        else if (*p == '{') v = parseObject();
        else if (*p == '[') v = parseArray();
        else if (isdigit((unsigned char)*p) || *p == '-') v = parseNumber();
        else if (strncmp(p, "true", 4) == 0) { v.type = J_BOOL; v.b_val = true; p += 4; }
        else if (strncmp(p, "false", 5) == 0) { v.type = J_BOOL; v.b_val = false; p += 5; }
        else if (strncmp(p, "null", 4) == 0) { v.type = J_NULL; p += 4; }
        else { p++; } 
        return v;
    }

    JsonValue parseString() {
        JsonValue v;
        v.type = J_STRING;
        p++; // skip "
        string res;
        while (*p && *p != '"') {
            if (*p == '\\') {
                p++;
                if (*p == '"') res += '"';
                else if (*p == '\\') res += '\\';
                else if (*p == '/') res += '/';
                else if (*p == 'b') res += '\b';
                else if (*p == 'f') res += '\f';
                else if (*p == 'n') res += '\n';
                else if (*p == 'r') res += '\r';
                else if (*p == 't') res += '\t';
                else if (*p == 'u') { p+=4; } 
                else res += *p;
            } else {
                res += *p;
            }
            p++;
        }
        if (*p == '"') p++;
        v.s_val = res;
        return v;
    }

    JsonValue parseNumber() {
        JsonValue v;
        v.type = J_NUMBER;
        char* end;
        v.n_val = strtod(p, &end);
        p = end;
        return v;
    }

    JsonValue parseObject() {
        JsonValue v;
        v.type = J_OBJECT;
        p++; 
        skipSpace();
        while (*p && *p != '}') {
            JsonValue key = parseString();
            skipSpace();
            if (*p == ':') p++;
            skipSpace();
            v.o_val[key.s_val] = parseValue();
            skipSpace();
            if (*p == ',') p++;
            skipSpace();
        }
        if (*p == '}') p++;
        return v;
    }

    JsonValue parseArray() {
        JsonValue v;
        v.type = J_ARRAY;
        p++; 
        skipSpace();
        while (*p && *p != ']') {
            v.a_val.push_back(parseValue());
            skipSpace();
            if (*p == ',') p++;
            skipSpace();
        }
        if (*p == ']') p++;
        return v;
    }
};

string escapeJson(const string& s) {
    string res = "";
    for (char c : s) {
        if (c == '"') res += "\\\"";
        else if (c == '\\') res += "\\\\";
        else if (c == '\n') res += "\\n";
        else if (c == '\r') res += "\\r";
        else if (c == '\t') res += "\\t";
        else res += c;
    }
    return res;
}

// --- COM Helper ---
HRESULT AutoWrap(int autoType, VARIANT *pvResult, IDispatch *pDisp, LPOLESTR ptName, int cArgs...) {
    if (!pDisp) return E_FAIL;
    va_list marker;
    va_start(marker, cArgs);
    DISPPARAMS dp = { NULL, NULL, 0, 0 };
    DISPID dispidNamed = DISPID_PROPERTYPUT;
    DISPID dispID;
    char szName[200];
    WideCharToMultiByte(CP_ACP, 0, ptName, -1, szName, 200, NULL, NULL);
    HRESULT hr = pDisp->GetIDsOfNames(IID_NULL, &ptName, 1, LOCALE_USER_DEFAULT, &dispID);
    if (FAILED(hr)) {
        return hr;
    }
    VARIANT *pArgs = new VARIANT[cArgs + 1];
    for (int i = 0; i < cArgs; i++) {
        pArgs[i] = va_arg(marker, VARIANT);
    }
    dp.cArgs = cArgs;
    dp.rgvarg = pArgs;
    if (autoType & DISPATCH_PROPERTYPUT) {
        dp.cNamedArgs = 1;
        dp.rgdispidNamedArgs = &dispidNamed;
    }
    hr = pDisp->Invoke(dispID, IID_NULL, LOCALE_SYSTEM_DEFAULT, autoType, &dp, pvResult, NULL, NULL);
    delete[] pArgs;
    va_end(marker);
    return hr;
}

// --- Word Automation ---
class WordAutomation {
    IDispatch* pWordApp = NULL;
    bool lastSavedState = true; 
    bool initialized = false;

public:
    std::function<void(string)> onSaveCallback;

    WordAutomation() {
        CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    }

    ~WordAutomation() {
        if (pWordApp) pWordApp->Release();
        CoUninitialize();
    }

    bool Connect() {
        if (initialized) return true;
        CLSID clsid;
        HRESULT hr = CLSIDFromProgID(L"Word.Application", &clsid);
        if (FAILED(hr)) return false;

        IUnknown *pUnk = NULL;
        hr = GetActiveObject(clsid, NULL, &pUnk);
        if (FAILED(hr)) return false;

        hr = pUnk->QueryInterface(IID_IDispatch, (void **)&pWordApp);
        pUnk->Release();
        if (FAILED(hr)) return false;

        Log("Connected to Word Application");
        initialized = true;
        CheckSavedState(); 
        return true;
    }

    bool IsConnected() {
        if (!initialized) return false;
        VARIANT result;
        VariantInit(&result);
        HRESULT hr = AutoWrap(DISPATCH_PROPERTYGET, &result, pWordApp, (LPOLESTR)L"Version", 0);
        if (FAILED(hr)) {
            Log("Word disconnected");
            pWordApp->Release();
            pWordApp = NULL;
            initialized = false;
            return false;
        }
        return true;
    }

    void CheckSavedState() {
        if (!IsConnected()) return;

        VARIANT result;
        VariantInit(&result);
        HRESULT hr = AutoWrap(DISPATCH_PROPERTYGET, &result, pWordApp, (LPOLESTR)L"ActiveDocument", 0);
        if (FAILED(hr) || result.vt != VT_DISPATCH) return;
        IDispatch* pDoc = result.pdispVal;

        VARIANT vSaved;
        VariantInit(&vSaved);
        hr = AutoWrap(DISPATCH_PROPERTYGET, &vSaved, pDoc, (LPOLESTR)L"Saved", 0);
        
        if (SUCCEEDED(hr)) {
            bool currentSaved = (vSaved.boolVal != 0); 
            if (lastSavedState == false && currentSaved == true) {
                Log("Detected Save Event!");
                OnSaved(pDoc);
            }
            lastSavedState = currentSaved;
        }
        pDoc->Release();
    }

    void OnSaved(IDispatch* pDoc) {
        if (onSaveCallback) {
             VARIANT vPath;
             VariantInit(&vPath); 
             HRESULT hr = AutoWrap(DISPATCH_PROPERTYGET, &vPath, pDoc, (LPOLESTR)L"FullName", 0);
             if (SUCCEEDED(hr) && vPath.vt == VT_BSTR) {
                 char buf[2048];
                 WideCharToMultiByte(CP_UTF8, 0, vPath.bstrVal, -1, buf, 2048, NULL, NULL);
                 onSaveCallback(string(buf));
             }
        }
    }

    bool CheckPath(const string& targetPath) {
        if (!IsConnected()) return false;
        VARIANT result;
        VariantInit(&result);
        HRESULT hr = AutoWrap(DISPATCH_PROPERTYGET, &result, pWordApp, (LPOLESTR)L"ActiveDocument", 0);
        if (FAILED(hr) || result.vt != VT_DISPATCH) return false;
        IDispatch* pDoc = result.pdispVal;
        
        VARIANT vPath;
        VariantInit(&vPath);
        hr = AutoWrap(DISPATCH_PROPERTYGET, &vPath, pDoc, (LPOLESTR)L"FullName", 0);
        pDoc->Release();

        if (FAILED(hr) || vPath.vt != VT_BSTR) return false;

        char currentPath[MAX_PATH];
        WideCharToMultiByte(CP_UTF8, 0, vPath.bstrVal, -1, currentPath, MAX_PATH, NULL, NULL);

        string s1 = currentPath;
        string s2 = targetPath;
        
        // Normalize: Lowercase and backslashes
        transform(s1.begin(), s1.end(), s1.begin(), ::tolower);
        transform(s2.begin(), s2.end(), s2.begin(), ::tolower);
        replace(s1.begin(), s1.end(), '/', '\\');
        replace(s2.begin(), s2.end(), '/', '\\');

        // Simple check: does s1 end with s2? or exact match?
        // Usually exact match for FullName
        if (s1 != s2) {
             Log("Path Mismatch. Current: " + s1 + ", Target: " + s2);
             return false;
        }
        return true;
    }

    bool SaveDocument() {
        if (!IsConnected()) return false;
        VARIANT result;
        VariantInit(&result);
        HRESULT hr = AutoWrap(DISPATCH_PROPERTYGET, &result, pWordApp, (LPOLESTR)L"ActiveDocument", 0);
        if (FAILED(hr) || result.vt != VT_DISPATCH) return false;
        IDispatch* pDoc = result.pdispVal;

        hr = AutoWrap(DISPATCH_METHOD, NULL, pDoc, (LPOLESTR)L"Save", 0);
        pDoc->Release();
        return SUCCEEDED(hr);
    }

    bool ReplaceDocument(const string& content, const string& type) {
        if (!IsConnected()) return false;
        
        char tempPath[MAX_PATH];
        GetTempPathA(MAX_PATH, tempPath);
        string tempFile = string(tempPath) + "word_plugin_temp";
        
        if (type == "html") tempFile += ".html";
        else if (type == "base64") tempFile += ".docx"; 
        else tempFile += ".txt";

        if (type == "base64") {
            DWORD dwSkip, dwFlags, dwBinaryLen;
            if (!CryptStringToBinaryA(content.c_str(), content.length(), CRYPT_STRING_BASE64, NULL, &dwBinaryLen, &dwSkip, &dwFlags)) {
                 Log("Base64 decode size failed");
                 return false;
            }
            vector<BYTE> buffer(dwBinaryLen);
            if (!CryptStringToBinaryA(content.c_str(), content.length(), CRYPT_STRING_BASE64, buffer.data(), &dwBinaryLen, &dwSkip, &dwFlags)) {
                 Log("Base64 decode failed");
                 return false;
            }
            ofstream ofs(tempFile, ios::binary);
            ofs.write((char*)buffer.data(), buffer.size());
            ofs.close();
        } else {
            ofstream ofs(tempFile);
            ofs << content;
            ofs.close();
        }

        VARIANT result;
        VariantInit(&result);
        HRESULT hr = AutoWrap(DISPATCH_PROPERTYGET, &result, pWordApp, (LPOLESTR)L"ActiveDocument", 0);
        if (FAILED(hr) || result.vt != VT_DISPATCH) return false;
        IDispatch* pDoc = result.pdispVal;

        VARIANT vContent;
        VariantInit(&vContent);
        hr = AutoWrap(DISPATCH_PROPERTYGET, &vContent, pDoc, (LPOLESTR)L"Content", 0);
        if (FAILED(hr) || vContent.vt != VT_DISPATCH) {
            pDoc->Release();
            return false;
        }
        IDispatch* pRange = vContent.pdispVal;

        // 1. Turn off TrackRevisions FIRST to ensure Delete works directly
        VARIANT vFalse;
        vFalse.vt = VT_BOOL;
        vFalse.boolVal = VARIANT_FALSE;
        AutoWrap(DISPATCH_PROPERTYPUT, NULL, pDoc, (LPOLESTR)L"TrackRevisions", 1, vFalse);

        // 2. Accept all prior revisions
        AutoWrap(DISPATCH_METHOD, NULL, pDoc, (LPOLESTR)L"AcceptAllRevisions", 0);

        // 3. Clear Document (Delete all content)
        AutoWrap(DISPATCH_METHOD, NULL, pRange, (LPOLESTR)L"Delete", 0);

        VARIANT vFileName;
        vFileName.vt = VT_BSTR;
        int wlen = MultiByteToWideChar(CP_ACP, 0, tempFile.c_str(), -1, NULL, 0);
        BSTR bstrFile = SysAllocStringLen(NULL, wlen);
        MultiByteToWideChar(CP_ACP, 0, tempFile.c_str(), -1, bstrFile, wlen);
        vFileName.bstrVal = bstrFile;

        // Replace content (InsertFile)
        hr = AutoWrap(DISPATCH_METHOD, NULL, pRange, (LPOLESTR)L"InsertFile", 1, vFileName);
        
        // Finalize: Ensure TrackRevisions is still OFF
        AutoWrap(DISPATCH_PROPERTYPUT, NULL, pDoc, (LPOLESTR)L"TrackRevisions", 1, vFalse);

        SysFreeString(bstrFile);
        pRange->Release();
        pDoc->Release();

        return SUCCEEDED(hr);
    }
};

// --- WebSocket Client ---
class WebSocketClient {
    HINTERNET hSession = NULL;
    HINTERNET hConnect = NULL;
    HINTERNET hRequest = NULL;
    HINTERNET hWebSocket = NULL;
    bool connected = false;

public:
    ~WebSocketClient() {
        Close();
    }

    void Close() {
        if (hWebSocket) WinHttpCloseHandle(hWebSocket);
        if (hRequest) WinHttpCloseHandle(hRequest);
        if (hConnect) WinHttpCloseHandle(hConnect);
        if (hSession) WinHttpCloseHandle(hSession);
        hWebSocket = NULL;
        hRequest = NULL;
        hConnect = NULL;
        hSession = NULL;
        connected = false;
    }

    bool Connect(const wstring& host, int port, const wstring& path) {
        hSession = WinHttpOpen(L"WordCOM/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY, WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
        if (!hSession) return false;

        hConnect = WinHttpConnect(hSession, host.c_str(), port, 0);
        if (!hConnect) return false;

        hRequest = WinHttpOpenRequest(hConnect, L"GET", path.c_str(), NULL, WINHTTP_NO_REFERER, WINHTTP_DEFAULT_ACCEPT_TYPES, 0);
        if (!hRequest) return false;

        if (!WinHttpSetOption(hRequest, WINHTTP_OPTION_UPGRADE_TO_WEB_SOCKET, NULL, 0)) return false;

        if (!WinHttpSendRequest(hRequest, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0)) return false;

        if (!WinHttpReceiveResponse(hRequest, NULL)) return false;

        hWebSocket = WinHttpWebSocketCompleteUpgrade(hRequest, (DWORD_PTR)NULL);
        if (!hWebSocket) return false;

        WinHttpCloseHandle(hRequest);
        hRequest = NULL;
        connected = true;
        Log("WebSocket Connected");
        return true;
    }

    bool Send(const string& msg) {
        if (!connected) return false;
        DWORD ret = WinHttpWebSocketSend(hWebSocket, WINHTTP_WEB_SOCKET_UTF8_MESSAGE_BUFFER_TYPE, (PVOID)msg.c_str(), msg.length());
        return ret == ERROR_SUCCESS;
    }

    bool Receive(string& outMsg) {
        if (!connected) return false;
        
        char buffer[4096];
        DWORD bytesRead = 0;
        WINHTTP_WEB_SOCKET_BUFFER_TYPE type;
        string fullMsg;

        do {
            DWORD ret = WinHttpWebSocketReceive(hWebSocket, buffer, sizeof(buffer), &bytesRead, &type);
            if (ret != ERROR_SUCCESS) {
                Close();
                return false;
            }
            if (type == WINHTTP_WEB_SOCKET_CLOSE_BUFFER_TYPE) {
                Log("WebSocket Closed by Server");
                Close();
                return false;
            }
            fullMsg.append(buffer, bytesRead);
        } while (bytesRead == sizeof(buffer) || type == WINHTTP_WEB_SOCKET_UTF8_FRAGMENT_BUFFER_TYPE);

        outMsg = fullMsg;
        return true;
    }

    bool IsConnected() const { return connected; }
};

struct Task {
    string action; 
    string id;
    string content;
    string type;
    string checkPath;
};

queue<Task> taskQueue;
mutex taskMutex;

int main() {
    WordAutomation word;
    WebSocketClient ws;
    JsonParser parser;
    
    Log("WordCOM Server Started");

    atomic<bool> running(true);

    thread wsThread([&]() {
        while (running) {
            if (!ws.IsConnected()) {
                if (!ws.Connect(L"localhost", 8080, L"/ws")) {
                    Sleep(2000);
                    continue;
                }
            }

            string msg;
            if (ws.Receive(msg)) {
                Log("Received: " + msg.substr(0, 100)); 
                JsonValue data = parser.parse(msg);
                
                if (data.type == J_OBJECT) {
                    string action = data.o_val["action"].s_val;
                    string id = data.o_val["id"].s_val;
                    string content = "";
                    string type = "";
                    string checkPath = "";

                    if (action == "replace") {
                        JsonValue payload = data.o_val["payload"];
                        content = payload.o_val["content"].s_val;
                        type = payload.o_val["type"].s_val;
                        
                        if (payload.o_val.count("options")) {
                            JsonValue options = payload.o_val["options"];
                            if (options.type == J_OBJECT && options.o_val.count("checkPath")) {
                                checkPath = options.o_val["checkPath"].s_val;
                            }
                        }
                    }

                    if (!action.empty()) {
                        lock_guard<mutex> lock(taskMutex);
                        taskQueue.push({action, id, content, type, checkPath});
                    }
                }
            }
        }
    });

    word.onSaveCallback = [&](string path) {
        string json = "{\"type\":\"event\",\"event\":\"saved\",\"path\":\"" + escapeJson(path) + "\"}";
        ws.Send(json);
        Log("Sent Saved Event");
    };

    while (running) {
        if (!word.IsConnected()) {
            word.Connect();
        } else {
            word.CheckSavedState();
        }

        {
            lock_guard<mutex> lock(taskMutex);
            while (!taskQueue.empty()) {
                Task t = taskQueue.front();
                taskQueue.pop();
                
                Log("Processing task: " + t.action);
                
                if (t.action == "save") {
                    bool ok = word.SaveDocument();
                    string status = ok ? "success" : "error";
                    string resp = "{\"type\":\"response\",\"id\":\"" + t.id + "\",\"status\":\"" + status + "\"}";
                    ws.Send(resp);
                } else if (t.action == "replace") {
                    if (!t.checkPath.empty()) {
                        if (!word.CheckPath(t.checkPath)) {
                            Log("CheckPath failed");
                            string resp = "{\"type\":\"response\",\"id\":\"" + t.id + "\",\"status\":\"error\",\"message\":\"Document path mismatch\"}";
                            ws.Send(resp);
                            continue;
                        }
                    }

                    bool ok = word.ReplaceDocument(t.content, t.type);
                    if (ok) word.SaveDocument();
                    string status = ok ? "success" : "error";
                    string resp = "{\"type\":\"response\",\"id\":\"" + t.id + "\",\"status\":\"" + status + "\"}";
                    ws.Send(resp);
                }
            }
        }

        Sleep(500);
    }

    if (wsThread.joinable()) wsThread.join();
    return 0;
}
