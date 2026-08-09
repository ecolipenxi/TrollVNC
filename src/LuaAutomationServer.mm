/*
 * Lua automation HTTP agent for TrollVNC.
 * Copyright (c) 2026 contributors.
 * Licensed under GPL-2.0 as part of TrollVNC.
 */

#import "LuaAutomationServer.h"
#import "ClipboardManager.h"
#import "STHIDEventGenerator.h"
#import "TVFrameSnapshot.h"

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>
#import <notify.h>
#import <objc/message.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <mutex>
#include <signal.h>
#include <spawn.h>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

#include <arpa/inet.h>
#include <mach/mach.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

// These are the exact raw touch primitives used by TrollVNC's pointer
// handler. They intentionally omit the marker event added by the public
// touchDown:/liftUp: helpers, because iOS 15 native permission alerts ignore
// that convenience sequence on some iPhone 6s/7 units.
@interface STHIDEventGenerator (LuaAgentRawTouch)
- (void)touchDownAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
- (void)liftUpAtPoints:(CGPoint *)locations touchCount:(NSUInteger)touchCount;
@end

extern "C" {
#include "lauxlib.h"
#include "lua.h"
#include "lualib.h"

FOUNDATION_EXPORT NSString *const SBSApplicationLaunchOptionUnlockDeviceKey;
FOUNDATION_EXPORT
int SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(
    CFStringRef bundleIdentifier, CFURLRef _Nullable url,
    CFDictionaryRef _Nullable appOptions, CFDictionaryRef _Nullable launchOptions,
    BOOL suspended);
int SBSOpenSensitiveURLAndUnlock(CFURLRef url, char flags);
CFStringRef _Nullable SBSCopyFrontmostApplicationDisplayIdentifier(void);
}

extern char **environ;

namespace {

constexpr char kLuaAgentVersion[] = "LuaAgent 3.1";
constexpr char kControllerAddressPath[] =
    "/var/mobile/Library/LuaAgent/controller-ip";

struct TouchGesture {
    double x1;
    double y1;
    double x2;
    double y2;
    double duration;
    bool moved;
};

std::atomic_bool gStarted{false};
std::atomic_bool gRunning{false};
std::atomic_bool gCancel{false};
std::atomic_int gActiveClients{0};
std::mutex gScriptMutex;
std::mutex gSpawnMutex;
std::thread gScriptThread;
std::mutex gStatusMutex;
std::string gLastError;
std::string gRunId;
std::vector<std::pair<std::string, std::string>> gRecentRequests;
std::vector<std::string> gRecentLogs;
double gStartedAt = 0;
double gFinishedAt = 0;
bool gStoppedByUser = false;
std::mutex gAppStateMutex;
std::unordered_map<std::string, double> gRecentlyKilledApps;
std::mutex gUpdateMutex;
std::mutex gKeepAliveMutex;
sockaddr_in gKeepAliveTarget{};
bool gHasKeepAliveTarget = false;
std::atomic_bool gPowerAssertionActive{false};

static void PersistControllerAddress(const sockaddr_in &peer) {
    char address[INET_ADDRSTRLEN] = {};
    if (!inet_ntop(AF_INET, &peer.sin_addr, address, sizeof(address))) return;
    @autoreleasepool {
        NSString *directory = @"/var/mobile/Library/LuaAgent";
        [NSFileManager.defaultManager createDirectoryAtPath:directory
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:nil];
        NSData *data = [[NSString stringWithUTF8String:address]
            dataUsingEncoding:NSUTF8StringEncoding];
        [data writeToFile:[NSString stringWithUTF8String:kControllerAddressPath]
                  options:NSDataWritingAtomic
                    error:nil];
    }
}

static void RememberControllerAddress(const sockaddr_in &peer) {
    if (peer.sin_family != AF_INET || peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK)) return;
    bool changed = false;
    {
        std::lock_guard<std::mutex> lock(gKeepAliveMutex);
        changed = !gHasKeepAliveTarget ||
            gKeepAliveTarget.sin_addr.s_addr != peer.sin_addr.s_addr;
        gKeepAliveTarget = peer;
        gKeepAliveTarget.sin_port = htons(46954);
        gHasKeepAliveTarget = true;
    }
    if (changed) PersistControllerAddress(peer);
}

static void LoadRememberedControllerAddress() {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:
            [NSString stringWithUTF8String:kControllerAddressPath]];
        if (!data.length || data.length >= INET_ADDRSTRLEN) return;
        NSString *text = [[NSString alloc] initWithData:data
                                                encoding:NSUTF8StringEncoding];
        sockaddr_in peer{};
        peer.sin_family = AF_INET;
        if (inet_pton(AF_INET, text.UTF8String, &peer.sin_addr) != 1 ||
            peer.sin_addr.s_addr == htonl(INADDR_LOOPBACK)) return;
        peer.sin_port = htons(46954);
        std::lock_guard<std::mutex> lock(gKeepAliveMutex);
        gKeepAliveTarget = peer;
        gHasKeepAliveTarget = true;
    }
}

// Keep the display dark without allowing the daemon, Wi-Fi, or Controller
// sockets to follow it into idle system sleep. Resolve IOKit dynamically for
// compatibility across the iOS 15-17 SDK/runtime combinations used here.
static bool AcquireNetworkPowerAssertions() {
    using CreateAssertionFn =
        int32_t (*)(CFStringRef, uint32_t, CFStringRef, uint32_t *);
    static void *ioKit = dlopen(
        "/System/Library/Frameworks/IOKit.framework/IOKit",
        RTLD_LAZY | RTLD_LOCAL);
    if (!ioKit) return false;
    auto createAssertion = reinterpret_cast<CreateAssertionFn>(
        dlsym(ioKit, "IOPMAssertionCreateWithName"));
    if (!createAssertion) return false;

    static uint32_t userIdleAssertion = 0;
    static uint32_t systemSleepAssertion = 0;
    if (!userIdleAssertion) {
        int32_t result = createAssertion(
            CFSTR("PreventUserIdleSystemSleep"), 255,
            CFSTR("LuaAgent Controller presence"), &userIdleAssertion);
        if (result != 0) userIdleAssertion = 0;
    }
    if (!systemSleepAssertion) {
        int32_t result = createAssertion(
            CFSTR("PreventSystemSleep"), 255,
            CFSTR("LuaAgent screen-off network"), &systemSleepAssertion);
        if (result != 0) systemSleepAssertion = 0;
    }
    bool active = userIdleAssertion != 0 || systemSleepAssertion != 0;
    gPowerAssertionActive.store(active);
    return active;
}

static void RunPowerAssertionWatchdog() {
    @autoreleasepool {
        for (;;) {
            if (!gPowerAssertionActive.load()) {
                bool acquired = AcquireNetworkPowerAssertions();
                NSLog(@"[LuaAgent] screen-off power assertion: %@",
                      acquired ? @"active" : @"unavailable");
            }
            usleep(30 * 1000 * 1000);
        }
    }
}

static void RunControllerKeepAlive() {
    @autoreleasepool {
        int fd = socket(AF_INET, SOCK_DGRAM, 0);
        if (fd < 0) return;
        timeval timeout{};
        timeout.tv_sec = 1;
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        const char payload[] = "LUAAGENT_KEEPALIVE_V1";
        const char expectedAck[] = "CONTROLLER_ACK_V1";
        for (;;) {
            sockaddr_in target{};
            bool hasTarget = false;
            {
                std::lock_guard<std::mutex> lock(gKeepAliveMutex);
                hasTarget = gHasKeepAliveTarget;
                if (hasTarget) target = gKeepAliveTarget;
            }
            if (hasTarget) {
                sendto(fd, payload, sizeof(payload) - 1, 0,
                       reinterpret_cast<sockaddr *>(&target), sizeof(target));
                char ack[64]{};
                sockaddr_in sender{};
                socklen_t senderLength = sizeof(sender);
                ssize_t received = recvfrom(
                    fd, ack, sizeof(ack), 0,
                    reinterpret_cast<sockaddr *>(&sender), &senderLength);
                if (received != static_cast<ssize_t>(sizeof(expectedAck) - 1) ||
                    std::memcmp(ack, expectedAck, sizeof(expectedAck) - 1) != 0) {
                    // UDP loss is tolerated; TCP presence below is the primary
                    // bidirectional screen-off keepalive.
                }
            }
            usleep(2 * 1000 * 1000);
        }
    }
}

static bool SendAll(int fd, const char *data, size_t size) {
    size_t sent = 0;
    while (sent < size) {
        ssize_t count = send(fd, data + sent, size - sent, 0);
        if (count <= 0) return false;
        sent += static_cast<size_t>(count);
    }
    return true;
}

static void RunControllerPresence();

static std::string JsonEscape(const std::string &value) {
    std::string out;
    out.reserve(value.size() + 16);
    for (unsigned char c : value) {
        switch (c) {
            case '"': out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\b': out += "\\b"; break;
            case '\f': out += "\\f"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20) {
                    char buf[8];
                    snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                } else {
                    out += static_cast<char>(c);
                }
        }
    }
    return out;
}

struct SpringBoardScreenApi {
    mach_port_t (*serverPort)(void) = nullptr;
    void (*lockStatus)(mach_port_t, Boolean *, Boolean *) = nullptr;
    void (*undim)(void) = nullptr;
    void (*lockDevice)(void) = nullptr;
    float (*backlightFactor)(void) = nullptr;
};

static SpringBoardScreenApi &ScreenApi() {
    static SpringBoardScreenApi api;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        void *handle = dlopen(
            "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices",
            RTLD_LAZY | RTLD_LOCAL);
        if (!handle) return;
        api.serverPort = reinterpret_cast<mach_port_t (*)(void)>(
            dlsym(handle, "SBSSpringBoardServerPort"));
        api.lockStatus = reinterpret_cast<void (*)(mach_port_t, Boolean *, Boolean *)>(
            dlsym(handle, "SBGetScreenLockStatus"));
        api.undim = reinterpret_cast<void (*)(void)>(dlsym(handle, "SBSUndimScreen"));
        api.lockDevice = reinterpret_cast<void (*)(void)>(dlsym(handle, "SBSLockDevice"));
        // This reports the actual display backlight, unlike SBGetScreenLockStatus
        // which remains "unlocked" when a passcode-free device's panel sleeps.
        api.backlightFactor = reinterpret_cast<float (*)(void)>(
            dlsym(handle, "SBGetCurrentBacklightFactor"));
    });
    return api;
}

static bool ReadBacklightFactor(float &factor) {
    auto &api = ScreenApi();
    if (!api.backlightFactor) return false;
    factor = api.backlightFactor();
    return std::isfinite(factor) && factor >= 0.0f && factor <= 1.5f;
}

