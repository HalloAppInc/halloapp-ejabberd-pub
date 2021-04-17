%%%----------------------------------------------------------------------------
%%% Records for athena queries.
%%%
%%%----------------------------------------------------------------------------

-record(athena_query, {
    query_bin :: binary(),
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

