#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa deps/argparse/ebin -pa deps/lager/ebin -pa deps/xmpp/ebin -sname d
%% Example usage: ./d src/mod_invites.erl
%% More info at server/doc/dscript.md
-author("josh").
-mode(compile).
-behavior(cli).
-export([main/1, cli/0, run/1]).

-define(DEFAULT_SRC_FILES, ["src/gen_mod.erl"]).
-define(DEFAULT_BEAM_FILES, ["ebin/gen_mod.beam"]).


main(Args) ->
    Start = os:system_time(second),
    cli:run(Args, #{progname => "d"}),
    Stop = os:system_time(second),
    Runtime = (Stop - Start),
    io:format("Runtime: ~Bm ~Bs  ~n", [trunc(Runtime / 60), Runtime rem 60]).


cli() ->
    #{
        handler => {?MODULE, run},
        arguments => [
            #{name => verbose, short => $v, type => boolean, default => false},
            #{name => out, short => $o, long => "-out", default => 'stdout'},
            #{name => include, short => $i, long => "-include",
                default => get_default_includes(), action => append},
            #{name => file, nargs => list}
        ]
    }.


run(#{out := Out} = RawOpts) ->
    Opts = generate_opts(RawOpts),
    NumFiles = length(get_opt(Opts, files)) - length(?DEFAULT_SRC_FILES),
    io:format("Running dialyzer on ~B files...~n", [NumFiles]),
    Res = run_dialyzer(Opts),
    io:format("Dialyzer analysis complete. ~B issues found.~n", [length(Res)]),
    case Out of
        stdout ->
            io:format("~p~n", [Res]);
        OutFile ->
            file:write_file(OutFile, io_lib:fwrite("~p", [Res])),
            io:format("Full analysis in ~s~n", [OutFile])
    end.


run_dialyzer(Opts) ->
    try
        dialyzer:run(Opts)
    catch _Err:Rea ->
        io_lib:format("ERROR: ~p~n", [Rea]),
        []
    end.


get_opt(Opts, OptAtom) ->
    case lists:keyfind(OptAtom, 1, Opts) of
        false -> false;
        {OptAtom, Res} -> Res
    end.


% converts parsed input to list of lists of opts for dialyzer:run/1
generate_opts(#{file := FileList, out := Out, include := Include, verbose := Verbose}) ->
    Files = get_full_paths(FileList, Verbose),
    FileOpt = case lists:any(fun(F) -> "erl" =:= string:substr(F, length(F) - 2, 3) end, Files) of
        true ->
            case lists:any(fun(F) -> "beam" =:= string:substr(F, length(F) - 3, 4) end, Files) of
                true -> error(multiple_file_types);
                false -> [{files, Files ++ ?DEFAULT_SRC_FILES}, {from, src_code}]
            end;
        false -> [{files, Files ++ ?DEFAULT_BEAM_FILES}]
    end,
    IncludeOpt = [{include_dirs, Include ++ get_default_includes()}],
    if
        Verbose -> io:format("Includes: ~p~n", [get_default_includes()]);
        true -> ok
    end,
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


get_full_paths(FileList, Verbose) ->
    Files = lists:map(fun generate_full_path/1, FileList),
    case Verbose of
        true -> io:format("Files: ~p~n", [Files]);
        false -> ok
    end,
    Files.


get_default_includes() ->
    lists:filter(
        fun filelib:is_dir/1,
        ["deps/" ++ Dir ++ "/include" ||
            Dir <- string:tokens(os:cmd("ls deps"), "\n")]
    ) ++ ["include/"].