static bool ReadDisplayBacklightLevel(long long &level, int *status = nullptr) {
    @autoreleasepool {
        if (status) *status = -1;
        // SBGetCurrentBacklightFactor is stale (always 0) from TrollVNC's
        // daemon process on a subset of iOS 15 iPhone 6s/7 devices.  The
        // FrontBoard display layout is the source SpringBoard itself uses and
        // keeps tracking the physical panel while this process stays alive.
        @try {
            static Class monitorClass = Nil;
            static int loadStatus = -10;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                void *handle = dlopen(
                    "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices",
                    RTLD_LAZY | RTLD_LOCAL);
                if (!handle) {
                    loadStatus = -10;
                    return;
                }
                monitorClass = NSClassFromString(@"FBSDisplayLayoutMonitor");
                loadStatus = monitorClass ? 0 : -11;
            });
            if (!monitorClass) {
                if (status) *status = loadStatus;
                return false;
            }

            SEL sharedSelector = NSSelectorFromString(@"sharedMonitorForDisplayType:");
            SEL layoutSelector = NSSelectorFromString(@"currentLayout");
            SEL levelSelector = NSSelectorFromString(@"displayBacklightLevel");
            if (![monitorClass respondsToSelector:sharedSelector]) {
                if (status) *status = -12;
                return false;
            }

            id monitor = ((id (*)(id, SEL, long long))objc_msgSend)(
                monitorClass, sharedSelector, 0LL);
            if (!monitor) {
                if (status) *status = -13;
                return false;
            }
            if (![monitor respondsToSelector:layoutSelector]) {
                if (status) *status = -14;
                return false;
            }
            id layout = ((id (*)(id, SEL))objc_msgSend)(monitor, layoutSelector);
            if (!layout) {
                if (status) *status = -15;
                return false;
            }
            if (![layout respondsToSelector:levelSelector]) {
                if (status) *status = -16;
                return false;
            }

            long long value = ((long long (*)(id, SEL))objc_msgSend)(layout, levelSelector);
            if (value < 0 || value > 10000) {
                if (status) *status = -17;
                return false;
            }
            level = value;
            if (status) *status = 0;
            return true;
        } @catch (NSException *exception) {
            if (status) *status = -18;
            return false;
        }
    }
}

static bool ReadSASLockScreenOn(bool &screenOn, int *status = nullptr) {
    @autoreleasepool {
        if (status) *status = -20;
        @try {
            static id monitor = nil;
            static int initStatus = -20;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                void *handle = dlopen(
                    "/System/Library/PrivateFrameworks/SiriActivation.framework/SiriActivation",
                    RTLD_LAZY | RTLD_LOCAL);
                if (!handle) {
                    initStatus = -20;
                    return;
                }
                Class monitorClass = NSClassFromString(@"SASLockStateMonitor");
                if (!monitorClass) {
                    initStatus = -21;
                    return;
                }
                monitor = [[monitorClass alloc] init];
                initStatus = monitor ? 0 : -22;
            });
            if (!monitor) {
                if (status) *status = initStatus;
                return false;
            }
            SEL selector = NSSelectorFromString(@"isScreenOn");
            if (![monitor respondsToSelector:selector]) {
                if (status) *status = -23;
                return false;
            }
            screenOn = ((BOOL (*)(id, SEL))objc_msgSend)(monitor, selector);
            if (status) *status = 0;
            return true;
        } @catch (NSException *exception) {
            if (status) *status = -24;
            return false;
        }
    }
}

static bool ReadSASSystemScreenOn(bool &screenOn, int *status = nullptr) {
    @autoreleasepool {
        if (status) *status = -30;
        @try {
            static Class systemStateClass = Nil;
            static int loadStatus = -30;
            static dispatch_once_t onceToken;
            dispatch_once(&onceToken, ^{
                void *handle = dlopen(
                    "/System/Library/PrivateFrameworks/SiriActivation.framework/SiriActivation",
                    RTLD_LAZY | RTLD_LOCAL);
                if (!handle) {
                    loadStatus = -30;
                    return;
                }
                systemStateClass = NSClassFromString(@"SASSystemState");
                loadStatus = systemStateClass ? 0 : -31;
            });
            if (!systemStateClass) {
                if (status) *status = loadStatus;
                return false;
            }
            SEL sharedSelector = NSSelectorFromString(@"sharedSystemState");
            if (![systemStateClass respondsToSelector:sharedSelector]) {
                if (status) *status = -32;
                return false;
            }
            id state = ((id (*)(id, SEL))objc_msgSend)(systemStateClass, sharedSelector);
            if (!state) {
                if (status) *status = -33;
                return false;
            }
            SEL screenSelector = NSSelectorFromString(@"deviceScreenIsOn");
            if (![state respondsToSelector:screenSelector]) {
                if (status) *status = -34;
                return false;
            }
            screenOn = ((BOOL (*)(id, SEL))objc_msgSend)(state, screenSelector);
            if (status) *status = 0;
            return true;
        } @catch (NSException *exception) {
            if (status) *status = -35;
            return false;
        }
    }
}

static bool ReadBlankedScreenNotification(bool &screenOn, int *status = nullptr,
                                          uint64_t *rawState = nullptr) {
    if (status) *status = -40;
    static int token = 0;
    static uint32_t registrationStatus = 1;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        registrationStatus = notify_register_check(
            "com.apple.springboard.hasBlankedScreen", &token);
    });
    if (registrationStatus != NOTIFY_STATUS_OK) {
        if (status) *status = -40;
        return false;
    }

    uint64_t state = 0;
    uint32_t readStatus = notify_get_state(token, &state);
    if (readStatus != NOTIFY_STATUS_OK) {
        if (status) *status = -41;
        return false;
    }
    if (rawState) *rawState = state;
    // This is the same Darwin state used by WorkflowKit's
    // WFScreenOnObserver: zero means the panel is not blanked.
    screenOn = state == 0;
    if (status) *status = 0;
    return true;
}

static bool ReadScreenOn(bool &screenOn, std::string *source = nullptr) {
    if (source) source->clear();
    long long displayBacklight = 0;
    if (ReadDisplayBacklightLevel(displayBacklight)) {
        screenOn = displayBacklight > 0;
        if (source) *source = "fbs_display_layout";
        return true;
    }
    if (ReadBlankedScreenNotification(screenOn)) {
        if (source) *source = "springboard_blanked_notify";
        return true;
    }
    float backlight = 0.0f;
    // From a root daemon SBGetCurrentBacklightFactor can be stale at exactly
    // zero.  A positive value is trustworthy; zero is reported as unknown so
    // wake() never toggles an already-lit panel off based on stale data.
    if (ReadBacklightFactor(backlight) && backlight > 0.01f) {
        screenOn = true;
        if (source) *source = "sbs_positive_backlight";
        return true;
    }
    return false;
}

static bool ReadScreenLocked(bool &locked) {
    auto &api = ScreenApi();
    if (!api.serverPort || !api.lockStatus) return false;
    Boolean screenLocked = false;
    Boolean passcode = false;
    api.lockStatus(api.serverPort(), &screenLocked, &passcode);
    locked = screenLocked;
    return true;
}

static std::string ReadFrontmostApplication() {
    @autoreleasepool {
        CFStringRef frontmostRef = SBSCopyFrontmostApplicationDisplayIdentifier();
        if (!frontmostRef) return "";
        NSString *frontmost = CFBridgingRelease(frontmostRef);
        return frontmost.UTF8String ?: "";
    }
}

static bool IsHomeFrontmostApplication(const std::string &frontmost) {
    // SpringBoard returns either its own bundle identifier or nil while the
    // icon grid is frontmost, depending on the iOS 15 point release/device.
    return frontmost.empty() || frontmost == "com.apple.springboard";
}

static int LuaDeviceIsScreenOn(lua_State *L) {
    bool screenOn = false;
    if (!ReadScreenOn(screenOn)) {
        lua_pushnil(L);
        lua_pushstring(L, "screen state API unavailable");
        return 2;
    }
    lua_pushboolean(L, screenOn);
    return 1;
}

static int LuaDeviceWake(lua_State *L) {
    auto &api = ScreenApi();
    if (!api.undim) {
        lua_pushnil(L);
        lua_pushstring(L, "safe wake API unavailable");
        return 2;
    }
    // Always try the non-toggle SpringBoard wake first.  If the real backlight
    // API confirms that the panel is still dark, use one HID power press; this
    // is safe because it is never sent while the panel is known to be on.
    api.undim();
    usleep(180 * 1000);
    api.undim();

    bool screenOn = false;
    if (ReadScreenOn(screenOn) && !screenOn) {
        [STHIDEventGenerator.sharedGenerator powerPress];
        usleep(450 * 1000);
        api.undim();
        usleep(180 * 1000);
        if (ReadScreenOn(screenOn) && !screenOn) {
            lua_pushnil(L);
            lua_pushstring(L, "panel remained dark after wake request");
            return 2;
        }
    }

    lua_pushboolean(L, true);
    return 1;
}

static int LuaDeviceSleep(lua_State *L) {
    // SBSLockDevice can update SpringBoard's lock state without powering off
    // the panel on passcode-free iOS 15 devices. A HID power press matches the
    // physical side button and reliably turns off an illuminated display.
    [STHIDEventGenerator.sharedGenerator powerPress];
    lua_pushboolean(L, true);
    return 1;
}

static std::string ApiJson(int code, const std::string &message, const std::string &data = "{}") {
    return "{\"code\":" + std::to_string(code) + ",\"message\":\"" + JsonEscape(message) +
           "\",\"data\":" + data + "}";
}

static CGPoint ScriptPoint(double x, double y) {
    // STHIDEventGenerator uses the device capture/native pixel coordinate
    // space (the same space used by TrollVNC pointer events and snapshots).
    return CGPointMake(x, y);
}

static bool SleepCancelable(unsigned long milliseconds) {
    while (milliseconds > 0 && !gCancel.load()) {
        unsigned long slice = std::min<unsigned long>(milliseconds, 50);
        usleep(static_cast<useconds_t>(slice * 1000));
        milliseconds -= slice;
    }
    return !gCancel.load();
}

static void LuaCancelHook(lua_State *L, lua_Debug *) {
    if (gCancel.load()) luaL_error(L, "script stopped");
}

static int LuaSysMsleep(lua_State *L) {
    lua_Integer ms = luaL_checkinteger(L, 1);
    if (ms > 0) SleepCancelable(static_cast<unsigned long>(ms));
    return 0;
}

static int LuaSysToast(lua_State *L) {
    const char *text = luaL_checkstring(L, 1);
    NSLog(@"[LuaAgent] toast: %s", text);
    return 0;
}

