// 回归测试在 Release 构建下也必须执行断言。
#ifdef NDEBUG
#undef NDEBUG
#endif

#include <cassert>
#include <cstring>

#include "network/LocalTargetPolicy.hpp"

int main() {
    WSADATA data{};
    assert(WSAStartup(MAKEWORD(2, 2), &data) == 0);

    assert(Network::IsLoopbackHost("localhost"));
    assert(Network::IsLoopbackHost("LOCALHOST."));
    assert(Network::IsLoopbackHost("127.0.0.1"));
    assert(Network::IsLoopbackHost("127.255.255.254"));
    assert(Network::IsLoopbackHost("::1"));
    assert(Network::IsLoopbackHost("[::1]"));
    assert(Network::IsLoopbackHost("::ffff:127.0.0.2"));
    assert(!Network::IsLoopbackHost("127.example.com"));
    assert(!Network::IsLoopbackHost("192.168.1.1"));
    assert(!Network::IsLoopbackHost("8.8.8.8"));

    sockaddr_in address4{};
    address4.sin_family = AF_INET;
    assert(inet_pton(AF_INET, "127.0.0.2", &address4.sin_addr) == 1);
    assert(Network::IsLoopbackSockaddr(
        reinterpret_cast<const sockaddr*>(&address4), sizeof(address4)));
    assert(!Network::IsLoopbackSockaddr(
        reinterpret_cast<const sockaddr*>(&address4), sizeof(address4.sin_family)));

    assert(inet_pton(AF_INET, "126.255.255.255", &address4.sin_addr) == 1);
    assert(!Network::IsLoopbackSockaddr(
        reinterpret_cast<const sockaddr*>(&address4), sizeof(address4)));

    sockaddr_in6 address6{};
    address6.sin6_family = AF_INET6;
    assert(inet_pton(AF_INET6, "::1", &address6.sin6_addr) == 1);
    assert(Network::IsLoopbackSockaddr(
        reinterpret_cast<const sockaddr*>(&address6), sizeof(address6)));

    assert(inet_pton(AF_INET6, "::ffff:127.0.0.8", &address6.sin6_addr) == 1);
    assert(Network::IsLoopbackSockaddr(
        reinterpret_cast<const sockaddr*>(&address6), sizeof(address6)));

    assert(inet_pton(AF_INET6, "::ffff:8.8.8.8", &address6.sin6_addr) == 1);
    assert(!Network::IsLoopbackSockaddr(
        reinterpret_cast<const sockaddr*>(&address6), sizeof(address6)));

    sockaddr unsupported{};
    unsupported.sa_family = AF_UNSPEC;
    assert(!Network::IsLoopbackSockaddr(&unsupported, sizeof(unsupported)));
    assert(!Network::IsLoopbackSockaddr(nullptr, 0));

    assert(WSACleanup() == 0);
    return 0;
}
