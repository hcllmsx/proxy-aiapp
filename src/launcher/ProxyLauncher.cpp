// 防止 windows.h 自动包含 winsock.h (避免与 winsock2.h 冲突)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

// ============================================================================
// Proxy-AiApp · 商店应用启动器（ProxyLauncher.exe）
//
// 背景：微软商店版应用（WhatsApp / ChatGPT 等）打包在 C:\Program Files\WindowsApps 下，
// 该目录对普通进程只读，无法像 Gemini 那样把 version.dll 直接投放进应用目录。
// 因此改用「运行时注入」：本程序负责激活应用，并在进程刚起来的一瞬把代理 DLL 注进去，
// 随后按后代链追踪并注入承载网络栈的子进程。
//
// 为什么必须抢时间：Electron / WebView2 的浏览器进程与网络服务进程在宿主进程起来
// 约 200~300ms 后就会创建，而首次导航失败后应用会放弃重试。注入太晚，
// 界面就再也加载不出来（或者第一次请求直连泄漏）。
//
// 多目标：不同商店应用的宿主进程名、AUMID、需要注入的子进程都不同，
// 因此统一由 config.json 里的 <key> 段描述，命令行用 --target <key> 选择。
//   whatsapp : 5319275A.WhatsAppDesktop_cv1g1gvanyjgm!App（.NET + WinUI + WebView2）
//   chatgpt  : OpenAI.Codex_2p2nqsd0c76g0!App（Electron，界面与网络栈在 utility 子进程）
//
// 用法：
//   ProxyLauncher.exe [--target <key>] [--aumid <AUMID>] [--dll <DLL 路径>]
//                     [--config <配置路径>] [--watch <秒>] [--no-restart] [--quiet]
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

