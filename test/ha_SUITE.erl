-module(ha_SUITE).

-export([
    all/0,
    init_per_suite/1,
    end_per_suite/1
]).

-export([
    dummy_test/1
]).

-include("suite.hrl").

all() -> [dummy_test].


init_per_suite(InitConfigData) ->
    ct:pal("Config ~p", [InitConfigData]),
    NewConfig = suite_ha:init_config(InitConfigData),
    DataDir = proplists:get_value(data_dir, NewConfig),
    {ok, CWD} = file:get_cwd(),
%%    ExtAuthScript = filename:join([DataDir, "extauth.py"]),
%%    LDIFFile = filename:join([DataDir, "ejabberd.ldif"]),
%%    {ok, _} = file:copy(ExtAuthScript, filename:join([CWD, "extauth.py"])),
%%    {ok, _} = ldap_srv:start(LDIFFile),
    inet_db:add_host({127,0,0,1}, [
        binary_to_list(?S2S_VHOST),
        binary_to_list(?MNESIA_VHOST),
        binary_to_list(?UPLOAD_VHOST)]),
    inet_db:set_domain(binary_to_list(p1_rand:get_string())),
    inet_db:set_lookup([file, native]),
%%    start_ejabberd(NewConfig),
    NewConfig.


start_ejabberd(_Config) ->
    {ok, _} = application:ensure_all_started(ejabberd, transient).


end_per_suite(_Config) ->
    ok.
%%    application:stop(ejabberd).


dummy_test(ConfigData) ->
    ok = ok.
%%    TestData = read_log(restart, ?value(logref, ConfigData)),
%%    {match,_Line} = search_for("restart successful", TestData).

%%check_no_errors(ConfigData) ->
%%    TestData = read_log(all, ?value(logref, ConfigData)),
%%    case search_for("error", TestData) of
%%        {match,Line} -> ct:fail({error_found_in_log,Line});
%%        nomatch -> ok
%%    end.