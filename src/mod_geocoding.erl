%%%-------------------------------------------------------------------
%%% @author josh
%%% @copyright (C) 2023, HalloApp, Inc.
%%% @doc
%%%
%%% @end
%%%-------------------------------------------------------------------
-module(mod_geocoding).
-author("josh").

-behavior(gen_mod).
-behavior(gen_server).

-include("ha_types.hrl").
-include("logger.hrl").
-include("proc.hrl").
-include("server.hrl").

%% gen_mod API
-export([start/2, stop/1, reload/3, depends/2, mod_options/1]).

%% gen_server API
-export([init/1, terminate/2, handle_cast/2, handle_call/3, handle_info/2, code_change/3]).

%% API
-export([
    process_local_iq/1
]).

%%====================================================================
%% IQ handlers
%%====================================================================

process_local_iq(#pb_iq{payload = #pb_reverse_geocode_request{location = #pb_gps_location{
        latitude = Latitude, longitude = Longitude}}} = IQ) when Latitude > 90 orelse Latitude < -90
        orelse Longitude > 180 orelse Latitude < -180 ->
    %% Lat/Long out of range
    pb:make_iq_result(IQ, #pb_reverse_geocode_result{result = fail, reason = invalid_lat_long});

process_local_iq(#pb_iq{from_uid = Uid, payload = #pb_reverse_geocode_request{location = #pb_gps_location{
        latitude = Latitude, longitude = Longitude}}} = IQ) ->
    ?INFO("~s requesting reverse geocode lookup for ~f, ~f", [Uid, Latitude, Longitude]),
    gen_server:cast(?PROC(), {reverse_geocode_lookup, Uid, Latitude, Longitude, IQ, self()}),
    ignore.

%%====================================================================
%% gen_mod functions
%%====================================================================

start(Host, Opts) ->
    ?INFO("Start: ~w", [?MODULE]),
    gen_mod:start_child(?MODULE, Host, Opts, ?PROC()),
    gen_iq_handler:add_iq_handler(ejabberd_local, ?HALLOAPP, pb_reverse_geocode_request, ?MODULE, process_local_iq),
    ok.

stop(_Host) ->
    ?INFO("Stop: ~w", [?MODULE]),
    gen_mod:stop_child(?PROC()),
    gen_iq_handler:remove_iq_handler(ejabberd_local, ?HALLOAPP, pb_reverse_geocode_request),
    ok.

depends(_Host, _Opts) ->
    [].

reload(_Host, _NewOpts, _OldOpts) ->
    ok.

mod_options(_Host) ->
    [].

%%====================================================================
%% gen_server API
%%====================================================================

