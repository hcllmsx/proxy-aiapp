// 防止 windows.h 自动包含 winsock.h (避免与 winsock2.h 冲突)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

// ============================================================================
// Proxy-AiApp · 商店应用启动器（ProxyLauncher.exe）
//
// 背景：微软商店版 WhatsApp 打包在 C:\Program Files\WindowsApps 下，该目录对
// 普通进程只读，无法像 Gemini 那样把 version.dll 直接投放进应用目录。因此改用
// 「运行时注入」：本程序负责激活应用，并在进程刚起来的一瞬把代理 DLL 注进去，
// 随后按后代链追踪并注入承载聊天界面与网络栈的 WebView2 进程。
//
// 为什么必须抢时间：WebView2 的浏览器进程在宿主进程起来约 200~300ms 后就会
// 创建，而首次导航失败后应用会放弃重试。注入太晚，聊天界面就再也加载不出来。
//
// 用法：
//   ProxyLauncher.exe [--aumid <AUMID>] [--dll <DLL 路径>] [--config <配置路径>]
//                     [--watch <秒>] [--no-restart] [--quiet]
// ============================================================================

#include <windows.h>
#include <shellapi.h>
#include <tlhelp32.h>

#include <algorithm>
#include <cstdio>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "../core/Config.hpp"
#include "../injection/ProcessInjector.hpp"

namespace {

// ============================ 基础工具 ============================

std::string WideToUtf8(const wchar_t* input) {
    if (!input || *input == L'\0') return "";
    const int len = WideCharToMultiByte(CP_UTF8, 0, input, -1, nullptr, 0, nullptr, nullptr);
    if (len <= 0) return "";
    std::string result(static_cast<size_t>(len), '\0');
    WideCharToMultiByte(CP_UTF8, 0, input, -1, &result[0], len, nullptr, nullptr);
    if (!result.empty() && result.back() == '\0') result.pop_back();
    return result;
}

std::wstring Utf8ToWide(const std::string& input) {
    if (input.empty()) return L"";
    const int len = MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, nullptr, 0);
    if (len <= 0) return L"";
    std::wstring result(static_cast<size_t>(len), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, input.c_str(), -1, &result[0], len);
    if (!result.empty() && result.back() == L'\0') result.pop_back();
    return result;
}

std::string ToLowerAscii(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

std::string TrimAscii(const std::string& s) {
    size_t begin = 0;
    size_t end = s.size();
    while (begin < end && std::isspace(static_cast<unsigned char>(s[begin]))) begin++;
    while (end > begin && std::isspace(static_cast<unsigned char>(s[end - 1]))) end--;
    return s.substr(begin, end - begin);
}

std::wstring GetExecutableDirectory() {
    wchar_t path[MAX_PATH] = {0};
    const DWORD len = GetModuleFileNameW(nullptr, path, MAX_PATH);
    if (len == 0 || len >= MAX_PATH) return L"";
    std::wstring result(path, len);
    const size_t lastSlash = result.find_last_of(L"\\/");
    if (lastSlash == std::wstring::npos) return L"";
    return result.substr(0, lastSlash);
}

std::wstring JoinPath(const std::wstring& dir, const std::wstring& name) {
    if (dir.empty()) return name;
    if (dir.back() == L'\\' || dir.back() == L'/') return dir + name;
    return dir + L"\\" + name;
}

// ============================ 启动器日志 ============================

std::string g_logFilePath;
std::mutex g_logMutex;

std::string FormatTimestamp() {
    SYSTEMTIME st = {};
    GetLocalTime(&st);
    char buffer[32] = {0};
    std::snprintf(buffer, sizeof(buffer), "%04d-%02d-%02d %02d:%02d:%02d",
                  st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond);
    return buffer;
}

void LogLine(const std::string& message) {
    if (g_logFilePath.empty()) return;
    std::lock_guard<std::mutex> lock(g_logMutex);
    const std::string line = FormatTimestamp() + " [PID:" + std::to_string(GetCurrentProcessId()) +
                             "] " + message + "\r\n";
    HANDLE file = CreateFileA(g_logFilePath.c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) return;
    DWORD written = 0;
    WriteFile(file, line.data(), static_cast<DWORD>(line.size()), &written, nullptr);
    CloseHandle(file);
}

void InitLog(const std::wstring& exeDir) {
    SYSTEMTIME st = {};
    GetLocalTime(&st);
    char stamp[16] = {0};
    std::snprintf(stamp, sizeof(stamp), "%04d%02d%02d", st.wYear, st.wMonth, st.wDay);

    const std::wstring logDir = JoinPath(exeDir, L"logs");
    CreateDirectoryW(logDir.c_str(), nullptr);

    const std::wstring logFile = JoinPath(logDir, Utf8ToWide(std::string("launcher-") + stamp + ".log"));
    g_logFilePath = WideToUtf8(logFile.c_str());
    LogLine("==== Proxy-AiApp 启动器开始 ====");
}

// ============================ 进程枚举 ============================

struct ProcessEntry {
    DWORD pid = 0;
    DWORD parentPid = 0;
    std::wstring name;
};

std::vector<ProcessEntry> SnapshotProcesses() {
    std::vector<ProcessEntry> result;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot == INVALID_HANDLE_VALUE) return result;

    PROCESSENTRY32W entry = {};
    entry.dwSize = sizeof(entry);
    if (Process32FirstW(snapshot, &entry)) {
        do {
            ProcessEntry item;
            item.pid = entry.th32ProcessID;
            item.parentPid = entry.th32ParentProcessID;
            item.name = entry.szExeFile;
            result.push_back(item);
        } while (Process32NextW(snapshot, &entry));
    }
    CloseHandle(snapshot);
    return result;
}

