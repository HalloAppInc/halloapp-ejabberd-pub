%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2021, Halloapp Inc.
%%%-------------------------------------------------------------------
-module(mod_geodb).
-author("vipin").
-behaviour(gen_mod).

-include("logger.hrl").

-define(GEOLIST_DB, "GeoLite2-Country.mmdb").

%% API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).
-export([
    lookup/1
]).


-spec lookup(IP :: binary() | string()) -> binary().
lookup(IP) ->
    try
        Result = locus:lookup(geodb, IP),
        case Result of
            {ok, Entry} ->
                maps:get(<<"iso_code">>, maps:get(<<"country">>, Entry, #{}), <<"ZZ">>);
            not_found ->
                <<"ZZ">>;
            {error, Error} ->
                ?ERROR("IP: ~s Error: ~p", [IP, Error]),
                <<"ZZ">>
        end
    catch
        Class:Reason:Stacktrace ->
            ?ERROR("Stacktrace: ~p", [lager:pr_stacktrace(Stacktrace, {Class, Reason})]),
            <<"ZZ">>
    end.


-spec full_path() -> file:filename().
full_path() ->
    filename:join(misc:data_dir(), ?GEOLIST_DB).

start(_Host, Opts) ->
    ?INFO("start ~w ~p", [?MODULE, Opts]),
    StartTime = util:now_ms(),
    ok = case locus:start_loader(geodb, full_path()) of
        ok -> ok;
        {error, already_started} -> ok;
        Any -> Any
    end,
    {ok, _DatabaseVersion} = locus:await_loader(geodb),
    EndTime = util:now_ms(),
    ?INFO("Time taken to load geodb: ~pms", [EndTime - StartTime]),
    ok.

stop(_Host) ->
    ?INFO("stop ~w", [?MODULE]),
    locus:stop_loader(geodb),
    ok.

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

depends(_Host, _Opts) ->
    [].

-spec mod_options(binary()) -> [{atom(), term()}].
mod_options(_Host) ->
    [].

