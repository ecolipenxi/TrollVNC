/*
 * Isolated wallpaper setter for TrollVNC.
 *
 * SpringBoard's private wallpaper service is not safe to call from the
 * long-running VNC/Lua daemon on some iOS 15 builds.  This tiny helper is
 * deliberately a separate process: a bad private-framework call can only
 * terminate this helper, never the Agent that owns the VNC connection.
 */

#import <UIKit/UIKit.h>

#include <cerrno>
#include <cstdlib>
#include <dlfcn.h>
#include <string>

using WallpaperSetImageForLocationsFn = CFStringRef (*)(CGImageRef, NSInteger);

static WallpaperSetImageForLocationsFn FindWallpaperSetter() {
    const char *frameworks[] = {
        "/System/Library/PrivateFrameworks/SpringBoardUIServices.framework/"
        "SpringBoardUIServices",
        "/System/Library/PrivateFrameworks/SpringBoardUI.framework/SpringBoardUI",
    };
    for (const char *framework : frameworks) {
        void *handle = dlopen(framework, RTLD_LAZY | RTLD_LOCAL);
        if (!handle) continue;
        auto setter = reinterpret_cast<WallpaperSetImageForLocationsFn>(dlsym(
            handle, "SBSUIWallpaperSetImageAsWallpaperForLocations"));
        if (setter) return setter;
    }
    return nullptr;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 3) return 64;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        if (!path) return 65;
        char *end = nullptr;
        long locationValue = std::strtol(argv[2], &end, 10);
        if (!end || *end != '\0' || locationValue < 1 || locationValue > 3)
            return 66;

        UIImage *image = [UIImage imageWithContentsOfFile:
            path.stringByStandardizingPath];
        if (!image || !image.CGImage) return 67;

        WallpaperSetImageForLocationsFn setter = FindWallpaperSetter();
        if (!setter) return 68;

        // This call is the only operation in the helper.  If SpringBoard
        // rejects or crashes on a particular iOS build, the parent Agent is
        // still alive and can return a useful error to Controller.
        CFStringRef result = setter(image.CGImage,
                                    static_cast<NSInteger>(locationValue));
        return result ? 0 : 69;
    }
}