bool IsProcessAlive(DWORD pid) {
    HANDLE handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!handle) return false;
    DWORD exitCode = 0;
    const bool alive = GetExitCodeProcess(handle, &exitCode) && exitCode == STILL_ACTIVE;
    CloseHandle(handle);
    return alive;
}

// 找出名字匹配指定进程名的全部进程（大小写不敏感）
std::vector<DWORD> FindProcessesByName(const std::vector<ProcessEntry>& processes,
                                       const std::string& targetName) {
    std::vector<DWORD> result;
    const std::string wanted = ToLowerAscii(targetName);
    for (const auto& p : processes) {
        if (ToLowerAscii(WideToUtf8(p.name.c_str())) == wanted) {
            result.push_back(p.pid);
        }
    }
    return result;
}

// 从 rootPid 出发做一次广度优先遍历，收集全部后代进程
std::vector<DWORD> CollectDescendants(const std::vector<ProcessEntry>& processes, DWORD rootPid) {
    std::map<DWORD, std::vector<DWORD>> childrenByParent;
    for (const auto& p : processes) {
        childrenByParent[p.parentPid].push_back(p.pid);
    }

    std::vector<DWORD> descendants;
    std::set<DWORD> visited;
    std::vector<DWORD> frontier;
    frontier.push_back(rootPid);

    while (!frontier.empty()) {
        std::vector<DWORD> next;
        for (DWORD pid : frontier) {
            auto it = childrenByParent.find(pid);
            if (it == childrenByParent.end()) continue;
            for (DWORD child : it->second) {
                if (child == rootPid) continue;
                if (!visited.insert(child).second) continue;
                descendants.push_back(child);
                next.push_back(child);
            }
        }
        frontier.swap(next);
    }
    return descendants;
}

// ============================ 注入 ============================