static int LuaLog(lua_State *L) {
    const char *text = luaL_tolstring(L, 1, nullptr);
    NSLog(@"[LuaAgent] %s", text ?: "");
    {
        std::lock_guard<std::mutex> lock(gStatusMutex);
        gRecentLogs.emplace_back(text ?: "");
        if (gRecentLogs.size() > 200) gRecentLogs.erase(gRecentLogs.begin());
    }
    lua_pop(L, 1);
    return 0;
}

static NSString *ClipboardStringOnMainThread() {
    __block NSString *text = nil;
    void (^readBlock)(void) = ^{
        text = [ClipboardManager.sharedManager currentString];
    };
    if ([NSThread isMainThread])
        readBlock();
    else
        dispatch_sync(dispatch_get_main_queue(), readBlock);
    return text;
}

static void SetClipboardStringOnMainThread(NSString *text) {
    void (^writeBlock)(void) = ^{
        [ClipboardManager.sharedManager setString:text ?: @""];
    };
    if ([NSThread isMainThread])
        writeBlock();
    else
        dispatch_sync(dispatch_get_main_queue(), writeBlock);
}

// Clipboard access stays inside the Lua process.  There is intentionally no
// unauthenticated HTTP clipboard endpoint exposed to the LAN.
static int LuaClipboardGet(lua_State *L) {
    @autoreleasepool {
        NSString *text = ClipboardStringOnMainThread();
        if (text.length == 0) {
            lua_pushnil(L);
            return 1;
        }
        NSData *utf8 = [text dataUsingEncoding:NSUTF8StringEncoding];
        if (!utf8) {
            lua_pushnil(L);
            return 1;
        }
        lua_pushlstring(L, static_cast<const char *>(utf8.bytes), utf8.length);
        return 1;
    }
}

static int LuaClipboardSet(lua_State *L) {
    size_t length = 0;
    const char *bytes = luaL_checklstring(L, 1, &length);
    if (length > 64 * 1024)
        return luaL_error(L, "clipboard text exceeds 65536 bytes");
    @autoreleasepool {
        NSString *text = [[NSString alloc] initWithBytes:bytes
                                                   length:length
                                                 encoding:NSUTF8StringEncoding];
        if (!text) {
            lua_pushboolean(L, false);
            lua_pushstring(L, "clipboard text is not valid UTF-8");
            return 2;
        }
        SetClipboardStringOnMainThread(text);
        lua_pushboolean(L, true);
        return 1;
    }
}

static int LuaClipboardClear(lua_State *L) {
    SetClipboardStringOnMainThread(@"");
    lua_pushboolean(L, true);
    return 1;
}

static bool IsSafePointEventName(const std::string &name) {
    if (name.empty() || name.size() > 40) return false;
    return std::all_of(name.begin(), name.end(), [](unsigned char c) {
        return (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
    });
}

static int LuaPointReport(lua_State *L) {
    size_t eventLength = 0;
    const char *eventBytes = luaL_checklstring(L, 1, &eventLength);
    size_t detailLength = 0;
    const char *detailBytes = luaL_optlstring(L, 2, "", &detailLength);
    std::string eventName(eventBytes, eventLength);
    if (!IsSafePointEventName(eventName))
        return luaL_error(L, "point event must use 1-40 uppercase letters, digits, or underscore");
    if (detailLength > 2048)
        return luaL_error(L, "point event detail exceeds 2048 bytes");

    std::string detail(detailBytes, detailLength);
    std::replace(detail.begin(), detail.end(), '\r', ' ');
    std::replace(detail.begin(), detail.end(), '\n', ' ');
    std::string line = "[TIKTOK_POINT] EVENT|" + eventName + "|" + detail;
    NSLog(@"[LuaAgent] %s", line.c_str());
    {
        std::lock_guard<std::mutex> lock(gStatusMutex);
        gRecentLogs.emplace_back(line);
        if (gRecentLogs.size() > 200) gRecentLogs.erase(gRecentLogs.begin());
    }
    lua_pushboolean(L, true);
    return 1;
}

static int LuaScreenInit(lua_State *) {
    return 0;
}

static int LuaScreenGetColor(lua_State *L) {
    double x = luaL_checknumber(L, 1);
    double y = luaL_checknumber(L, 2);
    int width = 0, height = 0;
    NSData *frame = TVCopyLatestFrameBGRA(&width, &height);
    if (!frame || width <= 0 || height <= 0) {
        lua_pushnil(L);
        return 1;
    }
    CGSize nativeSize = UIScreen.mainScreen.nativeBounds.size;
    int px = (int)llround(x * width / MAX(1.0, nativeSize.width));
    int py = (int)llround(y * height / MAX(1.0, nativeSize.height));
    px = MAX(0, MIN(width - 1, px));
    py = MAX(0, MIN(height - 1, py));
    const uint8_t *bytes = static_cast<const uint8_t *>(frame.bytes);
    const uint8_t *pixel = bytes + ((size_t)py * width + px) * 4;
    uint32_t rgb = ((uint32_t)pixel[2] << 16) | ((uint32_t)pixel[1] << 8) | pixel[0];
    lua_pushinteger(L, rgb);
    return 1;
}

static NSData *CopyImageBGRA(UIImage *image, int *outWidth, int *outHeight) {
    CGImageRef cgImage = image.CGImage;
    if (!cgImage) return nil;
    int width = (int)CGImageGetWidth(cgImage);
    int height = (int)CGImageGetHeight(cgImage);
    NSMutableData *data = [NSMutableData dataWithLength:(size_t)width * height * 4];
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    CGContextRef context = CGBitmapContextCreate(
        data.mutableBytes, width, height, 8, (size_t)width * 4, colorSpace,
        kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(colorSpace);
    if (!context) return nil;
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), cgImage);
    CGContextRelease(context);
    if (outWidth) *outWidth = width;
    if (outHeight) *outHeight = height;
    return data;
}

static int LuaScreenFindImage(lua_State *L) {
    // The Lua worker's outer autorelease pool lives for the entire script.
    // Long automation runs can call image matching hundreds of times, so drain
    // UIKit/CoreGraphics temporaries after every call on 2 GB iPhone 6s/7.
    @autoreleasepool {
    const char *pathCString = luaL_checkstring(L, 1);
    double similarity = luaL_optnumber(L, 2, 0.90);
    NSString *path = [[NSString stringWithUTF8String:pathCString] stringByExpandingTildeInPath];
    UIImage *needleImage = [UIImage imageWithContentsOfFile:path];
    int screenWidth = 0, screenHeight = 0;
    // Work from an immutable, freshly captured JPEG. Reading gFrontBuffer directly
    // here raced the capture thread while it resized/swapped buffers and could crash
    // the daemon during app transitions.
    NSData *freshJPEG = TVCreateFreshFrameJPEG(0.96, 2.0);
    UIImage *screenImage = freshJPEG ? [UIImage imageWithData:freshJPEG] : nil;
    NSData *screen =
        screenImage ? CopyImageBGRA(screenImage, &screenWidth, &screenHeight) : nil;
    int needleWidth = 0, needleHeight = 0;
    NSData *needle = needleImage ? CopyImageBGRA(needleImage, &needleWidth, &needleHeight) : nil;
    if (!screen || !needle || needleWidth <= 0 || needleHeight <= 0 ||
        needleWidth > screenWidth || needleHeight > screenHeight ||
        screen.length < (size_t)screenWidth * screenHeight * 4 ||
        needle.length < (size_t)needleWidth * needleHeight * 4) {
        lua_pushinteger(L, -1);
        lua_pushinteger(L, -1);
        return 2;
    }

    const uint8_t *hay = static_cast<const uint8_t *>(screen.bytes);
    const uint8_t *pin = static_cast<const uint8_t *>(needle.bytes);
    int sampleX = MAX(1, needleWidth / 12);
    int sampleY = MAX(1, needleHeight / 12);
    double maxMeanDifference = (1.0 - MAX(0.0, MIN(1.0, similarity))) * 255.0;
    CGSize nativeSize = UIScreen.mainScreen.nativeBounds.size;
    int searchMinX = 0, searchMinY = 0;
    int searchMaxX = screenWidth - needleWidth;
    int searchMaxY = screenHeight - needleHeight;
    if (lua_gettop(L) >= 6) {
        double rx = luaL_checknumber(L, 3);
        double ry = luaL_checknumber(L, 4);
        double rw = luaL_checknumber(L, 5);
        double rh = luaL_checknumber(L, 6);
        searchMinX = MAX(0, (int)floor(rx * screenWidth / MAX(1.0, nativeSize.width)));
        searchMinY = MAX(0, (int)floor(ry * screenHeight / MAX(1.0, nativeSize.height)));
        searchMaxX = MIN(searchMaxX, (int)ceil((rx + rw) * screenWidth /
                                               MAX(1.0, nativeSize.width)) - needleWidth);
        searchMaxY = MIN(searchMaxY, (int)ceil((ry + rh) * screenHeight /
                                               MAX(1.0, nativeSize.height)) - needleHeight);
    }
    int foundX = -1, foundY = -1;
    for (int y = searchMinY; y <= searchMaxY && foundX < 0; y += 2) {
        for (int x = searchMinX; x <= searchMaxX; x += 2) {
            uint64_t difference = 0;
            uint64_t channels = 0;
            bool rejected = false;
            for (int ny = 0; ny < needleHeight && !rejected; ny += sampleY) {
                for (int nx = 0; nx < needleWidth; nx += sampleX) {
                    const uint8_t *a = hay + ((size_t)(y + ny) * screenWidth + x + nx) * 4;
                    const uint8_t *b = pin + ((size_t)ny * needleWidth + nx) * 4;
                    difference += abs((int)a[0] - (int)b[0]);
                    difference += abs((int)a[1] - (int)b[1]);
                    difference += abs((int)a[2] - (int)b[2]);
                    channels += 3;
                    if (channels >= 24 && (double)difference / channels > maxMeanDifference * 1.8) {
                        rejected = true;
                        break;
                    }
                }
            }
            if (!rejected && channels > 0 && (double)difference / channels <= maxMeanDifference) {
                foundX = x;
                foundY = y;
                break;
            }
        }
    }
    if (foundX < 0) {
        lua_pushinteger(L, -1);
        lua_pushinteger(L, -1);
        return 2;
    }
    lua_pushinteger(L, llround(foundX * nativeSize.width / screenWidth));
    lua_pushinteger(L, llround(foundY * nativeSize.height / screenHeight));
    return 2;
    }
}

