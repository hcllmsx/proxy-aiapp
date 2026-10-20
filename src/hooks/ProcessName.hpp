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
           lowerName == "crashpad_handler.exe";
}

} // namespace Hooks
