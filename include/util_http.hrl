%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2020, Halloapp Inc.
%%% @doc
%%%  HTTP utility header
%%% @end
%%% Created : 16. Oct 2020 2:22 PM
%%%-------------------------------------------------------------------
-ifndef(UTIL_HTTP_HRL).
-define(UTIL_HTTP_HRL, 1).

-define(CT_HTML,
    {<<"Content-Type">>, <<"text/html; charset=utf-8">>}).

-define(CT_XML,
    {<<"Content-Type">>, <<"text/xml; charset=utf-8">>}).

-define(CT_PLAIN,
    {<<"Content-Type">>, <<"text/plain">>}).

-define(CT_JSON,
    {<<"Content-Type">>, <<"application/json">>}).

-define(CT_BIN,
    {<<"Content-Type">>, <<"application/octet-stream">>}).

-define(CT_JPG,
    {<<"Content-Type">>, <<"image/jpeg">>}).

-define(AC_ALLOW_ORIGIN,
    {<<"Access-Control-Allow-Origin">>, <<"*">>}).

-define(AC_ALLOW_METHODS,
    {<<"Access-Control-Allow-Methods">>, <<"GET, POST, OPTIONS">>}).

-define(AC_ALLOW_HEADERS,
    {<<"Access-Control-Allow-Headers">>, <<"Content-Type">>}).

-define(AC_MAX_AGE,
    {<<"Access-Control-Max-Age">>, <<"86400">>}).

-define(OPTIONS_HEADER, [
    ?CT_PLAIN, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_METHODS,
    ?AC_ALLOW_HEADERS, ?AC_MAX_AGE]).

-define(HEADER(CType),
    [CType, ?AC_ALLOW_ORIGIN, ?AC_ALLOW_HEADERS]).

-define(LOCATION_HEADER(Location),
    {<<"Location">>, Location}).

-type http_response_code() :: integer().
-type http_header() :: {binary(), binary()}.
-type http_headers() :: [http_header()].
-type http_body() :: binary().
-type http_response() :: {http_response_code(), http_headers(), http_body()}.
-type http_path() :: [binary()].


-endif.
