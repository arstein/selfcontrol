#ifndef SCDeepBlockConfig_h
#define SCDeepBlockConfig_h

// Deep block length bounds, in seconds (5 minutes to 4 hours).
#define SC_DEEP_MIN_SECS 300
#define SC_DEEP_MAX_SECS 14400
// A tamper-recovered deep block heals to the maximum length (fail-closed).
#define SC_DEEP_HEAL_SECS SC_DEEP_MAX_SECS

#endif /* SCDeepBlockConfig_h */
