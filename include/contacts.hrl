-author('murali').

-ifndef(CONTACTS_HRL).
-define(CONTACTS_HRL, 1).

-include("ha_types.hrl").
-include("time.hrl").

-define(SQUEEZE_LENGTH_BITS, 5).
-define(STORE_HASH_LENGTH_BYTES, 8).
-define(DUMMY_SALT, <<"y2c8wq3bvMIQNLlghqsXAS7bwEetE0Q=">>).
-define(SYNC_KEY_TTL, 31*?DAYS).

-endif.
