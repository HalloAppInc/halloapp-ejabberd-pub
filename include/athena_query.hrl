%%%----------------------------------------------------------------------------
%%% Records for athena queries.
%%%
%%%----------------------------------------------------------------------------

-ifndef(ATHENA_QUERY_HRL).
-define(ATHENA_QUERY_HRL, 1).

-include("ha_types.hrl").

-record(athena_query, {
    query_bin :: binary(),
    exec_id :: maybe(binary()),
    query_token :: binary(),
    result_token :: binary(),
    tags :: map(),
    result_fun :: {atom(), atom()}, %% {Module, Function} - argument will always be #athena_query{}.
    result :: list(),
    metrics :: list()
}).

-type athena_query() :: #athena_query{}.

-define(IOS, <<"ios">>).
-define(ANDROID, <<"android">>).
-define(ATHENA_DB, <<"default">>).
-define(ATHENA_RESULT_S3_BUCKET, <<"s3://ha-athena-results">>).
% maximum number of times that processing a given query will be attempted -- queries are checked 
% every 10 seconds, so this will try them for 5 minutes before giving up
-define(MAX_PROCESS_QUERY_RETRIES, 30). 

-endif.
