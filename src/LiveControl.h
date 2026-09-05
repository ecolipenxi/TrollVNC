// GPL-2.0, part of the LuaAgent/TrollVNC integration.
#import <Foundation/Foundation.h>

void TVStartLiveControlServer(uint16_t port);
bool TVAcquireLiveInput();
void TVReleaseLiveInput();
bool TVExternalInputBlocked();
NSString *TVLiveDeviceIdentifier();
NSDictionary *TVLiveDisplayInfo();
bool TVLiveApplyEvent(NSDictionary *event);
void TVLiveResetInput();