static int LuaScreenOCR(lua_State *L) {
    // Vision retains sizeable request/image intermediates until an autorelease
    // pool drains. A per-call pool prevents a long App Store/OCR phase from
    // exhausting memory and having iOS relaunch the Agent mid-script.
    @autoreleasepool {
    // OCR must observe the screen at the time of the Lua call. The VNC front
    // buffer can remain unchanged when no viewer is requesting frames, which
    // made long-running scripts read text from an earlier app screen.
    NSData *freshJPEG = TVCreateFreshFrameJPEG(0.96, 2.0);
    UIImage *image = freshJPEG ? [UIImage imageWithData:freshJPEG] : nil;
    if (!image.CGImage) {
        lua_pushnil(L);
        lua_pushstring(L, "screen frame is unavailable");
        return 2;
    }
    if (lua_gettop(L) >= 4) {
        double x = luaL_checknumber(L, 1);
        double y = luaL_checknumber(L, 2);
        double width = luaL_checknumber(L, 3);
        double height = luaL_checknumber(L, 4);
        CGSize nativeSize = UIScreen.mainScreen.nativeBounds.size;
        size_t imageWidth = CGImageGetWidth(image.CGImage);
        size_t imageHeight = CGImageGetHeight(image.CGImage);
        CGRect crop = CGRectMake(x * imageWidth / MAX(1.0, nativeSize.width),
                                 y * imageHeight / MAX(1.0, nativeSize.height),
                                 width * imageWidth / MAX(1.0, nativeSize.width),
                                 height * imageHeight / MAX(1.0, nativeSize.height));
        crop = CGRectIntersection(crop, CGRectMake(0, 0, imageWidth, imageHeight));
        if (!CGRectIsEmpty(crop)) {
            CGImageRef cropped = CGImageCreateWithImageInRect(image.CGImage, crop);
            if (cropped) {
                image = [UIImage imageWithCGImage:cropped];
                CGImageRelease(cropped);
            }
        }
    }
    __block NSMutableArray<NSString *> *lines = [NSMutableArray array];
    VNRecognizeTextRequest *request =
        [[VNRecognizeTextRequest alloc] initWithCompletionHandler:
            ^(VNRequest *finishedRequest, NSError *error) {
                if (error) return;
                for (VNRecognizedTextObservation *observation in finishedRequest.results) {
                    VNRecognizedText *candidate = [[observation topCandidates:1] firstObject];
                    if (candidate.string.length) [lines addObject:candidate.string];
                }
            }];
    request.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    request.usesLanguageCorrection = YES;
    VNImageRequestHandler *handler =
        [[VNImageRequestHandler alloc] initWithCGImage:image.CGImage options:@{}];
    NSError *error = nil;
    BOOL ok = [handler performRequests:@[request] error:&error];
    if (!ok) {
        lua_pushnil(L);
        lua_pushstring(L, error.localizedDescription.UTF8String ?: "OCR failed");
        return 2;
    }
    NSString *text = [lines componentsJoinedByString:@"\n"];
    lua_pushstring(L, text.UTF8String ?: "");
    return 1;
    }
}

static int LuaAppRun(lua_State *L) {
    const char *bundleCString = luaL_checkstring(L, 1);
    NSString *bundleID = [NSString stringWithUTF8String:bundleCString];
    int result = SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(
        (__bridge CFStringRef)bundleID, NULL, NULL,
        (__bridge CFDictionaryRef)@{SBSApplicationLaunchOptionUnlockDeviceKey : @YES}, NO);
    lua_pushboolean(L, result == 0);
    if (result != 0) {
        lua_pushfstring(L, "launch failed with code %d", result);
        return 2;
    }
    {
        std::lock_guard<std::mutex> lock(gAppStateMutex);
        gRecentlyKilledApps.erase(bundleCString);
    }
    return 1;
}

static int LuaAppKill(lua_State *L) {
    const char *bundleCString = luaL_checkstring(L, 1);
    NSString *bundleID = [NSString stringWithUTF8String:bundleCString];
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL sharedSelector = NSSelectorFromString(@"sharedService");
    SEL terminateSelector = NSSelectorFromString(
        @"terminateApplication:forReason:andReport:withDescription:");
    if (!serviceClass || ![serviceClass respondsToSelector:sharedSelector]) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "application termination service unavailable");
        return 2;
    }
    id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, sharedSelector);
    if (!service || ![service respondsToSelector:terminateSelector]) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "application termination selector unavailable");
        return 2;
    }
    ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(
        service, terminateSelector, bundleID, 1LL, NO, @"LuaAgent app.kill");
    {
        std::lock_guard<std::mutex> lock(gAppStateMutex);
        gRecentlyKilledApps[bundleCString] = [[NSDate date] timeIntervalSince1970];
    }
    lua_pushboolean(L, true);
    return 1;
}

static int LuaAppState(lua_State *L) {
    const char *bundleCString = luaL_checkstring(L, 1);
    double now = [[NSDate date] timeIntervalSince1970];
    {
        std::lock_guard<std::mutex> lock(gAppStateMutex);
        auto found = gRecentlyKilledApps.find(bundleCString);
        if (found != gRecentlyKilledApps.end() && now - found->second < 15.0) {
            lua_pushstring(L, "NOT RUNNING");
            return 1;
        }
    }
    CFStringRef frontmostRef = SBSCopyFrontmostApplicationDisplayIdentifier();
    NSString *frontmost = CFBridgingRelease(frontmostRef);
    if ([frontmost isEqualToString:[NSString stringWithUTF8String:bundleCString]])
        lua_pushstring(L, "ACTIVE");
    else
        lua_pushstring(L, "BACKGROUND");
    return 1;
}

static int LuaAppOpenURL(lua_State *L) {
    const char *urlCString = luaL_checkstring(L, 1);
    NSURL *url = [NSURL URLWithString:[NSString stringWithUTF8String:urlCString]];
    if (!url) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "invalid URL");
        return 2;
    }
    int result = SBSOpenSensitiveURLAndUnlock((__bridge CFURLRef)url, 1);
    lua_pushboolean(L, result == 0);
    if (result != 0) {
        lua_pushfstring(L, "open URL failed with code %d", result);
        return 2;
    }
    return 1;
}

static int LuaSysInputText(lua_State *L) {
    const char *textCString = luaL_checkstring(L, 1);
    NSString *text = [NSString stringWithUTF8String:textCString];
    STHIDEventGenerator *generator = STHIDEventGenerator.sharedGenerator;
    for (NSUInteger index = 0; index < text.length && !gCancel.load(); index++) {
        NSString *character = [text substringWithRange:NSMakeRange(index, 1)];
        [generator keyPress:character];
        usleep(35 * 1000);
    }
    lua_pushboolean(L, !gCancel.load());
    return 1;
}

static int LuaSysRootDir(lua_State *L) {
    NSString *path = @"/var/mobile/Library/LuaAgent";
    NSError *error = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:path
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:&error];
    if (error) {
        lua_pushnil(L);
        lua_pushstring(L, error.localizedDescription.UTF8String ?: "cannot create root directory");
        return 2;
    }
    lua_pushstring(L, path.UTF8String);
    return 1;
}

static bool IsAllowedWallpaperPath(NSString *path) {
    NSString *standardized = path.stringByStandardizingPath;
    NSString *root = @"/var/mobile/Library/LuaAgent/";
    return [standardized hasPrefix:root] &&
        ([standardized.pathExtension.lowercaseString isEqualToString:@"png"] ||
         [standardized.pathExtension.lowercaseString isEqualToString:@"jpg"] ||
         [standardized.pathExtension.lowercaseString isEqualToString:@"jpeg"] ||
         [standardized.pathExtension.lowercaseString isEqualToString:@"heic"]);
}

static NSString *WallpaperHelperPath() {
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *bundlePath = NSBundle.mainBundle.bundlePath;
    if (bundlePath.length > 0) {
        [candidates addObject:
            [bundlePath stringByAppendingPathComponent:@"trollvncwallpaper"]];
    }
    [candidates addObject:@"/var/jb/usr/bin/trollvncwallpaper"];
    [candidates addObject:@"/usr/bin/trollvncwallpaper"];
    for (NSString *candidate in candidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate])
            return candidate;
    }
    return nil;
}

static bool RunWallpaperHelper(NSString *imagePath, int locations,
                               std::string &error) {
    NSString *helperPath = WallpaperHelperPath();
    if (!helperPath) {
        error = "wallpaper helper is not installed";
        return false;
    }

    std::string helper = helperPath.UTF8String ?: "";
    std::string image = imagePath.UTF8String ?: "";
    std::string location = std::to_string(locations);
    char *argv[] = {
        const_cast<char *>(helper.c_str()),
        const_cast<char *>(image.c_str()),
        const_cast<char *>(location.c_str()),
        nullptr,
    };
    pid_t child = 0;
    int spawnError = posix_spawn(&child, helper.c_str(), nullptr, nullptr,
                                 argv, environ);
    if (spawnError != 0) {
        error = "cannot start wallpaper helper: " +
            std::string(strerror(spawnError));
        return false;
    }

    int status = 0;
    constexpr int kPolls = 80; // eight seconds, 100 ms per poll
    for (int poll = 0; poll < kPolls; poll++) {
        pid_t result = waitpid(child, &status, WNOHANG);
        if (result == child) {
            if (WIFEXITED(status) && WEXITSTATUS(status) == 0) return true;
            if (WIFEXITED(status)) {
                error = "wallpaper helper exited with code " +
                    std::to_string(WEXITSTATUS(status));
            } else if (WIFSIGNALED(status)) {
                error = "wallpaper helper stopped by signal " +
                    std::to_string(WTERMSIG(status));
            } else {
                error = "wallpaper helper did not complete";
            }
            return false;
        }
        if (result < 0) {
            error = "cannot wait for wallpaper helper: " +
                std::string(strerror(errno));
            return false;
        }
        usleep(100 * 1000);
    }

    kill(child, SIGKILL);
    waitpid(child, &status, 0);
    error = "wallpaper helper timed out after 8 seconds";
    return false;
}

