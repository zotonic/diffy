%% @author Maas-Maarten Zeeman <mmzeeman@xs4all.nl>
%% @copyright 2014-2026 Maas-Maarten Zeeman
%%
%% @doc Diffy, an erlang diff match and patch implementation 
%%
%% Copyright 2014-2026 Maas-Maarten Zeeman
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

-module(diffy_tests).

-include_lib("proper/include/proper.hrl").
-include_lib("eunit/include/eunit.hrl").

-dialyzer({no_opaque, [
    cleanup_merge_prop_test/0,
    cleanup_efficiency_prop_test/0,
    cleanup_semantic_prop_test/0,
    random_inner_diff_prop_test/0,
    random_diffs_prop_test/0
]}).

-define(NUM_TESTS, 500).

%%
%% Properties
%%

prop_cleanup_merge() ->
    ?FORALL(Diffs, list({diff_op(), proper_unicode:utf8()}),
        begin
            SourceText = diffy:source_text(Diffs),
            DestinationText = diffy:destination_text(Diffs),
            CleanDiffs = cleanup_merge(Diffs),

            SourceText =:= diffy:source_text(CleanDiffs)
            andalso DestinationText =:= diffy:destination_text(CleanDiffs)
        end).

prop_cleanup_efficiency() ->
    ?FORALL(Diffs, list({diff_op(), proper_unicode:utf8()}),
        begin
            SourceText = diffy:source_text(Diffs),
            DestinationText = diffy:destination_text(Diffs),
            EfficientDiffs = cleanup_efficiency(Diffs),

            SourceText =:= diffy:source_text(EfficientDiffs)
            andalso DestinationText =:= diffy:destination_text(EfficientDiffs)
        end).

prop_cleanup_semantic() ->
    ?FORALL(Diffs, list({diff_op(), proper_unicode:utf8()}),
        begin
            SourceText = diffy:source_text(Diffs),
            DestinationText = diffy:destination_text(Diffs),
            EfficientDiffs = cleanup_semantic(Diffs),

            SourceText =:= diffy:source_text(EfficientDiffs)
            andalso DestinationText =:= diffy:destination_text(EfficientDiffs)
        end).

html_like() ->
    proper_types:resize(200,
                        list(frequency([{70, range($a, $z)},       % letters
                                        {20, oneof(["&amp;", "&gt;", "<script>", "<br />", "<p>", "</p>", "<div>", "</div>"])}, % tags
                                        {2, utf8(4)},              % Some small portions of unicode chars.
                                        {2, range($0, $9)},        % numbers
                                        {2, $\s},                  % whitespace
                                        {4, $\n},                 % linebreaks
                                        {2, oneof([$., $-, $!, $?, $,])}   % punctuation
                                       ]))).

prop_make_diff() ->
    ?FORALL({S, D}, {html_like(), html_like()},
        begin
            SourceText = iolist_to_binary(S),
            DestinationText = iolist_to_binary(D),

            Patches = diffy:diff(SourceText, DestinationText),

            is_valid_patch(Patches) andalso
                (SourceText == diffy:source_text(Patches) andalso DestinationText == diffy:destination_text(Patches))
        end).

prop_inner_diff() ->
    ?FORALL({OP, IO, IN, OS}, {html_like(), html_like(), html_like(), html_like()},
        begin
            OuterPrefix = iolist_to_binary(OP),
            InnerOld = iolist_to_binary(IO),
            InnerNew = iolist_to_binary(IN),
            OuterSuffix = iolist_to_binary(OS),

            SourceText = <<OuterPrefix/binary, InnerOld/binary, OuterSuffix/binary>>,
            DestinationText = <<OuterPrefix/binary, InnerNew/binary, OuterSuffix/binary>>,

            Patches = diffy:diff(SourceText, DestinationText),

            is_valid_patch(Patches) andalso 
                (SourceText == diffy:source_text(Patches) andalso DestinationText == diffy:destination_text(Patches))
        end).

