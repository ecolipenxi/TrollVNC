/*
 * Lua automation HTTP agent for TrollVNC.
 * Copyright (c) 2026 contributors.
 * Licensed under GPL-2.0 as part of TrollVNC.
 */

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Starts the LAN-only Lua automation API. Calling this more than once is harmless.
void TVStartLuaAutomationServer(uint16_t port);

NS_ASSUME_NONNULL_END
