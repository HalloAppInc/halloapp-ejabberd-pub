%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% HTTP API for to redirect export request to S3
%%% @end
%%% Created : 16. Jun 2021 11:42 AM
%%%-------------------------------------------------------------------
% TODO: since this in no longer gen_mod does it have to start with mod_?
-module(mod_http_export).
-author("nikola").

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").

%% API
-export([process/2]).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /export
process([Token],
        #request{method = 'GET', ip = {NetIP, _Port}, headers = Headers} = _R) ->
    try
        IP = util_http:get_ip(NetIP, Headers),
        Location = get_s3_url(Token),
        ?INFO("redirecting ~ts ip:~p to ~ts", [Token, IP, Location]),
        {302, [?LOCATION_HEADER(Location)], <<"">>}
    catch
        error : Reason : Stacktrace ->
            ?ERROR("error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end;

process(Path, Request) ->
    ?INFO("404 Not Found path: ~p, r:~p", [Path, Request]),
    util_http:return_404().

get_s3_url(Token) ->
    Bucket = list_to_binary(mod_export:export_bucket()),
    <<"https://", Bucket/binary, ".s3.amazonaws.com/", Token/binary>>.