%% Return true iff the parameter which is passed is a valid patch.
%%
is_valid_patch([]) ->
    true;
is_valid_patch([{Op, Bin} | Rest]) when Op =:= insert orelse Op =:= delete orelse Op =:= equal ->
    case is_valid_utf8_binary(Bin) of
        true ->
            is_valid_patch(Rest);
        false ->
            false
    end;
is_valid_patch(_) ->
    false.

%% Return true if the parameter passed is a valid utf-8 binary.
%%
is_valid_utf8_binary(<<>>) ->
    true;
is_valid_utf8_binary(<<_C/utf8, Rest/binary>>) ->
    is_valid_utf8_binary(Rest);
is_valid_utf8_binary(_) ->
    false.

%%
%% Tests
%%

pretty_html_test() ->
    ?assertEqual(<<>>, pretty_html([])),
    ?assertEqual(<<"<span>test</span>">>, pretty_html([{equal, <<"test">>}])),
    ?assertEqual(<<"<del style='background:#ffe6e6;'>foo</del><span>test</span>">>, 
        pretty_html([{delete, <<"foo">>}, {equal, <<"test">>}])),

    ?assertEqual(<<"<ins style='background:#e6ffe6;'>foo</ins><span>test</span>">>, 
        pretty_html([{insert, <<"foo">>}, {equal, <<"test">>}])),

    %% escaping.
    ?assertEqual(<<"<ins style='background:#e6ffe6;'>&lt;span&gt;foo&lt;/span&gt;</ins><span>&amp; &lt; &gt; &quot; &#39;</span>">>, 
        pretty_html([{insert, <<"<span>foo</span>">>}, {equal, <<"& < > \" '">>}])),
    ok.

source_text_test() ->
    ?assertEqual(<<"fruit flies like a banana">>, 
        diffy:source_text([{equal,<<"fruit flies ">>}, {delete,<<"lik">>}, {equal,<<"e">>},
            {insert,<<"at">>}, {equal,<<" a banana">>}])),
    ok.

destination_text_test() ->
    ?assertEqual(<<"fruit flies eat a banana">>, 
        diffy:destination_text([{equal,<<"fruit flies ">>}, {delete,<<"lik">>}, {equal,<<"e">>},
            {insert,<<"at">>}, {equal,<<" a banana">>}])),
    ok.


levenshtein_test() ->
    ?assertEqual(0, diffy:levenshtein([])),
    ?assertEqual(5, diffy:levenshtein([{equal,<<"fruit flies ">>}, {delete,<<"lik">>}, 
        {equal,<<"e">>}, {insert,<<"at">>}, {equal,<<" a banana">>}])),

    % Levenshtein with trailing equality.
    ?assertEqual(4, diffy:levenshtein([{delete, <<"abc">>}, {insert, <<"1234">>}, {equal, <<"xyz">>}])),
    % Levenshtein with leading equality.
    ?assertEqual(4, diffy:levenshtein([{equal, <<"xyz">>}, {delete, <<"abc">>}, {insert, <<"1234">>}])),
    % Levenshtein with middle equality.
    ?assertEqual(7, diffy:levenshtein([{delete, <<"abc">>}, {equal, <<"xyz">>}, {insert, <<"1234">>}])),

    ok.

make_patch_test() ->
	%% No patches...
	?assertEqual([], diffy:make_patch([])),

	%% Source and destination text is the same.
	% ?assertEqual([], diffy:make_patch(<<>>, <<"abc">>)),

	%% Source and destination text is the same.
	% ?assertEqual([], diffy:make_patch(<<"abc">>, <<"abc">>)),

	ok.
 
