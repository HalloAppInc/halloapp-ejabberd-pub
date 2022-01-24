-author('murali').

-ifndef(CONTACTS_HRL).
-define(CONTACTS_HRL, 1).

-include("ha_types.hrl").
-include("time.hrl").

-define(SQUEEZE_LENGTH_BITS, 5).
-define(STORE_HASH_LENGTH_BYTES, 8).
-define(DUMMY_SALT, <<"y2c8wq3bvMIQNLlghqsXAS7bwEetE0Q=">>).
-define(SYNC_KEY_TTL, 31*?DAYS).

-define(MAX_JITTER_VALUE, 2 * ?HOURS).
-define(DEFAULT_SYNC_RETRY_TIME, 1 * ?DAYS).
-define(CONTACT_OPTIONS_TABLE, contact_options).
-define(SALT_LENGTH_BYTES, 32).
-define(PROBE_HASH_LENGTH_BYTES, 2).
-define(MAX_INVITERS, 3).
-define(NOTIFICATION_EXPIRY_MS, 1 * ?WEEKS_MS).
-define(MAX_CONTACTS, 32000).

-endif.
