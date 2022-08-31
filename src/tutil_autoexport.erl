%% Licensed under the Apache License, Version 2.0 (the "License"); you may
%% not use this file except in compliance with the License. You may obtain
%% a copy of the License at <http://www.apache.org/licenses/LICENSE-2.0>
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%%
%% @author Richard Carlsson <carlsson.richard@gmail.com>
%% @copyright 2006 Richard Carlsson
%% @private
%% @see eunit
%% @doc Parse transform for automatic exporting of testset functions.

%% -------------------------------------------------------------------- %%
%% NOTE: This file has been changed from the original eunit_autoexport
%% -------------------------------------------------------------------- %%
-module(tutil_autoexport).
-author('luke').

%% This is also defined in include/tutil.hrl
-define(DEFAULT_TESTSET_SUFFIX, "_testset").
-define(DEFAULT_SETUP_FUN, "setup").

-export([parse_transform/2]).

parse_transform(Forms, Options) ->
    TestsetSuffix = proplists:get_value(
        eunit_testset_suffix,
        Options,
        ?DEFAULT_TESTSET_SUFFIX
    ),
    F = fun(Form, Set) ->
        form(Form, Set, TestsetSuffix)
    end,
    Exports = sets:to_list(lists:foldl(F, sets:new(), Forms)),
    rewrite(Forms, Exports).


%% This function basically iterates through all the functions in the module we're transforming and 
%% returns a set of functions to export (in addition to any functions explicitly exported)
form({function, _L, Name, Arity, _Cs}, S, TestsetSuffix) when Arity =:= 0 orelse Arity =:= 1 ->
    N = atom_to_list(Name),

    % if the func ends in "_testset", add it to the export set
    case lists:suffix(TestsetSuffix, N) of 
        true ->
            sets:add_element({Name, Arity}, S);
        false -> 
            % Also automatically export setup/0, if it exists (this is used as the default setup
            % function for _testset generators)
            case {Name, Arity} of
                {setup, 0} ->
                    sets:add_element({Name, Arity}, S);
                _ ->
                    S
            end
    end;
form(_, S, _) ->
    S.

% Iterate through the high-level constructs of the module until we reach the module declaration, at 
% which point we re-process the rest of the code to eventually return the module with our transform
% applied
rewrite([{attribute, _, module, {Name, _Ps}} = M | Fs], Exports) ->
    module_decl(Name, M, Fs, Exports);
rewrite([{attribute, _, module, Name} = M | Fs], Exports) ->
    module_decl(Name, M, Fs, Exports);
rewrite([F | Fs], Exports) ->
    [F | rewrite(Fs, Exports)];
rewrite([], _Exports) ->
    %% fail-safe, in case there is no module declaration
    [].


% searches the code for a definition of a function auto_test_/0. If none is found, insert one
rewrite([{function, _, auto_test_, 0, _} = F | Fs], As, Module, _Test) ->
    % Found auto_test_/0
    rewrite(Fs, [F | As], Module, false);
rewrite([F | Fs], As, Module, Test) ->
    rewrite(Fs, [F | As], Module, Test);
rewrite([], As, Module, Test) ->
    L = erl_anno:new(0),
    {if Test -> % If auto_test_/0 hasn't been defined in the module, insert our own
            [{function, L, auto_test_, 0, [ % specifies a function auto_test_ with arity 0
                {clause, L, [], [], % specifies a function clause taking 0 arguments with 0 guards
                [ % this list is our function body, which is just going to call our generator
                    % insert a remote call to tutil:run_testsets(Module)
                    {call, L, {remote, L, {atom, L, tutil}, {atom, L, run_testsets}}, [ 
                        {atom, L, Module}
                    ]}
                ]}
            ]}
            | As]; % lastly, just add this new function to the list of pre-existing forms!
        true ->
            As
    end,
    Test}.


% Returns the same module specification, but with the following changes:
%   1. Insert a new function auto_test_/0 if one doesn't already exist, which takes no arguments and 
%       contains a single call to tutil:run_testsets/1 with the name of the current module. This 
%       function will be recognized by eunit as a generator function and automatically run with the 
%       rest of the tests. tutil:run_testsets/1 returns a test fixture containing all functions ending
%       in "_testset".
%   2. Export setup/0, auto_test_/0, and all functions ending in _testset with Arity 0 or 1 (This is
%       the Exports list we created using form/3
module_decl(Name, M, Fs, Exports) ->
    Module = Name,
    {Fs1, Test} = rewrite(Fs, [], Module, true),
    Es = if % if we inserted our own func, export it - if there was one there already it will have 
            % been exported by eunit already so we don't have to worry about it
            Test -> [{auto_test_, 0} | Exports];
            true -> Exports
        end,
    % Return our new module definition! We have to reverse Fs1 becasue it gets reversed during the 
    % search for auto_test_/0
    [M, {attribute, erl_anno:new(0), export, Es} | lists:reverse(Fs1)]. 