static int LuaSysSetWallpaper(lua_State *L) {
    const char *lightCString = luaL_checkstring(L, 1);
    const char *darkCString = lua_isnoneornil(L, 2)
        ? nullptr : luaL_checkstring(L, 2);
    int locations = static_cast<int>(luaL_optinteger(L, 3, 3));
    if (locations < 1 || locations > 3) {
        lua_pushnil(L);
        lua_pushstring(L, "wallpaper location must be 1, 2, or 3");
        return 2;
    }

    @autoreleasepool {
        NSString *lightPath = [NSString stringWithUTF8String:lightCString];
        NSString *darkPath = darkCString
            ? [NSString stringWithUTF8String:darkCString]
            : lightPath;
        if (!lightPath || !darkPath ||
            !IsAllowedWallpaperPath(lightPath) ||
            !IsAllowedWallpaperPath(darkPath)) {
            lua_pushnil(L);
            lua_pushstring(L, "wallpaper path must be an image inside LuaAgent root");
            return 2;
        }
        if (darkCString && ![darkPath isEqualToString:lightPath]) {
            lua_pushnil(L);
            lua_pushstring(L,
                           "appearance-aware wallpaper is unavailable in the safe Agent API");
            return 2;
        }

        if (![[NSFileManager defaultManager]
                fileExistsAtPath:lightPath.stringByStandardizingPath]) {
            lua_pushnil(L);
            lua_pushstring(L, "wallpaper image does not exist");
            return 2;
        }
        std::string error;
        if (!RunWallpaperHelper(lightPath.stringByStandardizingPath,
                                locations, error)) {
            lua_pushnil(L);
            lua_pushstring(L, error.c_str());
            return 2;
        }
        lua_pushboolean(L, true);
        return 1;
    }
}

static int LuaAppRunShortcut(lua_State *L) {
    const char *nameCString = luaL_checkstring(L, 1);
    NSString *shortcutName = [NSString stringWithUTF8String:nameCString];
    if (shortcutName.length == 0) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "shortcut name is empty");
        return 2;
    }

    NSURLComponents *components = [[NSURLComponents alloc] init];
    components.scheme = @"shortcuts";
    components.host = @"run-shortcut";
    components.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"name" value:shortcutName],
    ];
    NSURL *url = components.URL;
    if (!url) {
        lua_pushboolean(L, false);
        lua_pushstring(L, "failed to create shortcut URL");
        return 2;
    }

    int result = SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(
        CFSTR("com.apple.shortcuts"), (__bridge CFURLRef)url, NULL,
        (__bridge CFDictionaryRef)@{SBSApplicationLaunchOptionUnlockDeviceKey : @YES}, NO);
    lua_pushboolean(L, result == 0);
    if (result != 0) {
        lua_pushfstring(L, "shortcut launch failed with code %d", result);
        return 2;
    }
    return 1;
}

static int LuaKeyPress(lua_State *L) {
    const char *key = luaL_checkstring(L, 1);
    NSString *name = [[NSString stringWithUTF8String:key] uppercaseString];
    STHIDEventGenerator *generator = STHIDEventGenerator.sharedGenerator;
    if ([name isEqualToString:@"HOMEBUTTON"] || [name isEqualToString:@"HOME"]) {
        [generator menuPress];
    } else if ([name isEqualToString:@"POWERBUTTON"] || [name isEqualToString:@"POWER"]) {
        [generator powerPress];
    } else if ([name isEqualToString:@"VOLUMEUP"]) {
        [generator volumeIncrementPress];
    } else if ([name isEqualToString:@"VOLUMEDOWN"]) {
        [generator volumeDecrementPress];
    } else {
        return luaL_error(L, "unsupported key: %s", key);
    }
    return 0;
}

static TouchGesture *CheckTouch(lua_State *L) {
    return static_cast<TouchGesture *>(luaL_checkudata(L, 1, "TVTouchGesture"));
}

static void SendRawTap(CGPoint point) {
    // The convenience -tap: path is ignored by some iOS 15 system permission
    // alerts and can destabilize the daemon on affected iPhone 6s/7 units.
    // TrollVNC pointer input uses explicit touch-down/lift-up events and works
    // on the same alerts, so expose that exact, proven sequence to Lua too.
    STHIDEventGenerator *generator = STHIDEventGenerator.sharedGenerator;
    [generator touchDownAtPoints:&point touchCount:1];
    SleepCancelable(90);
    [generator liftUpAtPoints:&point touchCount:1];
}

static int LuaTouchOn(lua_State *L) {
    double x = luaL_checknumber(L, 1);
    double y = luaL_checknumber(L, 2);
    auto *gesture = static_cast<TouchGesture *>(lua_newuserdata(L, sizeof(TouchGesture)));
    *gesture = {x, y, x, y, 0.30, false};
    luaL_getmetatable(L, "TVTouchGesture");
    lua_setmetatable(L, -2);
    return 1;
}

static int LuaTouchMove(lua_State *L) {
    TouchGesture *gesture = CheckTouch(L);
    gesture->x2 = luaL_checknumber(L, 2);
    gesture->y2 = luaL_checknumber(L, 3);
    gesture->moved = true;
    lua_settop(L, 1);
    return 1;
}

static int LuaTouchStepLen(lua_State *L) {
    (void)luaL_checknumber(L, 2);
    lua_settop(L, 1);
    return 1;
}

static int LuaTouchStepDelay(lua_State *L) {
    TouchGesture *gesture = CheckTouch(L);
    double delayMs = luaL_checknumber(L, 2);
    gesture->duration = std::max(0.05, std::min(2.0, delayMs * 0.05));
    lua_settop(L, 1);
    return 1;
}

static int LuaTouchMsleep(lua_State *L) {
    (void)CheckTouch(L);
    lua_Integer ms = luaL_checkinteger(L, 2);
    if (ms > 0) SleepCancelable(static_cast<unsigned long>(ms));
    lua_settop(L, 1);
    return 1;
}

static int LuaTouchOff(lua_State *L) {
    TouchGesture *gesture = CheckTouch(L);
    CGPoint start = ScriptPoint(gesture->x1, gesture->y1);
    CGPoint end = ScriptPoint(gesture->x2, gesture->y2);
    STHIDEventGenerator *generator = STHIDEventGenerator.sharedGenerator;
    if (gesture->moved) {
        [generator dragLinearWithStartPoint:start endPoint:end duration:gesture->duration];
    } else {
        SendRawTap(start);
    }
    lua_settop(L, 1);
    return 1;
}

static int LuaTouchTap(lua_State *L) {
    CGPoint point = ScriptPoint(luaL_checknumber(L, 1), luaL_checknumber(L, 2));
    SendRawTap(point);
    return 0;
}

static int LuaTouchLongPress(lua_State *L) {
    CGPoint point = ScriptPoint(luaL_checknumber(L, 1), luaL_checknumber(L, 2));
    (void)luaL_optinteger(L, 3, 2000);
    [STHIDEventGenerator.sharedGenerator longPress:point];
    return 0;
}

static int LuaTouchSwipe(lua_State *L) {
    CGPoint start = ScriptPoint(luaL_checknumber(L, 1), luaL_checknumber(L, 2));
    CGPoint end = ScriptPoint(luaL_checknumber(L, 3), luaL_checknumber(L, 4));
    double durationMs = luaL_optnumber(L, 5, 350.0);
    NSTimeInterval duration = MAX(0.05, MIN(3.0, durationMs / 1000.0));
    [STHIDEventGenerator.sharedGenerator dragLinearWithStartPoint:start
                                                         endPoint:end
                                                         duration:duration];
    return 0;
}

static void RegisterFunctions(lua_State *L) {
    luaL_newmetatable(L, "TVTouchGesture");
    lua_pushvalue(L, -1);
    lua_setfield(L, -2, "__index");
    const luaL_Reg touchMethods[] = {
        {"move", LuaTouchMove},
        {"step_len", LuaTouchStepLen},
        {"step_delay", LuaTouchStepDelay},
        {"msleep", LuaTouchMsleep},
        {"off", LuaTouchOff},
        {nullptr, nullptr},
    };
    luaL_setfuncs(L, touchMethods, 0);
    lua_pop(L, 1);

    lua_newtable(L);
    lua_pushcfunction(L, LuaSysMsleep);
    lua_setfield(L, -2, "msleep");
    lua_pushcfunction(L, LuaSysToast);
    lua_setfield(L, -2, "toast");
    lua_pushcfunction(L, LuaSysInputText);
    lua_setfield(L, -2, "input_text");
    lua_pushcfunction(L, LuaSysRootDir);
    lua_setfield(L, -2, "root_dir");
    lua_pushcfunction(L, LuaSysSetWallpaper);
    lua_setfield(L, -2, "set_wallpaper");
    lua_setglobal(L, "sys");

    lua_newtable(L);
    lua_pushcfunction(L, LuaKeyPress);
    lua_setfield(L, -2, "press");
    lua_setglobal(L, "key");

    lua_newtable(L);
    lua_pushcfunction(L, LuaScreenInit);
    lua_setfield(L, -2, "init");
    lua_pushcfunction(L, LuaScreenGetColor);
    lua_setfield(L, -2, "get_color");
    lua_pushcfunction(L, LuaScreenGetColor);
    lua_setfield(L, -2, "getColor");
    lua_pushcfunction(L, LuaScreenFindImage);
    lua_setfield(L, -2, "find_image");
    lua_pushcfunction(L, LuaScreenFindImage);
    lua_setfield(L, -2, "findImage");
    lua_pushcfunction(L, LuaScreenOCR);
    lua_setfield(L, -2, "ocr");
    lua_pushcfunction(L, LuaScreenOCR);
    lua_setfield(L, -2, "ocr_text");
    lua_setglobal(L, "screen");

    lua_newtable(L);
    lua_pushcfunction(L, LuaTouchOn);
    lua_setfield(L, -2, "on");
    lua_pushcfunction(L, LuaTouchTap);
    lua_setfield(L, -2, "tap");
    lua_pushcfunction(L, LuaTouchLongPress);
    lua_setfield(L, -2, "long_press");
    lua_pushcfunction(L, LuaTouchSwipe);
    lua_setfield(L, -2, "swipe");
    lua_setglobal(L, "touch");

    lua_pushcfunction(L, LuaLog);
    lua_setglobal(L, "nLog");

    lua_newtable(L);
    lua_pushcfunction(L, LuaClipboardGet);
    lua_setfield(L, -2, "get");
    lua_pushcfunction(L, LuaClipboardSet);
    lua_setfield(L, -2, "set");
    lua_pushcfunction(L, LuaClipboardClear);
    lua_setfield(L, -2, "clear");
    lua_setglobal(L, "clipboard");

    lua_newtable(L);
    lua_pushcfunction(L, LuaPointReport);
    lua_setfield(L, -2, "report");
    lua_setglobal(L, "point");

    lua_newtable(L);
    lua_pushcfunction(L, LuaAppRun);
    lua_setfield(L, -2, "run");
    lua_pushcfunction(L, LuaAppRun);
    lua_setfield(L, -2, "activate");
    lua_pushcfunction(L, LuaAppKill);
    lua_setfield(L, -2, "kill");
    lua_pushcfunction(L, LuaAppState);
    lua_setfield(L, -2, "state");
    lua_pushcfunction(L, LuaAppOpenURL);
    lua_setfield(L, -2, "open_url");
    lua_pushcfunction(L, LuaAppRunShortcut);
    lua_setfield(L, -2, "run_shortcut");
    lua_setglobal(L, "app");

    // Compatibility aliases for scripts originally written against the
    // AutoTouch-style names used by the JavaScript sources.
    auto Alias = [&](const char *tableName, const char *fieldName,
                     const char *globalName) {
        lua_getglobal(L, tableName);
        lua_getfield(L, -1, fieldName);
        lua_setglobal(L, globalName);
        lua_pop(L, 1);
    };
    Alias("app", "run", "appRun");
    Alias("app", "activate", "appActivate");
    Alias("app", "kill", "appKill");
    Alias("app", "state", "appState");
    Alias("app", "open_url", "openURL");
    Alias("app", "run_shortcut", "appRunShortcut");
    Alias("sys", "input_text", "inputText");
    Alias("sys", "root_dir", "rootDir");
    Alias("sys", "set_wallpaper", "setWallpaper");
    Alias("sys", "toast", "toast");
    Alias("clipboard", "get", "getClipboard");
    Alias("clipboard", "set", "setClipboard");
    Alias("clipboard", "clear", "clearClipboard");

    lua_newtable(L);
    lua_pushcfunction(L, LuaDeviceIsScreenOn);
    lua_setfield(L, -2, "is_screen_on");
    lua_pushcfunction(L, LuaDeviceWake);
    lua_setfield(L, -2, "wake");
    lua_pushcfunction(L, LuaDeviceSleep);
    lua_setfield(L, -2, "sleep");
    lua_setglobal(L, "device");

    lua_pushcfunction(L, LuaScreenGetColor);
    lua_setglobal(L, "getColor");
    lua_pushcfunction(L, LuaScreenFindImage);
    lua_setglobal(L, "findImage");
}

