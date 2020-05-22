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

%% RedisAuth
-define(PASSWORD_KEY, <<"pas:">>).

%% RedisContacts
-define(CONTACTS_KEY, <<"con:">>).
-define(SYNC_KEY, <<"sync:">>).
-define(REVERSE_KEY, <<"rev:">>).

%% RedisAccounts (model_friends)
-define(FRIENDS_KEY, <<"fr:">>).

%% RedisMessages
-define(MESSAGE_KEY, <<"msg:">>).
-define(MESSAGE_QUEUE_KEY, <<"mq:">>).
-define(MESSAGE_ORDER_KEY, <<"ord:">>).

%% RedisPhone
-define(PHONE_KEY, <<"pho:">>).
-define(CODE_KEY, <<"cod:">>).

%% RedisWhisperKeys
-define(WHISPER_KEY, <<"wk:">>).
-define(OTP_KEY, <<"wotp:">>).
-define(SUBSCRIBERS_KEY, <<"wsub:">>).
