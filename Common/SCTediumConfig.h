// SCTediumConfig.h — compile-time knobs for the tedium override (see
// docs/superpowers/specs/2026-09-28-tedium-override-design.md in the vault).
#ifndef SCTediumConfig_h
#define SCTediumConfig_h

// ⚠️ TESTING VALUE. Raise to ~300 before relying on this as a deterrent.
#define SC_TEDIUM_REQUIRED_ENTRIES 10

// Wrong digit: progress = MAX(0, progress - penalty)
#define SC_TEDIUM_WRONG_ENTRY_PENALTY 20

// Entries arriving sooner than this after the last counted entry are ignored
// (no penalty, same digit). Monotonic. Guarantees >= N seconds total.
#define SC_TEDIUM_MIN_ENTRY_INTERVAL_SECS 1.0

// No counted entry for this long => progress resets to 0 (one continuous session).
#define SC_TEDIUM_IDLE_EXPIRY_SECS 600.0

#endif
