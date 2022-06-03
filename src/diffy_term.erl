%% @author Maas-Maarten Zeeman <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman
%%
%% @doc Diffy, an erlang diff match and patch implementation 
%%      Adapted from diffy.erl for simple diff on a list of Erlang terms
%% @end
%% Copyright 2014-2015 Maas-Maarten Zeeman, Marc Worrell
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%% 
%%     http://www.apache.org/licenses/LICENSE-2.0
%% 
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.
%% Erlang diff-match-patch implementation

-module(diffy_term).

-export([
    diff/2
]).

-type diff_op() :: delete | equal | insert.
-type diff() :: {diff_op(), term()}.
-type diffs() :: list(diff()).

-export_type([ diffs/0 ]).

-spec diff(list(), list()) -> diffs().
diff(A, A) ->
    [{equal, A}];
diff(A, []) ->
    [{delete, A}];
diff([], B) ->
    [{insert, B}];
diff(A, B) when is_list(A), is_list(B) ->
    {Dict0, N} = term_dict(A, dict:new(), 0),
    {Dict, _N} = term_dict(B, Dict0, N),
    Diff = diffy:diff(map_terms(A, Dict), map_terms(B, Dict)),
    unmap_diff(Diff, Dict).

term_dict([], D, N) ->
    {D, N};
term_dict([T|Ts], D, N) ->
    case dict:is_key(T, D) of
        true ->
            term_dict(Ts, D, N);
        false ->
            D1 = dict:store(T, N, D),
            term_dict(Ts, D1, N+1)
    end.

map_terms(A, Dict) ->
    T = [ dict:fetch(K, Dict) || K <- A ],
    unicode:characters_to_binary(T).

unmap_diff(Ds, Dict) ->
    RDict = dict:from_list([ {N,T} || {T,N} <- dict:to_list(Dict) ]),
    [ unmap_diff_1(D, RDict) || D <- Ds ].

unmap_diff_1({Op, B}, RDict) ->
    Cs = unicode:characters_to_list(B),
    {Op, [ dict:fetch(C, RDict) || C <- Cs ]}.



-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

diffy_term_test() ->
    ?assertEqual(
        [{equal,[a]}],
        diffy_term:diff([a], [a])),
    ?assertEqual(
        [{insert,[a]}],
        diffy_term:diff([], [a])),
    ?assertEqual(
        [{delete,[a]}],
        diffy_term:diff([a], [])),
    ?assertEqual(
        [{equal,[a]},{insert,[e]},{equal,[b,c,d]},{delete,[e]}],
        diffy_term:diff([a,b,c,d,e], [a,e,b,c,d])),
    ok.


-endif.


