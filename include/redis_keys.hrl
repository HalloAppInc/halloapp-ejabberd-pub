%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%% When adding new top level key, make sure it is not used in another
%%% place by searching in this file. This will allow us to run against
%%% single testing redis cluster
%%% @end
%%% Created : 22. May 2020 3:23 PM
%%%-------------------------------------------------------------------
-author("nikola").

%% RedisAccounts (model_accounts)
-define(ACCOUNT_KEY, <<"acc:">>).
-define(DELETED_ACCOUNT_KEY, <<"dac:">>).
-define(SUBSCRIBE_KEY, <<"sub:">>).
-define(BROADCAST_KEY, <<"bro:">>).
-define(COUNT_REGISTRATIONS_KEY, <<"c_reg:">>).
-define(COUNT_ACCOUNTS_KEY, <<"c_acc:">>).
%% set -> {uid}
-define(TRACED_UIDS_KEY, <<"traced_uids:">>).
%% set -> {phone}
-define(TRACED_PHONES_KEY, <<"traced_phones:">>).
%% store for each phone the last person to invite this phone number and timestamp
-define(INVITES_KEY, <<"inv:">>).
-define(ACTIVE_USERS_ALL_KEY, <<"active_users_all:">>).
-define(ACTIVE_USERS_IOS_KEY, <<"active_users_ios:">>).
-define(ACTIVE_USERS_ANDROID_KEY, <<"active_users_android:">>).

%%RedisFeed (model_feed)
-define(POST_KEY, <<"fp:">>).
-define(POST_AUDIENCE_KEY, <<"fpa:">>).
-define(POST_COMMENTS_KEY, <<"fpc:">>).
-define(COMMENT_KEY, <<"fc:">>).
-define(REVERSE_POST_KEY, <<"rfp:">>).
-define(COMMENT_PUSH_LIST_KEY, <<"fcp:">>).

%% PrivacyKeys
-define(WHITELIST_KEY, <<"whi:">>).
-define(ONLY_KEY, <<"onl:">>).
-define(BLACKLIST_KEY, <<"bla:">>).
-define(EXCEPT_KEY, <<"exc:">>).
-define(MUTE_KEY, <<"mut:">>).
-define(BLOCK_KEY, <<"blo:">>).
-define(REVERSE_BLOCK_KEY, <<"rbl:">>).

%% RedisAuth
-define(PASSWORD_KEY, <<"pas:">>).
-define(SPUB_KEY, <<"spb:">>).

%% RedisContacts
-define(CONTACTS_KEY, <<"con:">>).
-define(SYNC_KEY, <<"sync:">>).
-define(REVERSE_KEY, <<"rev:">>).
-define(PHONE_HASH_KEY, <<"rph:">>).

%% RedisAccounts (model_friends)
-define(FRIENDS_KEY, <<"fr:">>).

%% RedisMessages
-define(MESSAGE_KEY, <<"msg:">>).
-define(MESSAGE_QUEUE_KEY, <<"mq:">>).
-define(MESSAGE_ORDER_KEY, <<"ord:">>).

%% RedisPhone
-define(PHONE_KEY, <<"pho:">>).
-define(CODE_KEY, <<"cod:">>).
-define(INVITED_BY_KEY, <<"inb:">>).


%% RedisWhisperKeys
-define(WHISPER_KEY, <<"wk:">>).
-define(OTP_KEY, <<"wotp:">>).
-define(SUBSCRIBERS_KEY, <<"wsub:">>).

%% RedisGroups
-define(GROUP_KEY, <<"g:">>).
-define(GROUP_MEMBERS_KEY, <<"gm:">>).
-define(USER_GROUPS_KEY, <<"ug:">>).
-define(COUNT_GROUPS_KEY, <<"c_grp:">>).

