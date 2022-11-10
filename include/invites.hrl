-ifndef(INVITES_HRL).

-define(INVITES_HRL, 1).
-define(MAX_NUM_INVITES, 5).
% Controls if registrations are allowed without invite and the number of invites a user gets
-define(IS_INVITE_REQUIRED, false).
-define(INF_INVITES, 10000).

-define(INVITE_STRING_ID_SHA_HASH_LENGTH_BYTES, 16).

-define(INVITE_STRINGS_TABLE, invite_strings).
-define(INVITE_STRINGS_ETS_KEY, invite_strings_map).

-define(PRE_INVITE_STRINGS_TABLE, pre_invite_strings).
-define(PRE_INVITE_STRINGS_ETS_KEY, pre_invite_strings_map).

-endif.