static std::string CheckSyntax(const std::string &script) {
    lua_State *L = luaL_newstate();
    if (!L) return "cannot create Lua state";
    int status = luaL_loadbuffer(L, script.data(), script.size(), "remote-script");
    std::string error;
    if (status != LUA_OK) error = lua_tostring(L, -1) ?: "syntax error";
    lua_close(L);
    return error;
}

static void StopScript() {
    std::lock_guard<std::mutex> lock(gScriptMutex);
    gCancel.store(true);
    if (gScriptThread.joinable()) gScriptThread.join();
    gRunning.store(false);
    std::lock_guard<std::mutex> statusLock(gStatusMutex);
    gStoppedByUser = true;
    gFinishedAt = [[NSDate date] timeIntervalSince1970];
}

struct StartResult {
    std::string runId;
    bool duplicate;
};

static StartResult StartScript(
    const std::string &script, const std::string &requestId) {
    std::lock_guard<std::mutex> spawnLock(gSpawnMutex);
    if (!requestId.empty()) {
        std::lock_guard<std::mutex> statusLock(gStatusMutex);
        for (const auto &entry : gRecentRequests) {
            if (entry.first == requestId) return {entry.second, true};
        }
    }
    StopScript();
    std::lock_guard<std::mutex> lock(gScriptMutex);
    gCancel.store(false);
    gRunning.store(true);
    std::string runId = NSUUID.UUID.UUIDString.UTF8String ?: "";
    {
        std::lock_guard<std::mutex> statusLock(gStatusMutex);
        gRunId = runId;
        gLastError.clear();
        gRecentLogs.clear();
        gStoppedByUser = false;
        gStartedAt = [[NSDate date] timeIntervalSince1970];
        gFinishedAt = 0;
        if (!requestId.empty()) {
            gRecentRequests.emplace_back(requestId, runId);
            if (gRecentRequests.size() > 100)
                gRecentRequests.erase(gRecentRequests.begin());
        }
    }
    gScriptThread = std::thread([script] {
        @autoreleasepool {
            lua_State *L = luaL_newstate();
            if (!L) {
                gRunning.store(false);
                return;
            }
            luaL_openlibs(L);
            RegisterFunctions(L);
            lua_sethook(L, LuaCancelHook, LUA_MASKCOUNT, 1000);
            int status = luaL_loadbuffer(L, script.data(), script.size(), "remote-script");
            if (status == LUA_OK) status = lua_pcall(L, 0, LUA_MULTRET, 0);
            if (status != LUA_OK && !gCancel.load()) {
                const char *message = lua_tostring(L, -1) ?: "unknown";
                NSLog(@"[LuaAgent] runtime error: %s", message);
                std::lock_guard<std::mutex> lock(gStatusMutex);
                gLastError = message;
            }
            lua_close(L);
            gRunning.store(false);
            std::lock_guard<std::mutex> lock(gStatusMutex);
            gFinishedAt = [[NSDate date] timeIntervalSince1970];
        }
    });
    return {runId, false};
}

static bool ReceiveLine(int fd, std::string &pending, std::string &line) {
    for (;;) {
        size_t newline = pending.find('\n');
        if (newline != std::string::npos) {
            line = pending.substr(0, newline);
            pending.erase(0, newline + 1);
            return true;
        }
        if (pending.size() > 512 * 1024) return false;
        char buffer[4096];
        ssize_t received = recv(fd, buffer, sizeof(buffer), 0);
        if (received <= 0) return false;
        pending.append(buffer, static_cast<size_t>(received));
    }
}

static bool DecodeBase64(const std::string &encoded, std::string &decoded) {
    NSString *text = [[NSString alloc] initWithBytes:encoded.data()
                                             length:encoded.size()
                                           encoding:NSASCIIStringEncoding];
    if (!text) return false;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:text options:0];
    if (!data) return false;
    decoded.assign(static_cast<const char *>(data.bytes), data.length);
    return true;
}

static std::string EncodeBase64(const std::string &value) {
    NSData *data = [NSData dataWithBytes:value.data() length:value.size()];
    NSString *encoded = [data base64EncodedStringWithOptions:0];
    return encoded.UTF8String ?: "";
}

static std::string RunPresenceCommand(const std::string &line) {
    if (line.rfind("HEALTH ", 0) == 0) {
        std::string requestId = line.substr(7);
        if (requestId.empty()) return "";
        std::string data = "{\"ok\":true,\"running\":" +
            std::string(gRunning.load() ? "true" : "false") +
            ",\"version\":\"" + std::string(kLuaAgentVersion) +
            "\",\"screen_off_keepalive\":" +
            (gPowerAssertionActive.load() ? "true" : "false") + "}";
        std::string response = ApiJson(0, "Operation succeed", data);
        return "RESULT " + requestId + " " + EncodeBase64(response) + "\n";
    }
    if (line.rfind("RUN ", 0) != 0) return "";
    size_t idEnd = line.find(' ', 4);
    if (idEnd == std::string::npos) return "";
    std::string requestId = line.substr(4, idEnd - 4);
    std::string script;
    std::string response;
    if (!DecodeBase64(line.substr(idEnd + 1), script)) {
        response = ApiJson(400, "Invalid command encoding");
    } else {
        std::string error = CheckSyntax(script);
        if (!error.empty()) {
            response = ApiJson(1, error);
        } else {
            StartResult result = StartScript(script, requestId);
            std::string data = "{\"run_id\":\"" + JsonEscape(result.runId) +
                "\",\"duplicate\":" + (result.duplicate ? "true" : "false") + "}";
            response = ApiJson(
                0, result.duplicate ? "Duplicate request ignored" : "Operation succeed",
                data);
        }
    }
    return "RESULT " + requestId + " " + EncodeBase64(response) + "\n";
}

static void RunControllerPresence() {
    @autoreleasepool {
        const char heartbeat[] = "LUAAGENT_PRESENCE_V1\n";
        for (;;) {
            sockaddr_in target{};
            bool hasTarget = false;
            {
                std::lock_guard<std::mutex> lock(gKeepAliveMutex);
                hasTarget = gHasKeepAliveTarget;
                if (hasTarget) target = gKeepAliveTarget;
            }
            if (!hasTarget) {
                usleep(1000 * 1000);
                continue;
            }

            target.sin_port = htons(46955);
            int fd = socket(AF_INET, SOCK_STREAM, 0);
            if (fd < 0) {
                usleep(2 * 1000 * 1000);
                continue;
            }
            int yes = 1;
            setsockopt(fd, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
#ifdef TCP_KEEPALIVE
            int keepIdle = 5;
            setsockopt(fd, IPPROTO_TCP, TCP_KEEPALIVE, &keepIdle, sizeof(keepIdle));
#endif
#ifdef TCP_KEEPINTVL
            int keepInterval = 2;
            setsockopt(fd, IPPROTO_TCP, TCP_KEEPINTVL,
                       &keepInterval, sizeof(keepInterval));
#endif
#ifdef TCP_KEEPCNT
            int keepCount = 3;
            setsockopt(fd, IPPROTO_TCP, TCP_KEEPCNT, &keepCount, sizeof(keepCount));
#endif
            timeval timeout{};
            timeout.tv_sec = 5;
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));

            if (connect(fd, reinterpret_cast<sockaddr *>(&target),
                        sizeof(target)) != 0) {
                close(fd);
                usleep(2 * 1000 * 1000);
                continue;
            }

            std::string pending;
            for (;;) {
                if (!SendAll(fd, heartbeat, sizeof(heartbeat) - 1)) break;
                bool acknowledged = false;
                while (!acknowledged) {
                    std::string line;
                    if (!ReceiveLine(fd, pending, line)) goto disconnected;
                    if (line == "CONTROLLER_ACK_V1") {
                        acknowledged = true;
                        continue;
                    }
                    std::string result = RunPresenceCommand(line);
                    if (!result.empty() &&
                        !SendAll(fd, result.data(), result.size()))
                        goto disconnected;
                }
                usleep(2 * 1000 * 1000);
            }
disconnected:
            close(fd);
            usleep(1000 * 1000);
        }
    }
}

struct HttpRequest {
    std::string method;
    std::string path;
    std::string body;
};

static std::string QueryValue(const std::string &target, const std::string &name) {
    size_t query = target.find('?');
    if (query == std::string::npos) return "";
    std::string key = name + "=";
    size_t begin = target.find(key, query + 1);
    if (begin == std::string::npos) return "";
    begin += key.size();
    size_t end = target.find('&', begin);
    return target.substr(begin, end == std::string::npos ? end : end - begin);
}

