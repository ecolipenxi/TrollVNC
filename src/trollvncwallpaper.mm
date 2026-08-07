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
#include <objc/runtime.h>
#include <string>

using WallpaperSetImagesFn = int (*)(NSDictionary *, NSDictionary *, int, int);

static bool SetIntegerOption(id object, SEL selector, NSInteger value) {
    NSMethodSignature *signature = [object methodSignatureForSelector:selector];
    if (!signature) return false;
    NSInvocation *invocation = [NSInvocation invocationWithMethodSignature:signature];
    [invocation setTarget:object];
    [invocation setSelector:selector];
    [invocation setArgument:&value atIndex:2];
    [invocation invoke];
    return true;
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

        // SpringBoardUIServices expects SBFWallpaperOptions to be created
        // after SpringBoardFoundation is loaded.  This is the proven iOS
        // 13-15 call sequence; it must stay in this isolated helper because
        // the private service can abort its caller on some iOS 15 builds.
        dlopen("/System/Library/PrivateFrameworks/SpringBoardFoundation.framework/"
               "SpringBoardFoundation", RTLD_LAZY | RTLD_LOCAL);
        void *services = dlopen(
            "/System/Library/PrivateFrameworks/SpringBoardUIServices.framework/"
            "SpringBoardUIServices", RTLD_LAZY | RTLD_LOCAL);
        if (!services) return 68;
        auto setter = reinterpret_cast<WallpaperSetImagesFn>(dlsym(
            services, "SBSUIWallpaperSetImages"));
        if (!setter) return 69;

        Class optionsClass = objc_getClass("SBFWallpaperOptions");
        if (!optionsClass) return 70;
        id lightOptions = [[optionsClass alloc] init];
        id darkOptions = [[optionsClass alloc] init];
        if (!lightOptions || !darkOptions) return 71;
        SetIntegerOption(lightOptions, @selector(setParallaxFactor:), 0);
        SetIntegerOption(darkOptions, @selector(setParallaxFactor:), 0);
        SetIntegerOption(lightOptions, @selector(setWallpaperMode:), 1);
        SetIntegerOption(darkOptions, @selector(setWallpaperMode:), 2);

        NSDictionary *images = @{
            @"light": image,
            @"dark": image,
        };
        NSDictionary *options = @{
            @"light": lightOptions,
            @"dark": darkOptions,
        };
        (void)setter(images, options, static_cast<int>(locationValue), 2);
        return 0;
    }
}
