// 回归测试在 Release 构建下也必须执行断言。
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>

#include "core/UdpPolicy.hpp"

int main() {
    using Core::ResolveUdpAction;
    using Core::UdpAction;

    // 默认 auto 在 SOCKS5 下启用 UDP Associate。
    assert(ResolveUdpAction("auto", "socks5", "block") == UdpAction::Proxy);

    // HTTP 没有标准 UDP 转发能力，auto 必须遵循显式 fallback。
    assert(ResolveUdpAction("auto", "http", "block") == UdpAction::Block);
    assert(ResolveUdpAction("auto", "http", "direct") == UdpAction::Direct);

    // 显式模式保持用户选择；proxy 的运行时失败再由 fallback 处理。
    assert(ResolveUdpAction("proxy", "http", "block") == UdpAction::Proxy);
    assert(ResolveUdpAction("direct", "socks5", "block") == UdpAction::Direct);
    assert(ResolveUdpAction("block", "socks5", "direct") == UdpAction::Block);

    // 非法值安全回退为 block。
    assert(ResolveUdpAction("invalid", "socks5", "direct") == UdpAction::Block);
    return 0;
}
