/*
 * Lua automation HTTP agent for TrollVNC.
 * Copyright (c) 2026 contributors.
 * Licensed under GPL-2.0 as part of TrollVNC.
 */

#import "LuaAutomationServer.h"
#import "STHIDEventGenerator.h"
#import "TVFrameSnapshot.h"

#import <UIKit/UIKit.h>
#import <Vision/Vision.h>

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>

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
}

namespace {

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
std::thread gScriptThread;
std::mutex gStatusMutex;
std::string gLastError;
std::vector<std::string> gRecentLogs;
double gStartedAt = 0;
double gFinishedAt = 0;

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

static std::string ApiJson(int code, const std::string &message, const std::string &data = "{}") {
    return "{\"code\":" + std::to_string(code) + ",\"message\":\"" + JsonEscape(message) +
           "\",\"data\":" + data + "}";
}

static CGPoint ScriptPoint(double x, double y) {
    UIScreen *screen = UIScreen.mainScreen;
    CGSize nativeSize = screen.nativeBounds.size;
    CGSize pointSize = screen.bounds.size;
    if (nativeSize.width <= 0 || nativeSize.height <= 0) {
        return CGPointMake(x, y);
    }
    return CGPointMake(x * pointSize.width / nativeSize.width,
                       y * pointSize.height / nativeSize.height);
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
    const char *pathCString = luaL_checkstring(L, 1);
    double similarity = luaL_optnumber(L, 2, 0.90);
    NSString *path = [[NSString stringWithUTF8String:pathCString] stringByExpandingTildeInPath];
    UIImage *needleImage = [UIImage imageWithContentsOfFile:path];
    int screenWidth = 0, screenHeight = 0;
    NSData *screen = TVCopyLatestFrameBGRA(&screenWidth, &screenHeight);
    int needleWidth = 0, needleHeight = 0;
    NSData *needle = needleImage ? CopyImageBGRA(needleImage, &needleWidth, &needleHeight) : nil;
    if (!screen || !needle || needleWidth <= 0 || needleHeight <= 0 ||
        needleWidth > screenWidth || needleHeight > screenHeight) {
        lua_pushinteger(L, -1);
        lua_pushinteger(L, -1);
        return 2;
    }

    const uint8_t *hay = static_cast<const uint8_t *>(screen.bytes);
    const uint8_t *pin = static_cast<const uint8_t *>(needle.bytes);
    int sampleX = MAX(1, needleWidth / 12);
    int sampleY = MAX(1, needleHeight / 12);
    double maxMeanDifference = (1.0 - MAX(0.0, MIN(1.0, similarity))) * 255.0;
    int foundX = -1, foundY = -1;
    for (int y = 0; y <= screenHeight - needleHeight && foundX < 0; y += 2) {
        for (int x = 0; x <= screenWidth - needleWidth; x += 2) {
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
    CGSize nativeSize = UIScreen.mainScreen.nativeBounds.size;
    lua_pushinteger(L, llround(foundX * nativeSize.width / screenWidth));
    lua_pushinteger(L, llround(foundY * nativeSize.height / screenHeight));
    return 2;
}

static int LuaScreenOCR(lua_State *L) {
    UIImage *image = TVCreateLatestFrameImage();
    if (!image.CGImage) {
        lua_pushnil(L);
        lua_pushstring(L, "screen frame is unavailable");
        return 2;
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
        [generator tap:start];
    }
    lua_settop(L, 1);
    return 1;
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
    lua_setglobal(L, "touch");

    lua_pushcfunction(L, LuaLog);
    lua_setglobal(L, "nLog");

    lua_newtable(L);
    lua_pushcfunction(L, LuaAppRun);
    lua_setfield(L, -2, "run");
    lua_setglobal(L, "app");

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
    gFinishedAt = [[NSDate date] timeIntervalSince1970];
}

static void StartScript(const std::string &script) {
    StopScript();
    std::lock_guard<std::mutex> lock(gScriptMutex);
    gCancel.store(false);
    gRunning.store(true);
    {
        std::lock_guard<std::mutex> statusLock(gStatusMutex);
        gLastError.clear();
        gRecentLogs.clear();
        gStartedAt = [[NSDate date] timeIntervalSince1970];
        gFinishedAt = 0;
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
}

struct HttpRequest {
    std::string method;
    std::string path;
    std::string body;
};

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
        ",\"last_error\":\"" + JsonEscape(gLastError) +
        "\",\"started_at\":" + std::to_string(gStartedAt) +
        ",\"finished_at\":" + std::to_string(gFinishedAt) +
        ",\"logs\":" + logs + "}";
}

static std::string DeviceInfoJson(uint16_t port) {
    UIDevice *device = UIDevice.currentDevice;
    std::string name = device.name.UTF8String ?: "iPhone";
    std::string version = device.systemVersion.UTF8String ?: "";
    std::string lastError;
    {
        std::lock_guard<std::mutex> lock(gStatusMutex);
        lastError = gLastError;
    }
    std::string data = "{\"devname\":\"" + JsonEscape(name) +
        "\",\"marketing_name\":\"" + JsonEscape(device.model.UTF8String ?: "iPhone") +
        "\",\"sysversion\":\"" + JsonEscape(version) +
        "\",\"tsversion\":\"LuaAgent 0.2\",\"port\":" + std::to_string(port) +
        ",\"is_running\":" + (gRunning.load() ? "true" : "false") +
        ",\"last_error\":\"" + JsonEscape(lastError) + "\"}";
    return ApiJson(0, "Operation succeed", data);
}

static void HandleClient(int fd, uint16_t port) {
    HttpRequest request;
    if (!ReceiveRequest(fd, request)) {
        SendResponse(fd, 400, ApiJson(400, "Invalid HTTP request"));
        return;
    }
    std::string path = request.path.substr(0, request.path.find('?'));
    if (path == "/health") {
        std::string data = "{\"ok\":true,\"running\":" +
            std::string(gRunning.load() ? "true" : "false") +
            ",\"version\":\"LuaAgent 0.2\"}";
        SendResponse(fd, 200, ApiJson(0, "Operation succeed", data));
    } else if (path == "/deviceinfo") {
        SendResponse(fd, 200, DeviceInfoJson(port));
    } else if (path == "/snapshot") {
        NSData *jpeg = TVCreateLatestFrameJPEG(0.80);
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
            StartScript(request.body);
            SendResponse(fd, 200, ApiJson(0, "Operation succeed"));
        }
    } else if (path == "/recycle") {
        StopScript();
        [STHIDEventGenerator.sharedGenerator releaseEveryKeys];
        SendResponse(fd, 200, ApiJson(0, "Operation succeed"));
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
            int client = accept(server, nullptr, nullptr);
            if (client < 0) continue;
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
            std::thread([client, port] {
                @autoreleasepool {
                    HandleClient(client, port);
                    close(client);
                    gActiveClients.fetch_sub(1);
                }
            }).detach();
        }
    }
}

}  // namespace

void TVStartLuaAutomationServer(uint16_t port) {
    bool expected = false;
    if (!gStarted.compare_exchange_strong(expected, true)) return;
    std::thread([port] { RunServer(port); }).detach();
}
