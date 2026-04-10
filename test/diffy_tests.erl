%% @author Maas-Maarten Zeeman <mmzeeman@xs4all.nl>
%% @copyright 2014 Maas-Maarten Zeeman
%%
%% @doc Diffy, an erlang diff match and patch implementation 
%%
%% Copyright 2014 Maas-Maarten Zeeman
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

%%
%% Properties
%%

prop_cleanup_merge() ->
    ?FORALL(Diffs, diffy:diffs(),
        begin
            SourceText = diffy:source_text(Diffs),
            DestinationText = diffy:destination_text(Diffs),

            CleanDiffs = cleanup_merge(Diffs),

            SourceText == diffy:source_text(CleanDiffs) andalso
            DestinationText == diffy:destination_text(CleanDiffs)
        end).

prop_cleanup_efficiency() ->
    ?FORALL(Diffs, diffy:diffs(),
        begin
            SourceText = diffy:source_text(Diffs),
            DestinationText = diffy:destination_text(Diffs),

            EfficientDiffs = cleanup_efficiency(Diffs),

            SourceText == diffy:source_text(EfficientDiffs) andalso
            DestinationText == diffy:destination_text(EfficientDiffs)
        end).

html_like() ->
    proper_types:resize(200,
                        list(frequency([{70, range($a, $z)},       % letters
                                        {20, oneof(["&amp;", "&gt;", "<script>", "<br />", "<p>", "</p>", "<div>", "</div>"])}, % tags
                                        {2, utf8(4)},              % Some small portions of unicode chars.
                                        {2, range($0, $9)},        % numbers
                                        {2, $\s},                  % whitespace
                                        {4,  $\n},                 % linebreaks
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
    ?assertEqual(true, proper:quickcheck(prop_cleanup_merge(), [{numtests, 500}, {to_file, user}])),
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

    % % Simple elimination.
    % ?assertEqual([{delete, <<"abc">>}, {insert, <<"b">>}], 
    %     cleanup_semantic([{delete, <<"a">>}, {equal, <<"b">>}, {delete, <<"c">>}])),

    % % Multiple eliminations.
    % ?assertEqual([{delete, <<"AB_AB">>}, {insert, <<"1A2_1A2">>}], 
    %     cleanup_semantic([{insert, <<"1">>}, {equal, <<"A">>}, {delete, <<"B">>}, {insert, <<"2">>}, 
    %         {equal, <<"_">>}, {insert, <<"1">>}, {equal, <<"A">>}, {delete, <<"B">>}, {insert, <<"2">>}])),

    ok.

cleanup_efficiency_prop_test() ->
    ?assertEqual(true, proper:quickcheck(prop_cleanup_efficiency(), [{numtests, 500}, {to_file, user}])),
    ok.

random_diffs_prop_test() ->
    ?assertEqual(true, proper:quickcheck(prop_make_diff(), [{numtests, 500}, {to_file, user}])),
    ok.

random_inner_diff_prop_test() ->
    ?assertEqual(true, proper:quickcheck(prop_inner_diff(), [{numtests, 500}, {to_file, user}])),
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
    ?assertEqual([{insert, <<"12x34">>}, {delete, <<"xcd">>}], 
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

compute_diff_substring_match_test() ->
    %% Exercise the {Start, Length} branch of compute_diff/3 where
    %% binary:match(LongText, ShortText) succeeds — i.e. the short text
    %% is a verbatim substring of the long text.

    %% "test" found inside "a-test-b": no common prefix ('t' /= 'a') and no
    %% common suffix ('t' /= 'b'), so split_pre_and_suffix leaves both texts
    %% unchanged.  compute_diff sees ShortText = <<"test">>, LongText =
    %% <<"a-test-b">>, binary:match finds "test" at byte 2, producing:
    %%   [{insert, <<"a-">>}, {equal, <<"test">>}, {insert, <<"-b">>}]
    ?assertEqual([{insert, <<"a-">>}, {equal, <<"test">>}, {insert, <<"-b">>}],
                 diffy:diff(<<"test">>, <<"a-test-b">>)),

    %% Reversed direction: "a-test-b" vs "test".
    ?assertEqual([{delete, <<"a-">>}, {equal, <<"test">>}, {delete, <<"-b">>}],
                 diffy:diff(<<"a-test-b">>, <<"test">>)),

    %% "barfoo" vs "foo": split_pre_and_suffix strips "foo" as common suffix,
    %% compute_diff sees <<"bar">> vs <<>>, yielding [{delete, <<"bar">>}].
    %% Combined with suffix: [{delete, <<"bar">>}, {equal, <<"foo">>}].
    ?assertEqual([{delete, <<"bar">>}, {equal, <<"foo">>}],
                 diffy:diff(<<"barfoo">>, <<"foo">>)),

    %% "prefoo" vs "foo": no common prefix ('p' /= 'f'), common suffix "foo"
    %% stripped.  compute_diff sees <<"pre">> vs <<>>.
    ?assertEqual([{delete, <<"pre">>}, {equal, <<"foo">>}],
                 diffy:diff(<<"prefoo">>, <<"foo">>)),

    ok.

diff_non_ascii_prefix_test() ->
    %% Verify that diff/2 handles non-ASCII characters correctly when they
    %% precede an ASCII common suffix.
    %%
    %% diff(<<"a">>, <<Ā/utf8, "a">>):
    %%   split_pre_and_suffix finds no common prefix (first bytes differ:
    %%   97 vs 196), but "a" is a common suffix.  After stripping the suffix
    %%   compute_diff sees <<>> vs <<196,128>> (Ā in UTF-8).
    %%   Result: [{insert, <<Ā/utf8>>}, {equal, <<"a">>}].
    ?assertEqual(
        [{insert, <<$\x{100}/utf8>>}, {equal, <<"a">>}],
        diffy:diff(<<"a">>, <<$\x{100}/utf8, "a">>)),

    %% Longer variant: two Ā codepoints precede "ab".
    %%   Common suffix "ab" stripped; compute_diff sees <<>> vs <<Ā/utf8, Ā/utf8>>.
    ?assertEqual(
        [{insert, <<$\x{100}/utf8, $\x{100}/utf8>>}, {equal, <<"ab">>}],
        diffy:diff(<<"ab">>, <<$\x{100}/utf8, $\x{100}/utf8, "ab">>)),

    %% Non-ASCII: U+0100 (Ā) before "test".  No common prefix (196 /= 116),
    %% common suffix "test" stripped; compute_diff sees <<>> vs <<Ā/utf8>>.
    ?assertEqual([{insert, <<$\x{100}/utf8>>}, {equal, <<"test">>}],
                 diffy:diff(<<"test">>, <<$\x{100}/utf8, "test">>)),

    ok.

compute_diff_test() ->
    %% Branch 1: OldText is empty -> pure insert
    ?assertEqual([{insert, <<"hello">>}], diffy:diff(<<>>, <<"hello">>)),

    %% Branch 2: NewText is empty -> pure delete
    ?assertEqual([{delete, <<"hello">>}], diffy:diff(<<"hello">>, <<>>)),

    %% Branch 3: ShortText is a substring of LongText.
    %% OldText shorter: "foo" found inside "barfoo" (via common-suffix stripping
    %% then compute_diff on the remainder).
    ?assertEqual([{delete, <<"bar">>}, {equal, <<"foo">>}],
                 diffy:diff(<<"barfoo">>, <<"foo">>)),

    %% OldText longer: "foobar" and "foo" share the common prefix "foo",
    %% which split_pre_and_suffix strips. compute_diff then processes
    %% "bar" vs <<>>, yielding [{delete,<<"bar">>}].
    ?assertEqual([{equal, <<"foo">>}, {delete, <<"bar">>}],
                 diffy:diff(<<"foobar">>, <<"foo">>)),

    %% Branch 4a: single-codepoint ShortText with no match in LongText
    %% -> [{delete, OldText}, {insert, NewText}]
    ?assertEqual([{delete, <<"x">>}, {insert, <<"test">>}],
                 diffy:diff(<<"x">>, <<"test">>)),
    ?assertEqual([{delete, <<"test">>}, {insert, <<"x">>}],
                 diffy:diff(<<"test">>, <<"x">>)),

    %% Branch 4b: no substring relationship, length > 1 codepoint each —
    %% falls through to try_half_match / bisect. Check round-trip correctness.
    Old = <<"the cat sat on the mat">>,
    New = <<"the dog sat on the rug">>,
    Diffs = diffy:diff(Old, New),
    ?assertEqual(Old, diffy:source_text(Diffs)),
    ?assertEqual(New, diffy:destination_text(Diffs)),

    ok.


%%
%% Helpers
%%

pretty_html(Diffs) ->
    iolist_to_binary(diffy:pretty_html(Diffs)).

cleanup_efficiency(Diffs) ->
    diffy:cleanup_efficiency(Diffs).

cleanup_semantic(Diffs) ->
    diffy:cleanup_semantic(Diffs).

cleanup_merge(Diffs) ->
    diffy:cleanup_merge(Diffs).