bool InjectIntoProcess(DWORD pid, const std::wstring& dllPath, std::string* reason) {
    HANDLE process = OpenProcess(PROCESS_ALL_ACCESS | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
    if (!process) {
        const DWORD err = GetLastError();
        if (reason) *reason = "OpenProcess 失败, err=" + std::to_string(err);
        return false;
    }
    std::string failure;
    const bool ok = Injection::ProcessInjector::InjectDll(process, dllPath, &failure);
    CloseHandle(process);
    if (!ok && reason) *reason = failure;
    return ok;
}

// 进程刚创建时可能还没完全就绪，OpenProcess / LoadLibrary 偶发失败，做有限次重试
bool InjectWithRetry(DWORD pid, const std::wstring& dllPath, int maxAttempts, int intervalMs,
                     std::string* reason) {
    std::string lastReason;
    for (int attempt = 0; attempt < maxAttempts; attempt++) {
        if (!IsProcessAlive(pid)) {
            if (reason) *reason = "目标进程已退出";
            return false;
        }
        if (InjectIntoProcess(pid, dllPath, &lastReason)) {
            return true;
        }
        Sleep(static_cast<DWORD>(intervalMs));
    }
    if (reason) *reason = lastReason;
    return false;
}

// ============================ 应用激活 ============================

// 商店应用必须通过 AUMID 激活，不能直接 StartProcess 包内 exe
bool ActivateApplication(const std::wstring& aumid, std::string* reason) {
    const std::wstring shellTarget = L"shell:AppsFolder\\" + aumid;

    // 优先直接交给 Shell 处理 shell: 命名空间
    HINSTANCE result = ShellExecuteW(nullptr, L"open", shellTarget.c_str(), nullptr, nullptr,
                                     SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(result) > 32) {
        return true;
    }

    // 兜底：走 explorer.exe 解析 shell:AppsFolder\AUMID（商店应用的标准激活方式）
    result = ShellExecuteW(nullptr, L"open", L"explorer.exe", shellTarget.c_str(), nullptr,
                            SW_SHOWNORMAL);
    if (reinterpret_cast<INT_PTR>(result) > 32) {
        return true;
    }

    if (reason) {
        *reason = "激活失败 (ShellExecute 返回 " + std::to_string(reinterpret_cast<INT_PTR>(result)) + ")";
    }
    return false;
}

// 结束仍在运行的旧实例，保证本次启动时首屏就已经带上代理
bool TerminateExistingInstances(const std::vector<DWORD>& pids, std::string* reason) {
    bool allExited = true;
    for (DWORD pid : pids) {
        HANDLE process = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (!process) continue;
        TerminateProcess(process, 0);
        CloseHandle(process);
    }
    for (DWORD pid : pids) {
        for (int i = 0; i < 40; i++) {
            if (!IsProcessAlive(pid)) break;
            Sleep(100);
        }
        if (IsProcessAlive(pid)) {
            allExited = false;
        }
    }
    if (!allExited && reason) {
        *reason = "已运行的 WhatsApp 未能完全退出";
    }
    return allExited;
}

// ============================ 启动参数 ============================

struct Options {
    std::wstring aumid;
    std::wstring dllPath;
    std::wstring configPath;
    int watchSeconds = 45;
    bool forceRestart = true;
    bool quiet = false;
};

std::wstring ArgValue(int argc, LPWSTR* argv, const wchar_t* name, const std::wstring& fallback) {
    for (int i = 1; i < argc - 1; i++) {
        if (_wcsicmp(argv[i], name) == 0) {
            return argv[i + 1];
        }
    }
    return fallback;
}

bool HasFlag(int argc, LPWSTR* argv, const wchar_t* name) {
    for (int i = 1; i < argc; i++) {
        if (_wcsicmp(argv[i], name) == 0) {
            return true;
        }
    }
    return false;
}

void ShowError(const std::string& message, bool quiet) {
    if (!quiet) {
        MessageBoxW(nullptr, Utf8ToWide(message).c_str(), L"Proxy-AiApp 启动器", MB_OK | MB_ICONERROR);
    }
    LogLine("[错误] " + message);
}

} // namespace