init(_) ->
    AccessToken = mod_aws:get_secret(<<"Mapbox">>),
    {ok, #{access_token => AccessToken, ref_map => #{}}}.


terminate(_Reason, _State) ->
    ok.


handle_call(Msg, From, State) ->
    ?WARNING("Unexpected call from ~p: ~p", [From, Msg]),
    {noreply, State}.


handle_cast({reverse_geocode_lookup, Uid, Latitude, Longitude, IQ, C2SPid},
        #{access_token := AccessToken, ref_map := RefMap} = State) ->
    BinLat = float_to_binary(Latitude),
    BinLong = float_to_binary(Longitude),
    Url = <<"https://api.mapbox.com/geocoding/v5/mapbox.places/", BinLong/binary, ",", BinLat/binary, ".json?",
        "types=poi,address&reverseMode=score&access_token=", AccessToken/binary>>,
    NewState = case httpc:request(get, {Url, []}, [], [{sync, false}]) of
        {ok, Ref} ->
            NewRefMap = RefMap#{Ref => {Uid, IQ, C2SPid}},
            State#{ref_map => NewRefMap};
        {error, Err} ->
            ?ERROR("httpc error for url ~p: ~p", [Url, Err]),
            IQResult = pb:make_iq_result(IQ, #pb_reverse_geocode_result{result = fail}),
            halloapp_c2s:route(C2SPid, {route, IQResult}),
            State
    end,
    {noreply, NewState};

handle_cast({ping, Id, Ts, From}, State) ->
    util_monitor:send_ack(self(), From, {ack, Id, Ts, self()}),
    {noreply, State};

handle_cast(Msg, State) ->
    ?WARNING("Unexpected cast: ~p", [Msg]),
    {noreply, State}.


%% handles return message from async httpc request
handle_info({http, {Ref, {{_, 200, "OK"}, _Hdrs, JsonResult}}}, #{ref_map := RefMap} = State) ->
    ResultMap = jiffy:decode(JsonResult, [return_maps]),
    {Uid, IQ, C2SPid} = maps:get(Ref, RefMap),
    IQResult = case maps:get(<<"features">>, ResultMap) of
        [] ->
            pb:make_iq_result(IQ, #pb_reverse_geocode_result{result = ok});
        FeaturesList ->
            FeatureTypes = lists:map(fun(Map) -> lists:nth(1, binary:split(maps:get(<<"id">>, Map, undefined), <<".">>)) end, FeaturesList),
            case {lists:member(<<"poi">>, FeatureTypes), lists:member(<<"address">>, FeatureTypes)} of
                {true, _} ->
                    %% poi exists
                    Feature = get_feature(<<"poi">>, FeaturesList),
                    Name = maps:get(<<"text">>, Feature, <<>>),
                    Address = maps:get(<<"address">>, maps:get(<<"properties">>, Feature, #{}), <<>>),
                    ReverseGeocodeLocation = get_location_info_from_context(Feature,
                        #pb_reverse_geocode_location{name = Name, address = Address, type = <<"poi">>}),
                    pb:make_iq_result(IQ, #pb_reverse_geocode_result{result = ok, location = ReverseGeocodeLocation});
                {_, true} ->
                    %% address exists
                    Feature = get_feature(<<"address">>, FeaturesList),
                    Street = maps:get(<<"text">>, Feature, <<>>),
                    Number = maps:get(<<"address">>, Feature, <<"">>),
                    ReverseGeocodeLocation = get_location_info_from_context(Feature,
                        #pb_reverse_geocode_location{address = string:trim(<<Number/binary, " ", Street/binary>>), type = <<"address">>}),
                    pb:make_iq_result(IQ, #pb_reverse_geocode_result{result = ok, location = ReverseGeocodeLocation});
                _ ->
                    %% no poi or address info
                    ?INFO("No poi or address for ~s's request", [Uid]),
                    pb:make_iq_result(IQ, #pb_reverse_geocode_result{result = ok})
            end
    end,
    halloapp_c2s:route(C2SPid, {route, IQResult}),
    NewRefMap = maps:remove(Ref, RefMap),
    {noreply, State#{ref_map => NewRefMap}};

handle_info({http, {Ref, {{_, Code, HttpMsg}, _Hdrs, _Res}}}, #{ref_map := RefMap} = State) ->
    {_Uid, IQ, C2SPid} = maps:get(Ref, RefMap),
    ?ERROR("~p error: ~p | initial request: ~p", [Code, HttpMsg, IQ]),
    IQResult = pb:make_iq_result(IQ, #pb_reverse_geocode_result{result = fail}),
    halloapp_c2s:route(C2SPid, {route, IQResult}),
    NewRefMap = maps:remove(Ref, RefMap),
    {noreply, State#{ref_map => NewRefMap}};

handle_info({http, {Ref, {error, Reason}}}, #{ref_map := RefMap} = State) ->
    {_Uid, IQ, C2SPid} = maps:get(Ref, RefMap),
    ?ERROR("Error: ~p | initial request: ~p", [Reason, IQ]),
    IQResult = pb:make_iq_result(IQ, #pb_reverse_geocode_result{result = fail}),
    halloapp_c2s:route(C2SPid, {route, IQResult}),
    NewRefMap = maps:remove(Ref, RefMap),
    {noreply, State#{ref_map => NewRefMap}};

handle_info(Info, State) ->
    ?WARNING("Unexpected info: ~p", [Info]),
    {noreply, State}.


code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

-spec get_feature(binary(), list(map())) -> map().
get_feature(Type, FeaturesList) ->
    case lists:filter(
            fun(Feature) ->
                case binary:split(maps:get(<<"id">>, Feature), <<".">>) of
                    [Type, _] -> true;
                    _ -> false
                end
            end,
            FeaturesList) of
        [] -> undefined;
        [Res] -> Res
    end.

get_location_info_from_context(Feature, PbReverseGeocodeLocation) ->
    [Long, Lat] = maps:get(<<"center">>, Feature),
    GpsLocation = #pb_gps_location{latitude = Lat, longitude = Long},
    lists:foldl(
        fun(ContextMap, PbResult) ->
            [Type, _] = binary:split(maps:get(<<"id">>, ContextMap), <<".">>),
            case Type of
                <<"neighborhood">> ->
                    PbResult#pb_reverse_geocode_location{neighborhood = maps:get(<<"text">>, ContextMap, <<>>)};
                <<"postcode">> ->
                    PbResult#pb_reverse_geocode_location{postcode = maps:get(<<"text">>, ContextMap, <<>>)};
                <<"place">> ->
                    PbResult#pb_reverse_geocode_location{place = maps:get(<<"text">>, ContextMap, <<>>)};
                <<"district">> ->
                    PbResult#pb_reverse_geocode_location{district = maps:get(<<"text">>, ContextMap, <<>>)};
                <<"region">> ->
                    PbResult#pb_reverse_geocode_location{region = maps:get(<<"text">>, ContextMap, <<>>)};
                <<"country">> ->
                    PbResult#pb_reverse_geocode_location{country = maps:get(<<"text">>, ContextMap, <<>>)};
                _ ->
                    PbResult
            end
        end,
        PbReverseGeocodeLocation#pb_reverse_geocode_location{location = GpsLocation},
        maps:get(<<"context">>, Feature)).

