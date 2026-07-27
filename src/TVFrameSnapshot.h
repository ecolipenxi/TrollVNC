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

/// Starts capture on demand, waits for a fresh frame, and returns it as JPEG.
/// When there are no VNC clients, capture is stopped again before returning.
NSData *_Nullable TVCreateFreshFrameJPEG(CGFloat quality, NSTimeInterval timeout);

NS_ASSUME_NONNULL_END
