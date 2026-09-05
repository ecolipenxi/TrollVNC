// GPL-2.0, part of the LuaAgent/TrollVNC integration.
#import "LiveControl.h"
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/tcp.h>
#include <unistd.h>
#include <atomic>
#include <thread>
#include <string>

namespace {
std::atomic_int clients{0};
bool sendJson(int fd, NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    if (!data) return false;
    std::string bytes(static_cast<const char *>(data.bytes), data.length);
    bytes += '\n';
    size_t offset = 0;
    while (offset < bytes.size()) {
        ssize_t n = send(fd, bytes.data() + offset, bytes.size() - offset, 0);
        if (n <= 0) return false;
        offset += n;
    }
    return true;
}
NSDictionary *readJson(int fd) {
    // Bounded line; a quiet/broken connection times out and releases all input.
    std::string text;
    char c;
    while (text.size() < 4096) {
        if (recv(fd, &c, 1, 0) != 1) return nil;
        if (c == '\n') {
            NSData *data = [NSData dataWithBytes:text.data() length:text.size()];
            id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            return [value isKindOfClass:NSDictionary.class] ? value : nil;
        }
        text += c;
    }
    return nil;
}
void handle(int fd) {
    bool acquired = false;
    @try {
        NSDictionary *hello = readJson(fd);
        NSString *identifier = TVLiveDeviceIdentifier();
        NSString *expected = hello[@"deviceId"];
        if (![hello[@"type"] isEqual:@"hello"] ||
            ![expected isKindOfClass:NSString.class] || expected.length == 0 ||
            [expected caseInsensitiveCompare:identifier] != NSOrderedSame) {
            sendJson(fd, @{@"ok":@NO, @"error":@"DEVICE_MISMATCH"});
            return;
        }
        acquired = TVAcquireLiveInput();
        if (!acquired) {
            sendJson(fd, @{@"ok":@NO, @"error":@"INPUT_BUSY"});
            return;
        }
        if (!sendJson(fd, @{@"ok":@YES, @"type":@"hello", @"protocol":@1,
                           @"deviceId":identifier, @"display":TVLiveDisplayInfo()})) return;
        long long lastSequence = 0;
        for (;;) {
            @autoreleasepool {
                NSDictionary *event = readJson(fd);
                if (!event) break;
                NSNumber *sequence = event[@"seq"];
                if (![sequence isKindOfClass:NSNumber.class] || sequence.longLongValue <= lastSequence) break;
                lastSequence = sequence.longLongValue;
                NSString *type = event[@"type"];
                if ([type isEqual:@"ping"]) {
                    if (!sendJson(fd, @{@"ok":@YES, @"type":@"pong", @"display":TVLiveDisplayInfo()})) break;
                } else if ([type isEqual:@"close"]) {
                    break;
                } else if (!TVLiveApplyEvent(event)) {
                    TVLiveResetInput();
                    if (!sendJson(fd, @{@"ok":@NO, @"error":@"EVENT_REJECTED", @"display":TVLiveDisplayInfo()})) break;
                }
            }
        }
    } @catch (NSException *exception) {
        sendJson(fd, @{@"ok":@NO, @"error":@"INVALID_EVENT"});
    } @finally {
        if (acquired) {
            TVLiveResetInput();
            TVReleaseLiveInput();
        }
    }
}
}

void TVStartLiveControlServer(uint16_t port) {
    std::thread([port] {
        @autoreleasepool {
            int server = socket(AF_INET, SOCK_STREAM, 0);
            if (server < 0) return;
            int yes = 1;
            setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
            sockaddr_in address{};
            address.sin_family = AF_INET;
            address.sin_addr.s_addr = htonl(INADDR_ANY);
            address.sin_port = htons(port);
            if (bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)) || listen(server, 8)) {
                close(server); return;
            }
            for (;;) {
                int fd = accept(server, nullptr, nullptr);
                if (fd < 0) continue;
                if (clients.fetch_add(1) >= 8) { clients--; close(fd); continue; }
                timeval timeout{3, 0};
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
                setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, sizeof(yes));
                std::thread([fd] {
                    @autoreleasepool { handle(fd); }
                    close(fd); clients--;
                }).detach();
            }
        }
    }).detach();
}
