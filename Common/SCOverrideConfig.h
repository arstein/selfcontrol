#ifndef SCOverrideConfig_h
#define SCOverrideConfig_h

// Default override policy, used to seed a new block's OverridePolicy.
#define SC_OVERRIDE_DEFAULT_PER_DAY  (3)
#define SC_OVERRIDE_DEFAULT_MINUTES  (15)

// Hard ceiling on how far in the future a stored overrideEndDate may sit and
// still be honored, as defense-in-depth against a corrupt/oversized value.
// Legitimate overrides are minutes; this bound never limits real usage.
#define SC_OVERRIDE_MAX_LIFT_SECS  (2 * 60 * 60.0)

#endif /* SCOverrideConfig_h */