void InitLog(const std::wstring& exeDir, const std::string& targetKey) {
    SYSTEMTIME st = {};
    GetLocalTime(&st);
    char stamp[16] = {0};
    std::snprintf(stamp, sizeof(stamp), "%04d%02d%02d", st.wYear, st.wMonth, st.wDay);

    const std::wstring logDir = JoinPath(exeDir, L"logs");
    CreateDirectoryW(logDir.c_str(), nullptr);

    const std::wstring logFile =
        JoinPath(logDir, Utf8ToWide(std::string("launcher-") + targetKey + "-" + stamp + ".log"));
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

// 找出「应用主进程」：同名进程里父进程不是同名进程的那些。
// Electron / Chromium 这类应用会有大量同名子进程（renderer、gpu、utility），
// 它们的父进程都是主进程；只有主进程的父进程在应用之外，才是真正该注入的宿主。
std::vector<DWORD> FindTopLevelProcesses(const std::vector<ProcessEntry>& processes,
                                         const std::string& targetName) {
    const std::vector<DWORD> sameName = FindProcessesByName(processes, targetName);
    std::set<DWORD> sameNameSet(sameName.begin(), sameName.end());

    std::vector<DWORD> result;
    for (const auto& p : processes) {
        if (ToLowerAscii(WideToUtf8(p.name.c_str())) != ToLowerAscii(targetName)) continue;
        if (sameNameSet.count(p.parentPid) == 0) {
            result.push_back(p.pid);
        }
    }
    if (!result.empty()) return result;
    return sameName; // 兜底：主进程可能已被回收，至少还有同名进程可试
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
bool TerminateExistingInstances(const std::vector<DWORD>& pids, const std::string& displayName,
                                std::string* reason) {
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
        *reason = "已运行的 " + displayName + " 未能完全退出";
    }
    return allExited;
}

// ============================ 启动参数 ============================

struct Options {
    std::string targetKey = "whatsapp";
    std::wstring dllPath;
    std::wstring configPath;
    std::wstring aumid;      // 命令行覆盖
    int watchSeconds = 45;   // 命令行覆盖
    bool forceRestart = true;
    bool quiet = false;
};

// 一个「启动器型目标」的完整描述，来源是 config.json 里的 <key> 段
struct LaunchTarget {
    std::string key;
    std::string displayName;
    std::wstring aumid;
    std::string rootProcess;
    std::vector<std::string> childProcesses;
    int watchSeconds = 45;
    bool forceRestart = true;
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

// 从配置里取出目标描述；key 不认识时返回 false
bool BuildLaunchTarget(const std::string& key, const Core::Config& config, LaunchTarget* out,
                       std::string* reason) {
    const Core::LauncherAppConfig* src = nullptr;
    if (key == "whatsapp") {
        src = &config.whatsapp;
    } else if (key == "chatgpt") {
        src = &config.chatgpt;
    } else {
        if (reason) *reason = "未知的目标标识：" + key + "（可用：whatsapp / chatgpt）";
        return false;
    }

    out->key = key;
    out->displayName = src->displayName.empty() ? key : src->displayName;
    out->aumid = Utf8ToWide(src->aumid);
    out->rootProcess = src->rootProcess;
    out->childProcesses = src->childProcesses;
    out->watchSeconds = src->watchSeconds;
    out->forceRestart = src->forceRestart;
    return true;
}

bool IsChildProcessName(const std::string& lowerName, const std::vector<std::string>& childProcesses) {
    for (const auto& p : childProcesses) {
        if (ToLowerAscii(p) == lowerName) return true;
    }
    return false;
}

} // namespace

int RunLauncher(int argc, LPWSTR* argv) {
    const std::wstring exeDir = GetExecutableDirectory();

    // ---- 先解析目标 key，日志文件名要带上它 ----
    std::string targetKey =
        ToLowerAscii(TrimAscii(WideToUtf8(ArgValue(argc, argv, L"--target", L"").c_str())));
    if (targetKey.empty()) targetKey = "whatsapp";

    InitLog(exeDir, targetKey);

    Options options;
    options.targetKey = targetKey;
    options.dllPath = JoinPath(exeDir, L"version.dll");
    options.configPath = JoinPath(exeDir, L"config.json");
    options.quiet = HasFlag(argc, argv, L"--quiet");

    // ---- 读取配置（读取失败时沿用默认值） ----
    Core::Config& config = Core::Config::Instance();
    const std::string configPath = WideToUtf8(options.configPath.c_str());
    if (!config.Load(configPath)) {
        LogLine("[提示] config.json 读取失败，使用默认配置");
    }

    LaunchTarget target;
    std::string buildReason;
    if (!BuildLaunchTarget(options.targetKey, config, &target, &buildReason)) {
        ShowError(buildReason, options.quiet);
        return 2;
    }

    // ---- 命令行覆盖配置 ----
    const std::wstring cliAumid = ArgValue(argc, argv, L"--aumid", L"");
    if (!cliAumid.empty()) target.aumid = cliAumid;
    const std::wstring cliDll = ArgValue(argc, argv, L"--dll", L"");
    if (!cliDll.empty()) options.dllPath = cliDll;
    const std::wstring cliConfig = ArgValue(argc, argv, L"--config", L"");
    if (!cliConfig.empty()) {
        options.configPath = cliConfig;
        if (Core::Config::Instance().Load(WideToUtf8(cliConfig.c_str()))) {
            LaunchTarget reloaded;
            std::string ignored;
            if (BuildLaunchTarget(options.targetKey, Core::Config::Instance(), &reloaded, &ignored)) {
                // 命令行显式指定的 AUMID 优先级更高
                if (cliAumid.empty()) target.aumid = reloaded.aumid;
                target.rootProcess = reloaded.rootProcess;
                target.childProcesses = reloaded.childProcesses;
                target.watchSeconds = reloaded.watchSeconds;
                target.forceRestart = reloaded.forceRestart;
            }
        }
    }
    const std::wstring cliWatch = ArgValue(argc, argv, L"--watch", L"");
    if (!cliWatch.empty()) {
        const int parsed = _wtoi(cliWatch.c_str());
        if (parsed > 0) target.watchSeconds = parsed;
    }
    if (HasFlag(argc, argv, L"--no-restart")) target.forceRestart = false;

    // ---- 单实例互斥：按目标隔离，避免两个商店应用互相「杀进程再重启」 ----
    const std::wstring mutexName =
        L"Local\\ProxyAiApp_Launcher_" + Utf8ToWide(options.targetKey);
    HANDLE instanceMutex = CreateMutexW(nullptr, TRUE, mutexName.c_str());
    if (instanceMutex && GetLastError() == ERROR_ALREADY_EXISTS) {
        LogLine("已有启动器实例在运行，本次忽略（" + target.displayName + " 正在启动中）");
        CloseHandle(instanceMutex);
        return 0;
    }

    LogLine("目标: " + target.displayName + " (key=" + target.key + ")");
    LogLine("配置: aumid=" + WideToUtf8(target.aumid.c_str()) +
            ", dll=" + WideToUtf8(options.dllPath.c_str()) +
            ", root=" + target.rootProcess +
            ", children=" + [&] {
                std::string joined;
                for (const auto& c : target.childProcesses) {
                    if (!joined.empty()) joined += ",";
                    joined += c;
                }
                return joined;
            }() +
            ", watch=" + std::to_string(target.watchSeconds) + "s" +
            ", force_restart=" + (target.forceRestart ? "true" : "false"));

    // ---- 前置检查 ----
    if (options.dllPath.empty() || GetFileAttributesW(options.dllPath.c_str()) == INVALID_FILE_ATTRIBUTES) {
        ShowError("未找到代理 DLL：" + WideToUtf8(options.dllPath.c_str()) +
                      "\n请先运行 install.bat 安装代理。",
                  options.quiet);
        if (instanceMutex) { ReleaseMutex(instanceMutex); CloseHandle(instanceMutex); }
        return 2;
    }
    if (target.aumid.empty()) {
        ShowError("未配置 " + target.displayName + " 的应用标识（AUMID）。\n请运行 install.bat 重新检测安装。",
                  options.quiet);
        if (instanceMutex) { ReleaseMutex(instanceMutex); CloseHandle(instanceMutex); }
        return 2;
    }
    if (target.rootProcess.empty()) {
        ShowError("未配置 " + target.displayName + " 的宿主进程名。\n请检查 config.json。", options.quiet);
        if (instanceMutex) { ReleaseMutex(instanceMutex); CloseHandle(instanceMutex); }
        return 2;
    }

    // ---- 处理已经在运行的实例 ----
    std::vector<ProcessEntry> snapshot = SnapshotProcesses();
    const std::vector<DWORD> runningRoots = FindProcessesByName(snapshot, target.rootProcess);
    if (!runningRoots.empty()) {
        if (target.forceRestart) {
            LogLine("检测到 " + target.displayName + " 已在运行（" +
                    std::to_string(runningRoots.size()) + " 个进程），先结束旧实例再带代理重启");
            std::string reason;
            if (!TerminateExistingInstances(runningRoots, target.displayName, &reason)) {
                LogLine("[警告] " + reason);
            }
            // 结束后宿主与它的子进程会一并退出，等它们真正消失
            for (int i = 0; i < 50; i++) {
                snapshot = SnapshotProcesses();
                if (FindProcessesByName(snapshot, target.rootProcess).empty()) break;
                Sleep(100);
            }
        } else {
            LogLine("检测到 " + target.displayName + " 已在运行，按 --no-restart 直接为其注入");
        }
    }

    // ---- 激活应用 ----
    std::string activateReason;
    if (!ActivateApplication(target.aumid, &activateReason)) {
        ShowError("启动 " + target.displayName + " 失败：" + activateReason, options.quiet);
        if (instanceMutex) { ReleaseMutex(instanceMutex); CloseHandle(instanceMutex); }
        return 3;
    }
    LogLine("已激活应用: " + WideToUtf8(target.aumid.c_str()));

    // ---- 等待宿主进程出现并注入 ----
    DWORD rootPid = 0;
    const ULONGLONG waitDeadline = GetTickCount64() + 30000;
    while (GetTickCount64() < waitDeadline) {
        snapshot = SnapshotProcesses();
        const std::vector<DWORD> roots = FindTopLevelProcesses(snapshot, target.rootProcess);
        if (!roots.empty()) {
            rootPid = roots.front();
            break;
        }
        Sleep(10);
    }
    if (rootPid == 0) {
        ShowError("等待 " + target.displayName + " 主进程超时（30 秒）。\n请确认已安装微软商店版 " +
                      target.displayName + "。",
                  options.quiet);
        if (instanceMutex) { ReleaseMutex(instanceMutex); CloseHandle(instanceMutex); }
        return 4;
    }
    LogLine("主进程已出现: " + target.rootProcess + " pid=" + std::to_string(rootPid));

    std::string injectReason;
    if (!InjectWithRetry(rootPid, options.dllPath, 12, 80, &injectReason)) {
        ShowError("向 " + target.displayName + " 主进程注入代理失败：" + injectReason, options.quiet);
        if (instanceMutex) { ReleaseMutex(instanceMutex); CloseHandle(instanceMutex); }
        return 5;
    }
    LogLine("[成功] 已注入主进程 pid=" + std::to_string(rootPid));

    // ---- 按后代链追踪并注入承载网络栈的子进程 ----
    // 主进程注入完成后，DLL 自身的 CreateProcess Hook 通常已经能接管子进程的
    // 创建流程；这里的追踪是兜底，覆盖 Hook 没捕获到的情况
    // （Chromium / Electron 的沙箱进程正是走 CreateProcessAsUser，Hook 抓不到）。
    std::set<DWORD> injected;
    injected.insert(rootPid);
    int injectedCount = 0;
    const ULONGLONG watchStart = GetTickCount64();
    const ULONGLONG watchDeadline = watchStart + static_cast<ULONGLONG>(target.watchSeconds) * 1000;
    while (GetTickCount64() < watchDeadline) {
        snapshot = SnapshotProcesses();
        const std::vector<DWORD> descendants = CollectDescendants(snapshot, rootPid);
        for (DWORD pid : descendants) {
            if (injected.count(pid)) continue;
            const auto it = std::find_if(snapshot.begin(), snapshot.end(),
                                         [pid](const ProcessEntry& e) { return e.pid == pid; });
            if (it == snapshot.end()) continue;
            const std::string name = ToLowerAscii(WideToUtf8(it->name.c_str()));
            if (!IsChildProcessName(name, target.childProcesses)) continue;

            injected.insert(pid);
            std::string reason;
            if (InjectWithRetry(pid, options.dllPath, 4, 60, &reason)) {
                injectedCount++;
                LogLine("[成功] 已注入子进程 pid=" + std::to_string(pid) +
                        " (" + WideToUtf8(it->name.c_str()) + ")");
            } else {
                // 沙箱子进程注入失败属正常现象，不视为整体失败
                LogLine("[跳过] 子进程 pid=" + std::to_string(pid) + " 注入失败: " + reason);
            }
        }
        if (!IsProcessAlive(rootPid)) {
            LogLine("主进程已退出，停止追踪");
            break;
        }
        // 前 5 秒用密集轮询抢注入时机（网络服务进程出现得很快），
        // 之后放宽到 100ms，避免长时间空转把 CPU 吃满。
        const DWORD interval = (GetTickCount64() - watchStart < 5000) ? 10 : 100;
        Sleep(interval);
    }

    LogLine("==== 启动器结束：已注入 " + std::to_string(injectedCount) + " 个子进程 ====");
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