static bool ReceiveRequest(int fd, HttpRequest &request) {
    std::string bytes;
    char buffer[8192];
    size_t headerEnd = std::string::npos;
    while (bytes.size() < 5 * 1024 * 1024) {
        ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
        if (count <= 0) return false;
        bytes.append(buffer, static_cast<size_t>(count));
        headerEnd = bytes.find("\r\n\r\n");
        if (headerEnd != std::string::npos) break;
    }
    if (headerEnd == std::string::npos) return false;

    size_t firstEnd = bytes.find("\r\n");
    if (firstEnd == std::string::npos) return false;
    std::string first = bytes.substr(0, firstEnd);
    size_t p1 = first.find(' ');
    size_t p2 = first.find(' ', p1 + 1);
    if (p1 == std::string::npos || p2 == std::string::npos) return false;
    request.method = first.substr(0, p1);
    request.path = first.substr(p1 + 1, p2 - p1 - 1);

    size_t contentLength = 0;
    std::string headers = bytes.substr(firstEnd + 2, headerEnd - firstEnd - 2);
    std::string lowered = headers;
    for (char &c : lowered) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    size_t cl = lowered.find("content-length:");
    if (cl != std::string::npos) {
        size_t begin = cl + strlen("content-length:");
        while (begin < lowered.size() && lowered[begin] == ' ') begin++;
        contentLength = strtoul(lowered.c_str() + begin, nullptr, 10);
    }
    if (contentLength > 5 * 1024 * 1024) return false;
    size_t bodyOffset = headerEnd + 4;
    while (bytes.size() - bodyOffset < contentLength) {
        ssize_t count = recv(fd, buffer, sizeof(buffer), 0);
        if (count <= 0) return false;
        bytes.append(buffer, static_cast<size_t>(count));
    }
    request.body = bytes.substr(bodyOffset, contentLength);
    return true;
}

static void SendBytes(int fd, int status, const char *contentType,
                      const void *bytes, size_t length) {
    const char *reason = status == 200 ? "OK" : (status == 404 ? "Not Found" : "Bad Request");
    std::string headers = "HTTP/1.1 " + std::to_string(status) + " " + reason +
        "\r\nContent-Type: " + contentType +
        "\r\nAccess-Control-Allow-Origin: *"
        "\r\nConnection: close\r\nContent-Length: " + std::to_string(length) + "\r\n\r\n";
    size_t sent = 0;
    while (sent < headers.size()) {
        ssize_t count = send(fd, headers.data() + sent, headers.size() - sent, 0);
        if (count <= 0) break;
        sent += static_cast<size_t>(count);
    }
    sent = 0;
    const uint8_t *payload = static_cast<const uint8_t *>(bytes);
    while (sent < length) {
        ssize_t count = send(fd, payload + sent, length - sent, 0);
        if (count <= 0) break;
        sent += static_cast<size_t>(count);
    }
}

static void SendResponse(int fd, int status, const std::string &body) {
    SendBytes(fd, status, "application/json; charset=utf-8",
              body.data(), body.size());
}

static std::string StatusDataJson() {
    std::lock_guard<std::mutex> lock(gStatusMutex);
    std::string logs = "[";
    for (size_t i = 0; i < gRecentLogs.size(); i++) {
        if (i) logs += ",";
        logs += "\"" + JsonEscape(gRecentLogs[i]) + "\"";
    }
    logs += "]";
    return "{\"running\":" + std::string(gRunning.load() ? "true" : "false") +
        ",\"run_id\":\"" + JsonEscape(gRunId) +
        "\",\"stopped_by_user\":" + (gStoppedByUser ? "true" : "false") +
        ",\"last_error\":\"" + JsonEscape(gLastError) +
        "\",\"started_at\":" + std::to_string(gStartedAt) +
        ",\"finished_at\":" + std::to_string(gFinishedAt) +
        ",\"logs\":" + logs + "}";
}

static bool IsAllowedAssetName(const std::string &name) {
    if (name.empty() || name.size() > 96 || name.find('/') != std::string::npos ||
        name.find('\\') != std::string::npos)
        return false;
    auto allowed = [](unsigned char c) {
        return std::isalnum(c) || c == '_' || c == '-' || c == '.';
    };
    if (!std::all_of(name.begin(), name.end(),
                     [&](char c) { return allowed(static_cast<unsigned char>(c)); }))
        return false;
    std::string lower = name;
    for (char &c : lower) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return lower.ends_with(".png") || lower.ends_with(".jpg") || lower.ends_with(".jpeg");
}

static std::string UploadLuaAsset(const HttpRequest &request) {
    if (request.method != "POST") return ApiJson(405, "Asset upload requires POST");
    std::string name = QueryValue(request.path, "name");
    if (!IsAllowedAssetName(name)) return ApiJson(400, "Unsupported asset name");
    if (request.body.empty() || request.body.size() > 5 * 1024 * 1024)
        return ApiJson(400, "Asset size is invalid");
    NSString *directory = @"/var/mobile/Library/LuaAgent/codetiktok/images";
    NSError *directoryError = nil;
    [NSFileManager.defaultManager createDirectoryAtPath:directory
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:&directoryError];
    if (directoryError) return ApiJson(500, "Cannot create asset directory");
    NSString *path = [directory stringByAppendingPathComponent:
        [NSString stringWithUTF8String:name.c_str()]];
    NSData *data = [NSData dataWithBytes:request.body.data() length:request.body.size()];
    if (![data writeToFile:path options:NSDataWritingAtomic error:&directoryError] || directoryError)
        return ApiJson(500, "Cannot write asset");
    return ApiJson(0, "Asset uploaded");
}

static std::string DeviceInfoJson(uint16_t port) {
    UIDevice *device = UIDevice.currentDevice;
    std::string name = device.name.UTF8String ?: "iPhone";
    std::string version = device.systemVersion.UTF8String ?: "";
    std::string deviceId = device.identifierForVendor.UUIDString.UTF8String ?: "";
    std::string lastError;
    std::string runId;
    double startedAt;
    double finishedAt;
    bool stoppedByUser;
    bool screenOn = false;
    bool locked = false;
    std::string screenStateSource;
    bool screenOnKnown = ReadScreenOn(screenOn, &screenStateSource);
    bool lockedKnown = ReadScreenLocked(locked);
    long long displayBacklightLevel = -1;
    float sbsBacklightFactor = -1.0f;
    int fbsStatus = -1;
    int blankedNotifyStatus = -1;
    bool blankedNotifyScreenOn = false;
    uint64_t blankedNotifyState = 0;
    bool fbsKnown = ReadDisplayBacklightLevel(displayBacklightLevel, &fbsStatus);
    bool blankedNotifyKnown = ReadBlankedScreenNotification(
        blankedNotifyScreenOn, &blankedNotifyStatus, &blankedNotifyState);
    ReadBacklightFactor(sbsBacklightFactor);
    std::string frontmostApp = ReadFrontmostApplication();
    bool homeReadyKnown = screenOnKnown && lockedKnown;
    bool homeReady = homeReadyKnown && screenOn && !locked &&
        IsHomeFrontmostApplication(frontmostApp);
    {
        std::lock_guard<std::mutex> lock(gStatusMutex);
        lastError = gLastError;
        runId = gRunId;
        startedAt = gStartedAt;
        finishedAt = gFinishedAt;
        stoppedByUser = gStoppedByUser;
    }
    std::string data = "{\"devname\":\"" + JsonEscape(name) +
        "\",\"deviceid\":\"" + JsonEscape(deviceId) +
        "\",\"marketing_name\":\"" + JsonEscape(device.model.UTF8String ?: "iPhone") +
        "\",\"sysversion\":\"" + JsonEscape(version) +
        "\",\"tsversion\":\"" + std::string(kLuaAgentVersion) +
        "\",\"port\":" + std::to_string(port) +
        ",\"screen_off_keepalive\":" +
        (gPowerAssertionActive.load() ? "true" : "false") +
        ",\"screen_on\":" +
        (screenOnKnown ? (screenOn ? "true" : "false") : "null") +
        ",\"screen_state_source\":\"" + JsonEscape(screenStateSource) +
        "\",\"fbs_status\":" + std::to_string(fbsStatus) +
        ",\"fbs_backlight_known\":" + (fbsKnown ? "true" : "false") +
        ",\"display_backlight_level\":" + std::to_string(displayBacklightLevel) +
        ",\"sbs_backlight_factor\":" + std::to_string(sbsBacklightFactor) +
        ",\"blanked_notify_status\":" + std::to_string(blankedNotifyStatus) +
        ",\"blanked_notify_state\":" +
        (blankedNotifyKnown ? std::to_string(blankedNotifyState) : "null") +
        ",\"blanked_notify_screen_on\":" +
        (blankedNotifyKnown ? (blankedNotifyScreenOn ? "true" : "false") : "null") +
        ",\"locked\":" +
        (lockedKnown ? (locked ? "true" : "false") : "null") +
        ",\"frontmost_app\":\"" + JsonEscape(frontmostApp) +
        "\",\"home_ready\":" +
        (homeReadyKnown ? (homeReady ? "true" : "false") : "null") +
        ",\"is_running\":" + (gRunning.load() ? "true" : "false") +
        ",\"run_id\":\"" + JsonEscape(runId) +
        "\",\"started_at\":" + std::to_string(startedAt) +
        ",\"finished_at\":" + std::to_string(finishedAt) +
        ",\"stopped_by_user\":" + (stoppedByUser ? "true" : "false") +
        ",\"last_error\":\"" + JsonEscape(lastError) + "\"}";
    return ApiJson(0, "Operation succeed", data);
}

static bool ConfigureTrollStoreSilentInstall() {
    std::lock_guard<std::mutex> lock(gUpdateMutex);
    NSString *preferencesPath = @"/var/mobile/Library/Preferences/com.opa334.TrollStore.plist";

    // The Agent daemon runs as root while TrollStore reads preferences as the
    // mobile user. NSUserDefaults uses the caller's cfprefsd domain, so writing
    // this suite as root does not update the value TrollStore sees. Switch the
    // effective UID briefly to mobile (501), write and synchronize the exact
    // absolute suite used by TrollStore, then restore root before launching it.
    uid_t originalEuid = geteuid();
    bool changedUser = originalEuid == 0 && seteuid(501) == 0;
    if (originalEuid == 0 && !changedUser) return false;

    NSMutableDictionary *preferences =
        [NSMutableDictionary dictionaryWithContentsOfFile:preferencesPath];
    if (!preferences) preferences = [NSMutableDictionary dictionary];
    preferences[@"installAlertConfiguration"] = @2;
    BOOL wroteFile = [preferences writeToFile:preferencesPath atomically:YES];

    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:preferencesPath];
    [defaults setObject:@2 forKey:@"installAlertConfiguration"];
    BOOL synchronized = [defaults synchronize];
    usleep(150 * 1000);

    bool restoredUser = !changedUser || seteuid(originalEuid) == 0;
    return restoredUser && (wroteFile || synchronized);
}

