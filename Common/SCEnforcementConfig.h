//  SCEnforcementConfig.h
//  Compile-time enforcement tuning. Deliberately NOT user-editable (commitment
//  device: same reasoning as SCTediumConfig.h).
#ifndef SCEnforcementConfig_h
#define SCEnforcementConfig_h

// When the daemon finds block rules installed but cannot determine an end date
// (tampered/corrupt state), it heals the block to verified-now + this many
// seconds. Default: one day.
#define SC_SELFHEAL_BLOCK_SECS (86400.0)

#endif /* SCEnforcementConfig_h */
