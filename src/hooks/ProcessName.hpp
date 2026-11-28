#pragma once

#include <algorithm>
#include <cctype>
#include <string>
#include <utility>

namespace Hooks {

inline std::string ToLowerAsciiCopy(std::string s) {
    std::transform(s.begin(), s.end(), s.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return s;
}

inline void TrimAsciiInPlace(std::string& s) {
    auto isWs = [](unsigned char c) { return std::isspace(c) != 0; };
    size_t begin = 0;
    while (begin < s.size() && isWs(static_cast<unsigned char>(s[begin]))) begin++;
    size_t end = s.size();
    while (end > begin && isWs(static_cast<unsigned char>(s[end - 1]))) end--;
    s = s.substr(begin, end - begin);
}

inline std::string StripOuterQuotesCopy(std::string s) {
    TrimAsciiInPlace(s);
    if (s.size() >= 2 && s.front() == '"' && s.back() == '"') {
        s = s.substr(1, s.size() - 2);
        TrimAsciiInPlace(s);
    }
    return s;
}

inline std::string ExtractBaseNameFromPathLike(std::string s) {
    s = StripOuterQuotesCopy(std::move(s));
    const size_t lastSlash = s.find_last_of("\\/");
    if (lastSlash != std::string::npos) {
        s = s.substr(lastSlash + 1);
    }
    return StripOuterQuotesCopy(std::move(s));
}

inline std::string ExtractExecutableTokenFromCommandLine(std::string commandLine) {
    commandLine = StripOuterQuotesCopy(std::move(commandLine));
    if (commandLine.empty()) return "";

    // CreateProcess 的命令行可能是 `"C:\...\Antigravity IDE.exe" --flag`。
    // 先保留引号内完整路径，避免把带空格的 exe 名截断成 `Antigravity`。
    if (commandLine.front() == '"') {
        const size_t closingQuote = commandLine.find('"', 1);
        if (closingQuote != std::string::npos) {
            return commandLine.substr(1, closingQuote - 1);
        }
    }

    const std::string lowerCommandLine = ToLowerAsciiCopy(commandLine);
    const size_t exePos = lowerCommandLine.find(".exe");
    if (exePos != std::string::npos) {
        return commandLine.substr(0, exePos + 4);
    }

    const size_t firstSpace = commandLine.find(' ');
    if (firstSpace != std::string::npos) {
        return commandLine.substr(0, firstSpace);
    }
    return commandLine;
}

inline std::string GetCreateProcessTargetBaseNameA(const char* applicationName, const char* commandLine) {
    std::string target;
    if (applicationName && *applicationName) {
        target = applicationName;
    } else if (commandLine && *commandLine) {
        target = ExtractExecutableTokenFromCommandLine(commandLine);
    }
    target = ExtractBaseNameFromPathLike(std::move(target));
    return target.empty() ? std::string("Unknown") : target;
}

inline bool IsLanguageServerProcessName(const std::string& processName) {
    const std::string lowerName = ToLowerAsciiCopy(processName);
    return lowerName == "language_server.exe" ||
           lowerName == "language_server" ||
           lowerName.find("language_server_windows") != std::string::npos;
}

inline bool IsAntigravityHostProcessName(const std::string& processName) {
    const std::string lowerName = ToLowerAsciiCopy(processName);
    return lowerName == "antigravity.exe" ||
           lowerName == "antigravity ide.exe";
}

inline bool IsGeminiProcessName(const std::string& processName) {
    const std::string lowerName = ToLowerAsciiCopy(processName);
    return lowerName == "gemini.exe" ||
           lowerName == "geminiapplauncher.exe";
}

inline bool IsCrashpadProcessName(const std::string& processName) {
    const std::string lowerName = ToLowerAsciiCopy(processName);
    return lowerName == "geminicrashpadhandler.exe" ||
           lowerName == "chrome_crashpad_handler.exe" ||
           lowerName == "crashpad_handler.exe" ||
           // Chromium 系（WebView2 / Edge / Chrome）实际用的是连字符写法
           lowerName == "crashpad-handler.exe";
}

// WebView2 / Edge 内核宿主进程：聊天界面与网络栈都在这里，
// 但它属于嵌入式子进程，不该弹「加载成功」提示。
inline bool IsWebView2HostProcessName(const std::string& processName) {
    const std::string lowerName = ToLowerAsciiCopy(processName);
    return lowerName == "msedgewebview2.exe" ||
           lowerName == "msedge.exe" ||
           lowerName == "webview2.exe";
}

// 商店版 WhatsApp 的宿主进程（.NET + WinUI 外壳，聊天 UI 跑在 WebView2 里）
inline bool IsWhatsAppHostProcessName(const std::string& processName) {
    const std::string lowerName = ToLowerAsciiCopy(processName);
    return lowerName == "whatsapp.root.exe";
}

// Chromium 沙箱子进程类型：renderer / gpu-process / zygote 处于 AppContainer
// 之类的受限环境，注入必然失败，而且它们本身不做网络 IO（网络栈在
// network.mojom.NetworkService），因此在创建阶段就跳过，省掉满屏的失败日志。
inline bool IsSandboxedChromiumSubprocess(const std::string& commandLine) {
    if (commandLine.empty()) return false;
    return commandLine.find("--type=renderer") != std::string::npos ||
           commandLine.find("--type=gpu-process") != std::string::npos ||
           commandLine.find("--type=zygote") != std::string::npos ||
           commandLine.find("--type=crashpad-handler") != std::string::npos;
}

// WebView2 宿主进程的命令行特征：带 --webview-exe-name= 或 --embedded-browser-webview
inline bool IsWebView2EmbeddedHostCommandLine(const std::string& commandLine) {
    if (commandLine.empty()) return false;
    return commandLine.find("--webview-exe-name=") != std::string::npos ||
           commandLine.find("--embedded-browser-webview") != std::string::npos;
}

} // namespace Hooks