int RunLauncher(int argc, LPWSTR* argv) {
    const std::wstring exeDir = GetExecutableDirectory();
    InitLog(exeDir);

    // 单实例互斥：重复点击快捷方式时避免两个启动器互相「杀进程再重启」
    HANDLE instanceMutex = CreateMutexW(nullptr, TRUE, L"Local\\ProxyAiApp_Launcher");
    if (instanceMutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        LogLine("已有启动器实例在运行，本次忽略（WhatsApp 正在启动中）");
        CloseHandle(instanceMutex);
        return 0;
    }

    Options options;
    options.dllPath = JoinPath(exeDir, L"version.dll");
    options.configPath = JoinPath(exeDir, L"config.json");
    options.aumid = L"5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App";
    options.quiet = HasFlag(argc, argv, L"--quiet");

    // ---- 读取配置（读取失败时沿用默认值） ----
    Core::Config& config = Core::Config::Instance();
    const std::string configPath = WideToUtf8(options.configPath.c_str());
    if (!config.Load(configPath)) {
        LogLine("[提示] config.json 读取失败，使用默认配置");
    }
    const Core::WhatsAppConfig& whatsapp = config.whatsapp;

    options.aumid = Utf8ToWide(whatsapp.aumid);
    options.watchSeconds = whatsapp.watchSeconds;
    options.forceRestart = whatsapp.forceRestart;

    // ---- 命令行覆盖配置 ----
    const std::wstring cliAumid = ArgValue(argc, argv, L"--aumid", L"");
    if (!cliAumid.empty()) options.aumid = cliAumid;
    const std::wstring cliDll = ArgValue(argc, argv, L"--dll", L"");
    if (!cliDll.empty()) options.dllPath = cliDll;
    const std::wstring cliConfig = ArgValue(argc, argv, L"--config", L"");
    if (!cliConfig.empty()) {
        options.configPath = cliConfig;
        if (Core::Config::Instance().Load(WideToUtf8(cliConfig.c_str()))) {
            options.aumid = Utf8ToWide(Core::Config::Instance().whatsapp.aumid);
            options.watchSeconds = Core::Config::Instance().whatsapp.watchSeconds;
            options.forceRestart = Core::Config::Instance().whatsapp.forceRestart;
        }
    }
    const std::wstring cliWatch = ArgValue(argc, argv, L"--watch", L"");
    if (!cliWatch.empty()) {
        const int parsed = _wtoi(cliWatch.c_str());
        if (parsed > 0) options.watchSeconds = parsed;
    }
    if (HasFlag(argc, argv, L"--no-restart")) options.forceRestart = false;

    LogLine("配置: aumid=" + WideToUtf8(options.aumid.c_str()) +
            ", dll=" + WideToUtf8(options.dllPath.c_str()) +
            ", watch=" + std::to_string(options.watchSeconds) + "s" +
            ", force_restart=" + (options.forceRestart ? "true" : "false"));

    // ---- 前置检查 ----
    if (options.dllPath.empty() || GetFileAttributesW(options.dllPath.c_str()) == INVALID_FILE_ATTRIBUTES) {
        ShowError("未找到代理 DLL：" + WideToUtf8(options.dllPath.c_str()) +
                      "\n请先运行 install.bat 安装代理。",
                  options.quiet);
        return 2;
    }
    if (options.aumid.empty()) {
        ShowError("未配置 WhatsApp 的应用标识（AUMID）。\n请运行 install.bat 重新检测安装。", options.quiet);
        return 2;
    }

    const std::string rootProcessName = config.whatsapp.rootProcess;
    const std::string webviewProcessName = config.whatsapp.webviewProcess;

    // ---- 处理已经在运行的实例 ----
    std::vector<ProcessEntry> snapshot = SnapshotProcesses();
    std::vector<DWORD> runningRoots = FindProcessesByName(snapshot, rootProcessName);
    if (!runningRoots.empty()) {
        if (options.forceRestart) {
            LogLine("检测到 WhatsApp 已在运行（" + std::to_string(runningRoots.size()) +
                    " 个进程），先结束旧实例再带代理重启");
            std::string reason;
            if (!TerminateExistingInstances(runningRoots, &reason)) {
                LogLine("[警告] " + reason);
            }
            // 结束宿主进程后其 WebView2 子进程会一并退出，等它们真正消失
            for (int i = 0; i < 50; i++) {
                snapshot = SnapshotProcesses();
                const std::vector<DWORD> left = FindProcessesByName(snapshot, webviewProcessName);
                if (left.empty()) break;
                Sleep(100);
            }
        } else {
            LogLine("检测到 WhatsApp 已在运行，按 --no-restart 直接为其注入");
        }
    }

    // ---- 激活应用 ----
    std::string activateReason;
    if (!ActivateApplication(options.aumid, &activateReason)) {
        ShowError("启动 WhatsApp 失败：" + activateReason, options.quiet);
        return 3;
    }
    LogLine("已激活应用: " + WideToUtf8(options.aumid.c_str()));

    // ---- 等待宿主进程出现并注入 ----
    DWORD rootPid = 0;
    const ULONGLONG waitDeadline = GetTickCount64() + 30000;
    while (GetTickCount64() < waitDeadline) {
        snapshot = SnapshotProcesses();
        const std::vector<DWORD> roots = FindProcessesByName(snapshot, rootProcessName);
        if (!roots.empty()) {
            rootPid = roots.front();
            break;
        }
        Sleep(10);
    }
    if (rootPid == 0) {
        ShowError("等待 WhatsApp 主进程超时（30 秒）。\n请确认已安装微软商店版 WhatsApp。", options.quiet);
        return 4;
    }
    LogLine("主进程已出现: " + rootProcessName + " pid=" + std::to_string(rootPid));

    std::string injectReason;
    if (!InjectWithRetry(rootPid, options.dllPath, 12, 80, &injectReason)) {
        ShowError("向 WhatsApp 主进程注入代理失败：" + injectReason, options.quiet);
        return 5;
    }
    LogLine("[成功] 已注入主进程 pid=" + std::to_string(rootPid));

    // ---- 按后代链追踪并注入 WebView2 进程 ----
    // 主进程注入完成后，DLL 自身的 CreateProcess Hook 通常已经能接管 WebView2
    // 的创建流程；这里的追踪是兜底，覆盖 Hook 没捕获到的情况。
    std::set<DWORD> injected;
    injected.insert(rootPid);
    int injectedCount = 0;
    const ULONGLONG watchDeadline = GetTickCount64() + static_cast<ULONGLONG>(options.watchSeconds) * 1000;
    while (GetTickCount64() < watchDeadline) {
        snapshot = SnapshotProcesses();
        const std::vector<DWORD> descendants = CollectDescendants(snapshot, rootPid);
        for (DWORD pid : descendants) {
            if (injected.count(pid)) continue;
            const auto it = std::find_if(snapshot.begin(), snapshot.end(),
                                         [pid](const ProcessEntry& e) { return e.pid == pid; });
            if (it == snapshot.end()) continue;
            const std::string name = ToLowerAscii(WideToUtf8(it->name.c_str()));
            if (name != ToLowerAscii(webviewProcessName)) continue;

            injected.insert(pid);
            std::string reason;
            if (InjectWithRetry(pid, options.dllPath, 4, 60, &reason)) {
                injectedCount++;
                LogLine("[成功] 已注入 WebView2 进程 pid=" + std::to_string(pid) +
                        " (" + WideToUtf8(it->name.c_str()) + ")");
            } else {
                // 沙箱子进程注入失败属正常现象，不视为整体失败
                LogLine("[跳过] WebView2 进程 pid=" + std::to_string(pid) + " 注入失败: " + reason);
            }
        }
        if (!IsProcessAlive(rootPid)) {
            LogLine("主进程已退出，停止追踪");
            break;
        }
        // 追踪间隔要够短：WebView2 的网络服务进程比浏览器进程晚约 1~2 秒创建，
        // 晚一步就可能错过首次导航的时机。
        Sleep(15);
    }

    LogLine("==== 启动器结束：已注入 " + std::to_string(injectedCount) + " 个 WebView2 进程 ====");
    if (instanceMutex) {
        ReleaseMutex(instanceMutex);
        CloseHandle(instanceMutex);
    }
    return 0;
}

int WINAPI wWinMain(HINSTANCE, HINSTANCE, LPWSTR, int) {
    int argc = 0;
    LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
    if (!argv) {
        return 1;
    }
    const int result = RunLauncher(argc, argv);
    LocalFree(argv);
    return result;
}