static void StopRunningTrollStore() {
    Class serviceClass = NSClassFromString(@"FBSSystemService");
    SEL sharedSelector = NSSelectorFromString(@"sharedService");
    SEL terminateSelector = NSSelectorFromString(
        @"terminateApplication:forReason:andReport:withDescription:");
    if (!serviceClass || ![serviceClass respondsToSelector:sharedSelector]) return;
    id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, sharedSelector);
    if (!service || ![service respondsToSelector:terminateSelector]) return;
    ((void (*)(id, SEL, id, long long, BOOL, id))objc_msgSend)(
        service, terminateSelector, @"com.opa334.TrollStore", 1LL, NO,
        @"LuaAgent silent update");
    usleep(300 * 1000);
}

static std::string LaunchTrollStoreUpdate(
    const std::string &remoteUrl, const sockaddr_in &peer) {
    if (remoteUrl.empty() || remoteUrl.size() > 2048)
        return ApiJson(400, "Invalid update URL");

    NSString *remoteString = [NSString stringWithUTF8String:remoteUrl.c_str()];
    NSURLComponents *remote = [NSURLComponents componentsWithString:remoteString];
    NSString *scheme = remote.scheme.lowercaseString;
    if (!remote.URL || !([scheme isEqualToString:@"http"] ||
                         [scheme isEqualToString:@"https"])) {
        return ApiJson(400, "Update URL must use HTTP or HTTPS");
    }

    char peerText[INET_ADDRSTRLEN] = {};
    if (!inet_ntop(AF_INET, &peer.sin_addr, peerText, sizeof(peerText)) ||
        ![remote.host isEqualToString:[NSString stringWithUTF8String:peerText]]) {
        return ApiJson(403, "Update URL host must match Controller IP");
    }

    StopRunningTrollStore();
    // Best effort only. The Windows Controller clicks Install through VNC,
    // so an unavailable TrollStore preference must not block the update UI.
    (void)ConfigureTrollStoreSilentInstall();

    NSURLComponents *install = [[NSURLComponents alloc] init];
    install.scheme = @"apple-magnifier";
    install.host = @"install";
    install.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"url" value:remote.URL.absoluteString],
    ];
    if (!install.URL) return ApiJson(500, "Cannot create TrollStore URL");

    int result = SBSLaunchApplicationWithIdentifierAndURLAndLaunchOptions(
        CFSTR("com.opa334.TrollStore"), (__bridge CFURLRef)install.URL, NULL,
        (__bridge CFDictionaryRef)@{
            SBSApplicationLaunchOptionUnlockDeviceKey : @YES
        }, NO);
    if (result != 0) {
        return ApiJson(500, "Cannot launch TrollStore, code " + std::to_string(result));
    }
    return ApiJson(0, "TrollStore update started",
                   "{\"silent_install\":true,\"auto_restart\":false}");
}

static void HandleClient(int fd, uint16_t port, sockaddr_in peer) {
    HttpRequest request;
    if (!ReceiveRequest(fd, request)) {
        SendResponse(fd, 400, ApiJson(400, "Invalid HTTP request"));
        return;
    }
    std::string path = request.path.substr(0, request.path.find('?'));
    if (path == "/upload_asset") {
        std::string response = UploadLuaAsset(request);
        bool ok = response.find("\"code\":0") != std::string::npos;
        SendResponse(fd, ok ? 200 : 400, response);
    } else if (path == "/health") {
        std::string data = "{\"ok\":true,\"running\":" +
            std::string(gRunning.load() ? "true" : "false") +
            ",\"version\":\"" + std::string(kLuaAgentVersion) +
            "\",\"screen_off_keepalive\":" +
            (gPowerAssertionActive.load() ? "true" : "false") +
            ",\"silent_update\":true,"
            "\"auto_restart\":false}";
        SendResponse(fd, 200, ApiJson(0, "Operation succeed", data));
    } else if (path == "/deviceinfo") {
        SendResponse(fd, 200, DeviceInfoJson(port));
    } else if (path == "/snapshot") {
        NSData *jpeg = TVCreateFreshFrameJPEG(0.80, 2.0);
        if (!jpeg) {
            SendResponse(fd, 400, ApiJson(503, "Screen frame is not ready"));
        } else {
            SendBytes(fd, 200, "image/jpeg", jpeg.bytes, jpeg.length);
        }
    } else if (path == "/is_running") {
        SendResponse(fd, 200, ApiJson(0, "Operation succeed",
                                     gRunning.load() ? "true" : "false"));
    } else if (path == "/status" || path == "/logs") {
        SendResponse(fd, 200, ApiJson(0, "Operation succeed", StatusDataJson()));
    } else if (path == "/check_syntax") {
        std::string error = CheckSyntax(request.body);
        SendResponse(fd, 200, error.empty() ? ApiJson(0, "Operation succeed")
                                            : ApiJson(1, error));
    } else if (path == "/spawn") {
        std::string error = CheckSyntax(request.body);
        if (!error.empty()) {
            SendResponse(fd, 200, ApiJson(1, error));
        } else {
            StartResult result = StartScript(
                request.body, QueryValue(request.path, "request_id"));
            std::string data = "{\"run_id\":\"" + JsonEscape(result.runId) +
                "\",\"duplicate\":" + (result.duplicate ? "true" : "false") + "}";
            SendResponse(fd, 200, ApiJson(
                0, result.duplicate ? "Duplicate request ignored" : "Operation succeed",
                data));
        }
    } else if (path == "/recycle") {
        StopScript();
        [STHIDEventGenerator.sharedGenerator releaseEveryKeys];
        SendResponse(fd, 200, ApiJson(0, "Operation succeed"));
    } else if (path == "/install_update") {
        std::string response = LaunchTrollStoreUpdate(request.body, peer);
        bool ok = response.find("\"code\":0") != std::string::npos;
        SendResponse(fd, ok ? 200 : 400, response);
    } else if (path == "/restart_agent") {
        SendResponse(fd, 200, ApiJson(0, "Agent restart scheduled"));
        std::thread([] {
            usleep(750 * 1000);
            _exit(0);
        }).detach();
    } else {
        SendResponse(fd, 404, ApiJson(404, "Endpoint not found"));
    }
}

static void RunServer(uint16_t port) {
    @autoreleasepool {
        int server = socket(AF_INET, SOCK_STREAM, 0);
        if (server < 0) return;
        int yes = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        address.sin_port = htons(port);
        if (bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0 ||
            listen(server, 64) != 0) {
            NSLog(@"[LuaAgent] cannot listen on %u: %s", port, strerror(errno));
            close(server);
            return;
        }
        NSLog(@"[LuaAgent] listening on 0.0.0.0:%u", port);
        for (;;) {
            sockaddr_in peer{};
            socklen_t peerLength = sizeof(peer);
            int client = accept(
                server, reinterpret_cast<sockaddr *>(&peer), &peerLength);
            if (client < 0) continue;
            RememberControllerAddress(peer);
            if (gActiveClients.fetch_add(1) >= 32) {
                gActiveClients.fetch_sub(1);
                SendResponse(client, 503, ApiJson(503, "Server busy"));
                close(client);
                continue;
            }
            timeval timeout{};
            timeout.tv_sec = 12;
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
            setsockopt(client, SOL_SOCKET, SO_KEEPALIVE, &yes, sizeof(yes));
#ifdef SO_NOSIGPIPE
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
#endif
            std::thread([client, port, peer] {
                @autoreleasepool {
                    HandleClient(client, port, peer);
                    close(client);
                    gActiveClients.fetch_sub(1);
                }
            }).detach();
        }
    }
}

static std::string DiscoveryJson(uint16_t apiPort) {
    UIDevice *device = UIDevice.currentDevice;
    std::string name = device.name.UTF8String ?: "iPhone";
    std::string model = device.model.UTF8String ?: "iPhone";
    std::string version = device.systemVersion.UTF8String ?: "";
    return "{\"port\":" + std::to_string(apiPort) +
        ",\"devname\":\"" + JsonEscape(name) +
        "\",\"marketing_name\":\"" + JsonEscape(model) +
        "\",\"sysversion\":\"" + JsonEscape(version) +
        "\",\"tsversion\":\"" + std::string(kLuaAgentVersion) + "\"}";
}

static void RunDiscovery(uint16_t discoveryPort, uint16_t apiPort) {
    @autoreleasepool {
        int server = socket(AF_INET, SOCK_DGRAM, 0);
        if (server < 0) return;
        int yes = 1;
        setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
        sockaddr_in address{};
        address.sin_family = AF_INET;
        address.sin_addr.s_addr = htonl(INADDR_ANY);
        address.sin_port = htons(discoveryPort);
        if (bind(server, reinterpret_cast<sockaddr *>(&address), sizeof(address)) != 0) {
            NSLog(@"[LuaAgent] cannot listen for discovery on UDP %u: %s",
                  discoveryPort, strerror(errno));
            close(server);
            return;
        }
        NSLog(@"[LuaAgent] discovery listening on UDP 0.0.0.0:%u", discoveryPort);
        for (;;) {
            uint8_t requestBytes[1024];
            sockaddr_in sender{};
            socklen_t senderLength = sizeof(sender);
            ssize_t length = recvfrom(
                server, requestBytes, sizeof(requestBytes), 0,
                reinterpret_cast<sockaddr *>(&sender), &senderLength);
            if (length <= 0) continue;

            @autoreleasepool {
                RememberControllerAddress(sender);
                NSData *requestData = [NSData dataWithBytes:requestBytes
                                                    length:(NSUInteger)length];
                NSError *jsonError = nil;
                id object = [NSJSONSerialization JSONObjectWithData:requestData
                                                            options:0
                                                              error:&jsonError];
                if (jsonError || ![object isKindOfClass:[NSDictionary class]] ||
                    ![(NSDictionary *)object objectForKey:@"port"]) {
                    continue;
                }

                std::string response = DiscoveryJson(apiPort);
                sendto(server, response.data(), response.size(), 0,
                       reinterpret_cast<sockaddr *>(&sender), senderLength);
            }
        }
    }
}

}  // namespace

void TVStartLuaAutomationServer(uint16_t port) {
    bool expected = false;
    if (!gStarted.compare_exchange_strong(expected, true)) return;
    LoadRememberedControllerAddress();
    (void)AcquireNetworkPowerAssertions();
    std::thread([port] { RunServer(port); }).detach();
    std::thread([port] { RunDiscovery(46953, port); }).detach();
    std::thread([] { RunControllerKeepAlive(); }).detach();
    std::thread([] { RunControllerPresence(); }).detach();
    std::thread([] { RunPowerAssertionWatchdog(); }).detach();
}
