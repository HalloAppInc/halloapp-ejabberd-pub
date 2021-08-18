%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2021, <COMPANY>
%%% @doc
%%%
%%% @end
%%% Created : 02. Aug 2021 3:00 PM
%%%-------------------------------------------------------------------
-author("josh").

-define(TABLES, [
    ?IP_TABLE,
    ?SECRETS_TABLE
]).

-define(SECRETS_TABLE, aws_secrets).
-define(DUMMY_SECRET, <<"dummy_secret">>).

-define(IP_TABLE, aws_ips).
-define(LOCALHOST_IPS, [{"localhost", "127.0.0.1"}]).