cleanup_merge_test() ->
    % no change..
    ?assertEqual([], cleanup_merge([])),

    % no change
    ?assertEqual([{equal, <<"a">>}, {delete, <<"b">>}, {insert, <<"c">>}], 
        cleanup_merge([{equal, <<"a">>}, {delete, <<"b">>}, {insert, <<"c">>}])),

    % Merge equalities
    ?assertEqual([{equal, <<"abc">>}], 
        cleanup_merge([{equal, <<"a">>}, {equal, <<"b">>}, {equal, <<"c">>}])),
    ?assertEqual([{delete, <<"abc">>}], 
        cleanup_merge([{delete, <<"a">>}, {delete, <<"b">>}, {delete, <<"c">>}])),
    ?assertEqual([{insert, <<"abc">>}], 
        cleanup_merge([{insert, <<"a">>}, {insert, <<"b">>}, {insert, <<"c">>}])),

    % Merge interweaves before equal operations
    ?assertEqual([{delete, <<"ac">>}, {insert, <<"bd">>}, {equal, <<"ef">>}], 
        cleanup_merge([{delete, <<"a">>}, {insert, <<"b">>}, {delete, <<"c">>}, {insert, <<"d">>}, 
            {equal, <<"e">>}, {equal, <<"f">>}])),

    % Prefix and suffix detection with equalities.
    ?assertEqual([{equal, <<"xa">>}, {delete, <<"d">>}, {insert, <<"b">>}, {equal, <<"cy">>}], 
        cleanup_merge([{equal, <<"x">>}, {delete, <<"a">>}, {insert, <<"abc">>}, {delete, <<"dc">>}, {equal, <<"y">>}])),

    % Slide left edit
    ?assertEqual([{insert, <<"ab">>}, {equal, <<"ac">>}],
        cleanup_merge([{equal, <<"a">>}, {insert, <<"ba">>}, {equal, <<"c">>}])),

    % Slide right edit
    ?assertEqual([{equal, <<"ca">>}, {insert, <<"ba">>}],
        cleanup_merge([{equal, <<"c">>}, {insert, <<"ab">>}, {equal, <<"a">>}])),

    % Slide edit left recursive.
    ?assertEqual([{delete, <<"abc">>}, {equal, <<"acx">>}],
        cleanup_merge([{equal, <<"a">>}, {delete, <<"b">>}, {equal, <<"c">>}, {delete, <<"ac">>}, {equal, <<"x">>}])),

    % Slide edit right recursive
    ?assertEqual([{equal, <<"xca">>}, {delete, <<"cba">>}],
        cleanup_merge([{equal, <<"x">>}, {delete, <<"ca">>}, {equal, <<"c">>}, {delete, <<"b">>}, {equal, <<"a">>}])),

    ok.

cleanup_merge_prop_test() ->
    ?assertEqual(true, proper:quickcheck(prop_cleanup_merge(), [{numtests, ?NUM_TESTS}, {to_file, user}])),
    ok.

cleanup_semantic_test() ->
    % No diffs case
    ?assertEqual([], cleanup_semantic([])),

    % No elimination #1.
    ?assertEqual([{delete, <<"ab">>}, {insert, <<"cd">>}, {equal, <<"12">>}, {delete, <<"e">>}],
        cleanup_semantic([{delete, <<"ab">>}, {insert, <<"cd">>}, {equal, <<"12">>}, {delete, <<"e">>}])),

    % No elimination #2. 
    ?assertEqual([{delete, <<"abc">>}, {insert, <<"ABC">>}, {equal, <<"1234">>}, {delete, <<"wxyz">>}], 
        cleanup_semantic([{delete, <<"abc">>}, {insert, <<"ABC">>}, {equal, <<"1234">>}, {delete, <<"wxyz">>}])),

    % Simple elimination.
    ?assertEqual([{delete, <<"abc">>}, {insert, <<"b">>}], 
        cleanup_semantic([{delete, <<"a">>}, {equal, <<"b">>}, {delete, <<"c">>}])),

    % Multiple eliminations.
    ?assertEqual([{delete, <<"AB_AB">>}, {insert, <<"1A2_1A2">>}],
        cleanup_semantic([{insert, <<"1">>}, {equal, <<"A">>}, {delete, <<"B">>}, {insert, <<"2">>},
            {equal, <<"_">>}, {insert, <<"1">>}, {equal, <<"A">>}, {delete, <<"B">>}, {insert, <<"2">>}])),

    % Regression test for UTF-8 data loss in cleanup_semantic_overlaps
    % Ins1 = <<0,32,204,128,0,0>> (size 6, text_size 5)
    % Ins2 = <<0,0,0,0,0,0,0,0>> (size 8, text_size 8)
    % Total Dest size 14, text_size 13
    Diffs = [{delete,<<0,0,0,0,0,0,0,0>>},{insert,<<0,32,204,128,0,0>>},{insert,<<0,0,0,0,0,0,0,0>>}],
    Cleaned = cleanup_semantic(Diffs),
    ?assertEqual(diffy:destination_text(Diffs), diffy:destination_text(Cleaned)),

    ok.
