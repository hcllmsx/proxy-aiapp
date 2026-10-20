#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <winsock2.h>
#include <ws2tcpip.h>

// 回归测试在 Release 构建下也必须执行断言。
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>

#include "network/SocketFamily.hpp"

int main() {
    WSADATA data{};
    assert(WSAStartup(MAKEWORD(2, 2), &data) == 0);

    SOCKET socket6 = socket(AF_INET6, SOCK_STREAM, IPPROTO_TCP);
    assert(socket6 != INVALID_SOCKET);

    int error = 0;
    const Network::DualStackResult result =
        Network::EnsureIpv6DualStack(socket6, AF_INET6, &error);
    assert(result == Network::DualStackResult::Enabled ||
           result == Network::DualStackResult::AlreadyEnabled);
    assert(error == 0);

    DWORD v6Only = 1;
    int optionLength = static_cast<int>(sizeof(v6Only));
    assert(getsockopt(
               socket6,
               IPPROTO_IPV6,
               IPV6_V6ONLY,
               reinterpret_cast<char*>(&v6Only),
               &optionLength) == 0);
    assert(v6Only == 0);

    sockaddr_in6 mapped{};
    mapped.sin6_family = AF_INET6;
    mapped.sin6_addr.u.Byte[10] = 0xff;
    mapped.sin6_addr.u.Byte[11] = 0xff;
    mapped.sin6_addr.u.Byte[12] = 127;
    mapped.sin6_addr.u.Byte[15] = 1;
    assert(Network::IsIpv4MappedAddress(mapped));

    sockaddr_in6 native{};
    native.sin6_family = AF_INET6;
    native.sin6_addr = in6addr_loopback;
    assert(!Network::IsIpv4MappedAddress(native));

    closesocket(socket6);
    WSACleanup();
    return 0;
}
