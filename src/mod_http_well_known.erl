%%%-------------------------------------------------------------------
%%% @author nikola
%%% @copyright (C) 2021, HalloApp, Inc.
%%% @doc
%%% HTTP API for well-known files https://en.wikipedia.org/wiki/List_of_/.well-known/_services_offered_by_webservers
%%% @end
%%% Created : 13. Apr 2021 11:42 AM
%%%-------------------------------------------------------------------
-module(mod_http_well_known).
-author("nikola").
-behaviour(gen_mod).

-include("logger.hrl").
-include("ejabberd_http.hrl").
-include("util_http.hrl").

%% API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([process/2]).

-define(APPLE_APP_SITE_ASSOCIATION, <<"apple-app-site-association">>).
-define(ASSET_LINKS, <<"assetlinks.json">>).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

%TODO: we can make this more generic and just statically server any file from a folder.
-spec process(Path :: http_path(), Request :: http_request()) -> http_response().
%% /.well-known
process([FileBin], #request{method = 'GET'} = _R)
        when FileBin =:= ?APPLE_APP_SITE_ASSOCIATION orelse FileBin =:= ?ASSET_LINKS->
    try
        FileName = filename:join(misc:data_dir(), FileBin),
        {200, [?CT_JSON], {file, FileName}}
    catch
        error : Reason : Stacktrace ->
            ?ERROR("logs unknown error: Stacktrace:~s",
                [lager:pr_stacktrace(Stacktrace, {error, Reason})]),
            util_http:return_500()
    end;

process(Path, Request) ->
    ?INFO("404: Not Found path: ~p, r:~p", [Path, Request]),
    util_http:return_404().


start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].
