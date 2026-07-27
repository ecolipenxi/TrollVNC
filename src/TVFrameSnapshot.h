/*
 * Shared framebuffer snapshot helpers.
 * Licensed under GPL-2.0 as part of TrollVNC.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Returns a tightly packed BGRA copy of the latest VNC framebuffer.
NSData *_Nullable TVCopyLatestFrameBGRA(int *_Nullable width, int *_Nullable height);

/// Returns the latest framebuffer as a UIImage.
UIImage *_Nullable TVCreateLatestFrameImage(void);

/// Returns the latest framebuffer encoded as JPEG.
NSData *_Nullable TVCreateLatestFrameJPEG(CGFloat quality);

NS_ASSUME_NONNULL_END