cleanup_efficiency_prop_test() ->
    ?assertEqual(true, proper:quickcheck(prop_cleanup_efficiency(), [{numtests, ?NUM_TESTS}, {to_file, user}])),
    ok.

cleanup_semantic_prop_test() ->
    ?assertEqual(true, proper:quickcheck(prop_cleanup_semantic(), [{numtests, ?NUM_TESTS}, {to_file, user}])),
    ok.

random_diffs_prop_test() ->
    ?assertEqual(true, proper:quickcheck(prop_make_diff(), [{numtests, ?NUM_TESTS}, {to_file, user}])),
    ok.

random_inner_diff_prop_test() ->
    ?assertEqual(true, proper:quickcheck(prop_inner_diff(), [{numtests, ?NUM_TESTS}, {to_file, user}])),
    ok.

cleanup_efficiency_test() ->
    % Null case
    ?assertEqual([], cleanup_semantic([])),

    % No elimination.
    Diffs = [{delete, <<"ab">>}, {insert, <<"12">>}, {equal, <<"wxyz">>}, {delete, <<"cd">>}, {insert, <<"34">>}],
    ?assertEqual(Diffs, cleanup_efficiency(Diffs)),

    % Four-edit elimination
    ?assertEqual([{delete, <<"abxyzcd">>}, {insert, <<"12xyz34">>}], 
        cleanup_efficiency([{delete, <<"ab">>}, {insert, <<"12">>}, {equal, <<"xyz">>}, {delete, <<"cd">>}, {insert, <<"34">>}])),

    % Three-edit elimination
    ?assertEqual([{delete, <<"xcd">>}, {insert, <<"12x34">>}], 
        cleanup_efficiency([{insert, <<"12">>}, {equal, <<"x">>}, {delete, <<"cd">>}, {insert, <<"34">>}])),

    % Backpass elimination
    ?assertEqual([{delete, <<"abxyzcd">>}, {insert, <<"12xy34z56">>}],
        cleanup_efficiency([{delete, <<"ab">>}, {insert, <<"12">>}, {equal, <<"xy">>}, {insert, <<"34">>}, 
            {equal, <<"z">>}, {delete, <<"cd">>}, {insert, <<"56">>}])),

    ok.

text_size_test() ->
    ?assertEqual(0, diffy:text_size(<<>>)),
    ?assertEqual(3, diffy:text_size(<<"aap">>)),
    ?assertEqual(3, diffy:text_size(<<"aap">>)),
    ?assertEqual(4, diffy:text_size(<<229/utf8, 228/utf8, 246/utf8, 251/utf8>>)),
    ?assertEqual(4, diffy:text_size(<<1046/utf8, 1011/utf8, 1022/utf8, 127/utf8>>)),

    %% Bad utf-8 input results in a badarg.
    ?assertError(badarg, diffy:text_size(<<149,157,112,8>>)),

    ok.

