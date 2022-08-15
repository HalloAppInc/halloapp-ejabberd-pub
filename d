#!/usr/bin/env escript
%% -*- erlang -*-
%%! -pa _build/default/lib/argparse/ebin -pa _build/default/lib/lager/ebin -sname d 

%% Example usage: ./d src/mod_invites.erl
%% More info at server/doc/dscript.md

%% If dialyzer isn't working, make sure you've created a persistent lookup table with:
%% $ dialyzer --build_plt --apps erts kernel stdlib mnesia compiler crypto sasl ssl

-author("josh").
-mode(compile).
-behavior(cli).
-export([main/1, cli/0, run/1]).

-define(DEPS_DIR, "_build/default/lib/").
-define(DEFAULT_INCLUDE_DIR, "_build/*/*/*/include/").

-define(DEFAULT_SRC_FILES, ["src/gen_mod.erl", ?DEPS_DIR "supervisor3/src/supervisor3.erl"]).
-define(DEFAULT_BEAM_FILES, [?DEPS_DIR "ejabberd/ebin/gen_mod.beam", ?DEPS_DIR "supervisor3/ebin/supervisor3.beam"]).


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
            #{name => recursive, short => $r, type => boolean, default => false},
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
    PrettyRes = lists:map(fun dialyzer:format_warning/1, Res),
    
    case Out of
        stdout ->
            io:format("~s~n", [PrettyRes]);
        OutFile ->
            file:write_file(OutFile, io_lib:fwrite("~s", [PrettyRes])),
            io:format("Full analysis in ~s~n", [OutFile])
    end.


run_dialyzer(Opts) ->
    try
        dialyzer:run(Opts)
    catch _Err:Rea ->
        {dialyzer_error, ErrStr} = Rea,
        io:format("ERROR: ~s~n", [ErrStr]),
        case re:run(ErrStr, "Could not find the PLT") of
            {match, _} -> 
                io:format("HALLOAPP: To build a working plt, use:~n     dialyzer --build_plt --apps erts kernel stdlib mnesia compiler crypto sasl ssl~n");
            _ -> ok
        end,
        []
    end.


get_opt(Opts, OptAtom) ->
    case lists:keyfind(OptAtom, 1, Opts) of
        false -> false;
        {OptAtom, Res} -> Res
    end.


% converts parsed input to list of lists of opts for dialyzer:run/1
generate_opts(#{file := FileList, out := Out, include := Include, verbose := Verbose, recursive := Rec}) ->
    Files = get_full_paths(FileList),
    AllFiles = case Rec of 
        true ->
            sets:to_list(get_recursive_valid_file_set(sets:from_list(Files)));
        false -> Files
    end,
    FileOpt = case lists:any(fun(F) -> "erl" =:= string:substr(F, length(F) - 2, 3) end, AllFiles) of
        true ->
            case lists:any(fun(F) -> "beam" =:= string:substr(F, length(F) - 3, 4) end, AllFiles) of
                true -> error(multiple_file_types);
                false -> 
                    ValidFiles = lists:filter( % filter out non-erl files!
                        fun(F) -> "erl" =:= string:substr(F, length(F) - 2, 3) end,
                        AllFiles ++ ?DEFAULT_SRC_FILES),
                    [{files, ValidFiles}, {from, src_code}]
            end;
        false -> 
            ValidFiles = lists:filter( % filter out non-erl files!
                fun(F) -> "beam" =:= string:substr(F, length(F) - 3, 4) end,
                AllFiles ++ ?DEFAULT_BEAM_FILES),
            [{files, ValidFiles}]
    end,
    case Verbose of
        true -> io:format("Files: ~p~n", [FileOpt]);
        false -> ok
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


get_full_paths(FileList) ->
    lists:map(fun generate_full_path/1, FileList).


get_default_includes() ->
    LibList = lists:filter(
        fun filelib:is_dir/1,
        [Dir || Dir <- string:tokens(os:cmd("ls -d " ?DEFAULT_INCLUDE_DIR), "\n")]),        
    [?DEPS_DIR] ++ LibList ++ ["include/", "include/proto/"].


get_recursive_valid_file_set(FileSet) -> 
    DirSet = sets:filter(
        fun filelib:is_dir/1,
        FileSet),
    NonDirSet = sets:subtract(FileSet, DirSet),
    Contents = sets:fold(
        fun (Dir, Acc) ->
            PrefixDir = case lists:reverse(Dir) of 
                "/" ++ _ -> Dir;
                _ -> Dir ++ "/"
            end,
            ContentList = [PrefixDir ++ File || File <- string:tokens(os:cmd("ls " ++ Dir), "\n")],
            sets:union(sets:from_list(ContentList), Acc)
        end,
        sets:new(),
        DirSet),
    case sets:is_empty(Contents) of
        false ->
            sets:union(NonDirSet, get_recursive_valid_file_set(Contents));
        true ->
            NonDirSet
    end.
