#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa deps/argparse/ebin -pa deps/lager/ebin -pa deps/xmpp/ebin -sname d
%% Example usage: ./d src/mod_invites.erl
%% More info at server/doc/dscript.md
-author("josh").
-mode(compile).
-behavior(cli).
-export([main/1, cli/0, run/1]).

-define(DEFAULT_INCLUDES, [
    "include/",
    "deps/xmpp/include"
]).

-define(DEFAULT_FILES, ["src/gen_mod.erl"]).


main(Args) ->
    cli:run(Args, #{progname => "d"}).


cli() ->
    #{
        handler => {?MODULE, run},
        arguments => [
            #{name => out, short => $o, long => "-out", default => 'stdout'},
            #{name => include, short => $i, long => "-include",
                default => ?DEFAULT_INCLUDES, action => append},
            #{name => file}
        ]
    }.


run(#{out := Out} = RawOpts) ->
    Start = os:system_time(millisecond),
    Res = run_dialyzer(generate_opts(RawOpts)),
    case Out of
        stdout ->
            io:format("~s", [Res]);
        OutFile ->
            file:write_file(OutFile, io_lib:fwrite("~s", [Res])),
            io:format("Full analysis in ~s~n", [OutFile])
    end,
    Stop = os:system_time(millisecond),
    Runtime = (Stop - Start),
    io:format("Runtime: ~Bm ~.2.0fs  ~n", [trunc(Runtime / 1000) div 60, (Runtime rem 60) / 1000]).


run_dialyzer(Opts) ->
    [File, _DefaultFiles] = get_opt(Opts, files),
    io:format("Running dialyzer on ~s...~n", [File]),
    Ret = try
        Res = dialyzer:run(Opts),
        io:format("Dialyzer analysis complete. ~B issues found.~n", [length(Res)]),
        io_lib:format("~p~n", [Res])
    catch _Err:Rea ->
        io_lib:format("ERROR: ~p~n", [Rea])
    end,
    Ret.


get_opt(Opts, OptAtom) ->
    case lists:keyfind(OptAtom, 1, Opts) of
        false -> false;
        {OptAtom, Res} -> Res
    end.


% converts parsed input to list of opts for dialyzer:run/1
generate_opts(#{file := File, out := Out, include := Include}) ->
    Path = generate_full_path(File),
    FileOpt = case string:tokens(File, ".") of
        [_File, "erl"] -> [{files, [Path] ++ ?DEFAULT_FILES}, {from, src_code}];
        [_File, "beam"] -> [{files, [Path] ++ ?DEFAULT_FILES}, {from, byte_code}];
        _ -> error(invalid_file)
    end,
    IncludeOpt = [{include_dirs, Include ++ ?DEFAULT_INCLUDES}],
    OutOpt = case Out of
        stdout -> [];
        OutFile -> [{output_file, OutFile}]
    end,
    FileOpt ++ OutOpt ++ IncludeOpt.


generate_full_path(RelativePath) ->
    {ok, Base} = file:get_cwd(),
    case RelativePath of
        ["/" | Rest] -> Base + Rest;
        _ -> Base ++ "/" ++ RelativePath
    end.