diff_test() ->
    %% No input, no diff
    ?assertEqual([], diffy:diff(<<>>, <<>>)),

    %% Texts are equal
    ?assertEqual([{equal, <<"String">>}], diffy:diff(<<"String">>, <<"String">>)),

    %% Insert and delete
    ?assertEqual([{insert, <<"test">>}], diffy:diff(<<>>, <<"test">>)),
    ?assertEqual([{delete, <<"test">>}], diffy:diff(<<"test">>, <<>>)),

    %% Longtext inside short text
    ?assertEqual([{insert, <<"a-">>}, {equal, <<"test">>}, {insert, <<"-b">>}], 
        diffy:diff(<<"test">>, <<"a-test-b">>)),
    ?assertEqual([{delete, <<"a-">>}, {equal, <<"test">>}, {delete, <<"-b">>}], 
        diffy:diff(<<"a-test-b">>, <<"test">>)),

    %% Single char insertions
    ?assertEqual([{delete,<<"x">>},{insert,<<"test">>}],
        diffy:diff(<<"x">>, <<"test">>)),
    ?assertEqual([{delete, <<"test">>},{insert, <<"x">>}],
        diffy:diff(<<"test">>, <<"x">>)),

    ?assertEqual([{equal, <<"a">>}, {delete, <<"b">>}, {insert, <<"c">>}],
        diffy:diff(<<"ab">>, <<"ac">>)),
    ?assertEqual([{delete, <<"a">>}, {insert, <<"c">>}, {equal, <<"b">>}],
        diffy:diff(<<"ab">>, <<"cb">>)),

    ?assertEqual([{equal, <<"t">>},
                  {insert, <<"e">>},
                  {equal, <<"st">>}], diffy:diff(<<"tst">>, <<"test">>)),

    ?assertEqual([{equal,<<"cat ">>}, {insert,<<"mouse dog ">>}], 
                 diffy:diff(<<"cat ">>,
                            <<"cat mouse dog ">>)),
    ok.

  
diff_linemode_corners_test() ->
    %% Empty inputs.
    ?assertEqual([], diffy:diff_linemode(<<>>, <<>>)),
    ?assertEqual([{insert, <<"hello\n">>}], diffy:diff_linemode(<<>>, <<"hello\n">>)),
    ?assertEqual([{delete, <<"hello\n">>}], diffy:diff_linemode(<<"hello\n">>, <<>>)),

    %% Identical input — single equal op.
    ?assertEqual([{equal, <<"hello\nworld\n">>}],
        diffy:diff_linemode(<<"hello\nworld\n">>, <<"hello\nworld\n">>)),

    %% No newline at end of file — last line treated as its own token.
    ?assertEqual(
        [{equal, <<"hello\n">>}, {delete, <<"world">>}, {insert, <<"maas">>}],
        diffy:diff_linemode(<<"hello\nworld">>, <<"hello\nmaas">>)),

    %% Blank lines — exercise is_blankline_start/end and the \n\n pattern.
    %% The rediff within cleanup_line_diff splits b\n vs c\n at character level.
    ?assertEqual(
        [{equal, <<"a\n\n">>}, {delete, <<"b">>}, {insert, <<"c">>}, {equal, <<"\nd\n">>}],
        diffy:diff_linemode(<<"a\n\nb\nd\n">>, <<"a\n\nc\nd\n">>)),

    %% \r\n line endings — exercises the \r\n\r\n blankline pattern.
    ?assertEqual(
        [{equal, <<"hello\r\n">>}, {delete, <<"world\r\n">>}, {insert, <<"maas\r\n">>}],
        diffy:diff_linemode(<<"hello\r\nworld\r\n">>, <<"hello\r\nmaas\r\n">>)),

    %% Repeated lines — the same line appearing multiple times should reuse the same index.
    ?assertEqual(
        [{equal, <<"a\nb\na\n">>}, {insert, <<"b\n">>}],
        diffy:diff_linemode(<<"a\nb\na\n">>, <<"a\nb\na\nb\n">>)),

    %% Large enough to trigger linemode via compute_diff1 size threshold.
    %% Build two texts that differ only in one line buried in > 100 chars of context.
    Prefix = binary:copy(<<"padding line\n">>, 10),
    Suffix = binary:copy(<<"trailing line\n">>, 10),
    Text1 = <<Prefix/binary, "old line\n", Suffix/binary>>,
    Text2 = <<Prefix/binary, "new line\n", Suffix/binary>>,
    Diffs = diffy:diff(Text1, Text2),
    %% Source and destination text must be preserved exactly.
    ?assertEqual(Text1, diffy:source_text(Diffs)),
    ?assertEqual(Text2, diffy:destination_text(Diffs)),
    %% Must contain at least one delete and one insert — the changed line.
    ?assert(lists:any(fun({delete, _}) -> true; (_) -> false end, Diffs)),
    ?assert(lists:any(fun({insert, _}) -> true; (_) -> false end, Diffs)),

    %% Multi-byte UTF-8 lines — verify encoding survives the linemode round-trip.
    ?assertEqual(
        [{equal, <<"héllo\n"/utf8>>}, {delete, <<"wörld\n"/utf8>>}, {insert, <<"wörlt\n"/utf8>>}],
        diffy:diff_linemode(<<"héllo\nwörld\n"/utf8>>, <<"héllo\nwörlt\n"/utf8>>)),

    %% cleanup_line_diff rediff path — two changed lines adjacent to an equal trigger
    %% the rediff of accumulated delete+insert data.
    T1 = <<"aaa\nbbb\nccc\n">>,
    T2 = <<"aab\nbbc\nccc\n">>,
    RediffDiffs = diffy:diff_linemode(T1, T2),
    ?assertEqual(T1, diffy:source_text(RediffDiffs)),
    ?assertEqual(T2, diffy:destination_text(RediffDiffs)),

    ok.

