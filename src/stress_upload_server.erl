%%%-------------------------------------------------------------------
%%% @author vipin
%%% @copyright (C) 2021, Halloapp Inc.
%%% @doc
%%% To stress test the upload server.
%%% @end
%%%-------------------------------------------------------------------
-module(stress_upload_server).
-author("vipin").

-include("ha_types.hrl").
-include("logger.hrl").

-define(DEFAULT_SIZE, 300 * 1024).  %% 300KiB

%% API
-export([
    stress_upload_server/3,
    run_upload_client/3
]).


-spec stress_upload_server(NumClients :: integer(), NumRequestsPerClient :: integer(), Options :: map()) -> ok.
stress_upload_server(NumClients, NumRequestsPerClient, Options) ->
    spawn_clients(NumClients, NumClients, NumRequestsPerClient, Options, os:system_time(millisecond)).

-spec spawn_clients(TotalClients :: integer(), RemainingClients :: integer(), 
        NumRequestsPerClient :: integer(), Options :: map(), StartTime :: integer()) -> ok.
spawn_clients(TotalClients, 0, NumRequestsPerClient, _Options, StartTime) ->
    wait_for(TotalClients),
    TimeTaken = os:system_time(millisecond) - StartTime,
    TotalRequests = TotalClients * NumRequestsPerClient,
    ?INFO("~p clients uploaded: ~p objects at: ~p objects/second",
        [TotalClients, TotalRequests, TotalRequests / (TimeTaken / 1000)]),
    ok;

spawn_clients(TotalClients, RemainingClients, NumRequestsPerClient, Options, StartTime) ->
    spawn(?MODULE, run_upload_client, [NumRequestsPerClient, Options, self()]),
    spawn_clients(TotalClients, RemainingClients - 1, NumRequestsPerClient, Options, StartTime).  


-spec run_upload_client(RemainingRequests :: integer(), Options :: map(), Pid :: pid()) -> ok.
run_upload_client(0, _Options, Pid) ->
    Pid ! {done, self()},
    ok;

run_upload_client(RemainingRequests, Options, Pid) ->
    Size = maps:get(size, Options, ?DEFAULT_SIZE),
    {ok, PatchUrl} = upload_client:request_upload(Size, Options),
    {ok, Offset} = upload_client:request_offset(PatchUrl),
    {ok, DownloadUrl} = upload_client:upload_data(PatchUrl, Offset, Size),
    ?INFO("Pid: ~p, download location: ~p", [self(), DownloadUrl]),
    run_upload_client(RemainingRequests - 1, Options, Pid).

wait_for(0) ->
    ok;
wait_for(NumClients) ->
    receive
        {done, Pid} ->
            ?INFO("Done: ~p", [Pid]),
            wait_for(NumClients - 1)
    end.