diff_options_test() ->
    A = <<"one two x four five">>,
    B = <<"one TWO x FOUR five">>,

    %% No options — same as diff/2.
    ?assertEqual(diffy:diff(A, B), diffy:diff(A, B, [])),

    %% no_linemode: result is structurally equivalent (same source/dest text).
    NoLinemode = diffy:diff(A, B, [no_linemode]),
    ?assertEqual(diffy:source_text(diffy:diff(A, B)), diffy:source_text(NoLinemode)),
    ?assertEqual(diffy:destination_text(diffy:diff(A, B)), diffy:destination_text(NoLinemode)),

    %% semantic option applies cleanup_semantic to the raw diff.
    ?assertEqual(diffy:cleanup_semantic(diffy:diff(A, B)), diffy:diff(A, B, [semantic])),

    %% efficiency option applies cleanup_efficiency to the raw diff.
    ?assertEqual(diffy:cleanup_efficiency(diffy:diff(A, B)), diffy:diff(A, B, [efficiency])),

    %% {efficiency, Cost} applies cleanup_efficiency/2 with the given cost.
    ?assertEqual(diffy:cleanup_efficiency(diffy:diff(A, B), 2), diffy:diff(A, B, [{efficiency, 2}])),

    %% Both: semantic first, then efficiency.
    ?assertEqual(
        diffy:cleanup_efficiency(diffy:cleanup_semantic(diffy:diff(A, B))),
        diffy:diff(A, B, [semantic, efficiency])),

    %% Order of options in list does not affect cleanup order.
    ?assertEqual(
        diffy:diff(A, B, [semantic, efficiency]),
        diffy:diff(A, B, [efficiency, semantic])),

    ok.



%%
%% Helpers
%%

diff_op() ->
    oneof([insert, delete, equal]).

pretty_html(Diffs) ->
    iolist_to_binary(diffy:pretty_html(Diffs)).

cleanup_efficiency(Diffs) ->
    diffy:cleanup_efficiency(Diffs).

cleanup_semantic(Diffs) ->
    diffy:cleanup_semantic(Diffs).

cleanup_merge(Diffs) ->
    diffy:cleanup_merge(Diffs).
