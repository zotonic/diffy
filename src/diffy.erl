%% @author Maas-Maarten Zeeman <mmzeeman@xs4all.nl>
%% @copyright 2014-2026 Maas-Maarten Zeeman
%%
%% @doc Diffy, an erlang diff match and patch implementation 
%% @end
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

-module(diffy).

-export([
    diff/2,
    diff/3,
    diff_bisect/2,
    diff_linemode/2,

    pretty_html/1,

    source_text/1,
    destination_text/1,

    cleanup_merge/1,
    cleanup_semantic/1,

    cleanup_efficiency/1,
    cleanup_efficiency/2,

    levenshtein/1,

    make_patch/1,
    make_patch/2,

    text_size/1,

    split_pre_and_suffix/2,
    unique_match/2
]).

-type diff_op() :: delete | equal | insert.
-type diff() :: {diff_op(), unicode:unicode_binary()}.
-type diffs() :: list(diff()).

-type diff_option() ::
    semantic |
    efficiency |
    {efficiency, EditCost :: pos_integer()} |
    no_linemode.

-type for_fun() :: fun((integer(), term()) -> {continue, term()} | {break, term()}).

-export_type([diff_op/0, diff/0, diffs/0, diff_option/0]).

-define(PATCH_MARGIN, 4).
-define(IS_INS_OR_DEL(Op), (Op =:= insert orelse Op =:= delete)).
-define(PHASH2_RANGE, (1 bsl 32)).

-record(bisect_state, {
    k1start = 0, k1end = 0,
    k2start = 0, k2end = 0,
    v1,
    v2
}).

-record(patch, {
    diffs = [],

    start1 = 0,
    start2 = 0,

    length1 = 0,
    length2 = 0
}).

-dialyzer({no_match, for/5}).

% @doc Compute the difference between two binary texts.
-spec diff(unicode:unicode_binary(), unicode:unicode_binary()) -> diffs().
diff(Text1, Text2) ->
    diff(Text1, Text2, []).

% @doc Compute the difference between two binary texts with options.
%
% Options:
%   semantic             - run cleanup_semantic/1 on the result
%   efficiency           - run cleanup_efficiency/1 on the result (default edit cost 4)
%   {efficiency, Cost}   - run cleanup_efficiency/2 with a custom edit cost
%   no_linemode          - disable the linemode optimization for large texts
%
% Cleanups are always applied in the correct order: semantic first, then efficiency.
-spec diff(unicode:unicode_binary(), unicode:unicode_binary(), [diff_option()]) -> diffs().
diff(Text1, Text2, Options) when is_list(Options) ->
    CheckLines = not lists:member(no_linemode, Options),
    T1 = to_utf32(Text1),
    T2 = to_utf32(Text2),
    Diffs32 = diff32(T1, T2, CheckLines),
    Diffs1 = case lists:member(semantic, Options) of
        true  -> cleanup_semantic32(Diffs32);
        false -> Diffs32
    end,
    Diffs2 = case efficiency_opt(Options) of
        none           -> Diffs1;
        default        -> cleanup_efficiency32(Diffs1);
        {custom, Cost} -> cleanup_efficiency32(Diffs1, Cost)
    end,
    %% Single conversion at the exit boundary.
    [{Op, to_utf8(D)} || {Op, D} <- Diffs2].

%% Extract the efficiency option, preferring {efficiency, Cost} over plain efficiency.
efficiency_opt(Options) ->
    case lists:keyfind(efficiency, 1, Options) of
        {efficiency, Cost} -> {custom, Cost};
        false ->
            case lists:member(efficiency, Options) of
                true  -> default;
                false -> none
            end
    end.

%% Internal diff working entirely in UTF-32 binaries.
diff32(<<>>, <<>>, _CheckLines) ->
    [];
diff32(Text1, Text2, _CheckLines) when Text1 =:= Text2 ->
    [{equal, Text1}];
diff32(Text1, Text2, CheckLines) ->
    {Prefix, MText1, MText2, Suffix} = split_pre_and_suffix(Text1, Text2),

    Diffs = compute_diff(MText1, MText2, CheckLines),

    Diffs1 = case Suffix of
                 <<>> -> Diffs;
                 _ -> Diffs ++ [{equal, Suffix}]
             end,

    Diffs2 = case Prefix of
                 <<>> -> Diffs1;
                 _ -> [{equal, Prefix} | Diffs1]
             end,

    cleanup_merge32(Diffs2).

%% This assumes Text1 and Text2 don't have a common prefix. Operates on UTF-32.
compute_diff(<<>>, NewText, _CheckLines) ->
    [{insert, NewText}];
compute_diff(OldText, <<>>, _CheckLines) ->
    [{delete, OldText}];
compute_diff(OldText, NewText, CheckLines) ->
    OldStNew = size(OldText) < size(NewText),

    {ShortText, LongText} = case OldStNew of
                                true -> {OldText, NewText};
                                false -> {NewText, OldText}
                            end,

    case aligned_utf32_match(LongText, ShortText, 0) of
        {Start, Length} ->
            <<Pre:Start/binary, _:Length/binary, Suf/binary>> = LongText,
            Op = diff_op(OldStNew),
            [{Op, Pre}, {equal, ShortText}, {Op, Suf}];
        nomatch ->
            %% In UTF-32, a single codepoint is exactly 4 bytes.
            case size(ShortText) =:= 4 of
                true ->
                    [{delete, OldText}, {insert, NewText}];
                false ->
                    try_half_match(OldText, NewText, CheckLines)
            end
    end.

diff_op(true) -> insert;
diff_op(false) -> delete.

%% Check if we can do a half-match diff, if not, try line or bisect diff.  
try_half_match(OldText, NewText, CheckLines) ->
    case half_match(OldText, NewText) of
        {half_match, A1, A2, B1, B2, Common} ->
            Diffs1 = diff32(A1, B1, CheckLines),
            Diffs2 = diff32(A2, B2, CheckLines),
            Diffs1 ++ [{equal, Common} | Diffs2];
        undefined ->
            compute_diff1(OldText, NewText, CheckLines)
    end.

%% Check if we can do a half-match diff, returns undefined if it is not advantageous.
%% Operates on UTF-32 binaries — size comparisons are in bytes (4 bytes per codepoint).
half_match(A, B) ->
    AgtB = size(A) > size(B),
    {Short, Long} = case AgtB of
                        true -> {B, A};
                        false -> {A, B}
                    end,

    LongSize = size(Long),
    ShortSize = size(Short),

    %% text_smaller_than(Long, 4) becomes size(Long) < 4*4 in UTF-32.
    case LongSize < 16 orelse ShortSize * 2 < LongSize of
        true ->
            %% No point in looking.
            undefined;
        false ->
            %% Seed positions are quarter-way and half-way through Long,
            %% expressed as byte offsets (codepoints * 4).
            LongLen = LongSize div 4,  %% codepoint count
            Hm1 = half_match_i(Long, Short, ((LongLen + 3) div 4) * 4),
            Hm2 = half_match_i(Long, Short, ((LongLen + 1) div 2) * 4),

            %% Select the longest half-match.
            Hm = case {Hm1, Hm2} of
                     {undefined, undefined} -> 
                         undefined;
                     {undefined, _} -> 
                         Hm2;
                     {_, undefined} -> 
                         Hm1;
                     {{half_match, _, _, _, _, C1}, {half_match, _, _, _, _, C2}} when size(C1) > size(C2) ->
                         Hm1;
                     {_, _} ->
                         Hm2
                 end,

            %% Swap values if A was smaller than B
            case Hm of
                undefined -> undefined;
                {half_match, T1A, T1B, T2A, T2B, MidCommon} ->
                    case AgtB of
                        true -> Hm;
                        false ->
                            {half_match, T2A, T2B, T1A, T1B, MidCommon}
                    end
            end
    end.

% Find the best common overlap at location I.
half_match_i(Long, Short, I) ->
    {NewI, Seed} = seed(Long, I),
    case Seed of
        <<>> -> undefined;
        _ -> best_common(Long, Short, Seed, NewI, 0, <<>>, <<>>, <<>>, <<>>, <<>>) 
    end.

%% Find the best common overlap inside two texts.
best_common(Long, Short, Seed, SeedLoc, Start, 
        BestLongA, BestLongB, BestShortA, BestShortB, BestCommon) ->
    %% Check if we can find a match for Seed2 inside the shorttext.
    case aligned_utf32_match(Short, Seed, Start) of
        nomatch -> 
            case size(BestCommon) * 2 >= size(Long) of
                false -> 
                    undefined;
                true -> 
                    {half_match, BestLongA, BestLongB, BestShortA, BestShortB, BestCommon}
            end;
        {MatchStart, _} ->
            %% Because the seed is already at utf-8 boundaries this will work.
            <<LongPre:SeedLoc/binary, LongPost/binary>> = Long,
            <<ShortPre:MatchStart/binary, ShortPost/binary>> = Short,

            %% Note: This is a split on a utf8-char boundary.
            Suffix = common_suffix(LongPre, ShortPre),
            Prefix = common_prefix(LongPost, ShortPost),

	    PrefixSize = size(Prefix),
	    SuffixSize = size(Suffix),

            case size(BestCommon) < PrefixSize + SuffixSize of
                true ->
                    %% We have a new best common match
                    NewBestCommon = <<Suffix/binary, Prefix/binary>>,

		    A = SeedLoc - SuffixSize,
		    <<NewBestLongA:A/binary, _/binary>> = LongPre,
		    <<_:PrefixSize/binary, NewBestLongB/binary>> = LongPost,

		    B = MatchStart - SuffixSize,
		    <<NewBestShortA:B/binary, _/binary>> = ShortPre,
		    <<_:PrefixSize/binary, NewBestShortB/binary>> = ShortPost,

                    best_common(Long, Short, Seed, SeedLoc, next_char(Short, MatchStart), 
                        NewBestLongA, NewBestLongB, NewBestShortA, NewBestShortB, NewBestCommon);
                false ->
                    best_common(Long, Short, Seed, SeedLoc, next_char(Short, MatchStart), 
                        BestLongA, BestLongB, BestShortA, BestShortB, BestCommon)
            end
    end.

%% @doc Round a byte offset up to the next UTF-32 codepoint boundary.
align_utf32_offset(Offset) when Offset rem 4 =:= 0 ->
    Offset;
align_utf32_offset(Offset) ->
    Offset + (4 - (Offset rem 4)).

%% @doc Find a match whose start offset is aligned to a UTF-32 codepoint boundary.
aligned_utf32_match(Bin, Pattern, Start) ->
    AlignedStart = align_utf32_offset(Start),
    case AlignedStart >= size(Bin) of
        true ->
            nomatch;
        false ->
            case binary:match(Bin, Pattern, [{scope, {AlignedStart, size(Bin) - AlignedStart}}]) of
                nomatch ->
                    nomatch;
                {MatchStart, Length} when MatchStart rem 4 =:= 0 ->
                    {MatchStart, Length};
                {MatchStart, _Length} ->
                    aligned_utf32_match(Bin, Pattern, MatchStart + 1)
            end
    end.

%% @doc Return the byte position of the next codepoint in a UTF-32 binary.
next_char(_Bin, Pos) ->
    Pos + 4.

%%
%% In UTF-32 every codepoint is exactly 4 bytes. Start is always a 4-byte-aligned
%% byte offset, so no alignment step is needed.
seed(Long, Start) ->
    TotalCodepoints = size(Long) div 4,
    SeedCodepoints = TotalCodepoints div 4,
    SeedSize = SeedCodepoints * 4,
    <<_Pre:Start/binary, Seed:SeedSize/binary, _Post/binary>> = Long,
    {Start, Seed}.


%% Line diff
compute_diff1(Text1, Text2, true) ->
    diff_linemode32(Text1, Text2);
compute_diff1(Text1, Text2, false) when size(Text1) > 400 orelse size(Text2) > 400 ->
    %% 100 UTF-8 bytes ≈ 400 UTF-32 bytes (conservative upper bound)
    diff_linemode32(Text1, Text2);
compute_diff1(Text1, Text2, false) ->
    diff_bisect32(Text1, Text2).


%% Public entry: accepts UTF-8, converts at boundary.
diff_linemode(Text1, Text2) ->
    T1 = to_utf32(Text1),
    T2 = to_utf32(Text2),
    Diffs32 = diff_linemode32(T1, T2),
    [{Op, to_utf8(D)} || {Op, D} <- Diffs32].

%% Internal: operates entirely on UTF-32 binaries.
diff_linemode32(Text1, Text2) ->
    {CharText1, CharText2, Lines} = lines_to_chars(Text1, Text2),
    Diffs = diff32(CharText1, CharText2, false),

    %% Transform the diffs back to lines.
    Diffs1 = decode_lines(Diffs, Lines),

    Cleaned = cleanup_merge32(Diffs1),
    cleanup_line_diff(Cleaned, <<>>, <<>>, [], []).


%% Cleanup after a line based diff.
%%
cleanup_line_diff([], _, _, TmpAcc, Acc) ->
    lists:reverse(TmpAcc ++ Acc);

%% Concatenate the text found in insert and delete operations.
cleanup_line_diff([{insert, Data}=I|Rest], DeleteData, InsertData, TmpAcc, Acc) ->
    cleanup_line_diff(Rest, DeleteData, <<InsertData/binary, Data/binary>>, [I|TmpAcc], Acc);
cleanup_line_diff([{delete, Data}=D|Rest], DeleteData, InsertData, TmpAcc, Acc) ->
    cleanup_line_diff(Rest, <<DeleteData/binary, Data/binary>>, InsertData, [D|TmpAcc], Acc);

%% Found an equal without a leading insert and delete operations. Just pass
%% the operations
cleanup_line_diff([{equal, _}=E|Rest], DeleteData, InsertData, TmpAcc, Acc) 
	when DeleteData =:= <<>> orelse InsertData =:= <<>> ->
    Acc1 = TmpAcc ++ Acc,
    cleanup_line_diff(Rest, <<>>, <<>>, [], [E|Acc1]);

%% Found leading insert and delete data, diff the texts and replace the operations.
cleanup_line_diff([{equal, _}=E|Rest], DeleteData, InsertData, _TmpAcc, Acc) ->
    %% Data is already UTF-32 — pass directly to diff32.
    Diffs = diff32(DeleteData, InsertData, false),
    Acc1 = lists:reverse(Diffs) ++ Acc,
    cleanup_line_diff(Rest, <<>>, <<>>, [], [E|Acc1]).


%% Diff lines.
%% Text1 and Text2 are UTF-32 binaries. Lines are stored as UTF-32 binaries.
%% CharText1/CharText2 are UTF-32 binaries where each 4-byte word is a line index.
lines_to_chars(Text1, Text2) ->
    Utf8Text1 = to_utf8(Text1),
    Utf8Text2 = to_utf8(Text2),
    {CharText1, NextChar, Lines1, Map1} = lines_to_chars(Utf8Text1, 0, <<>>, 0, [], #{}),
    {CharText2, _, Lines2, _Map2} = lines_to_chars(Utf8Text2, 0, <<>>, NextChar, Lines1, Map1),

    {CharText1, CharText2, lists:reverse(Lines2)}.

%% Transform each unique line into a 4-byte index; store line content as UTF-32.
lines_to_chars(Text, Idx, CharText, NextChar, Lines, Map) when Idx >= byte_size(Text) ->
    {CharText, NextChar, Lines, Map};
lines_to_chars(Text, Idx, CharText, NextChar, Lines, Map) ->
    case binary:match(Text, <<"\n">>, [{scope, {Idx, byte_size(Text)-Idx}}]) of
        nomatch ->
            <<_:Idx/binary, Line/binary>> = Text,
            {Char, NextChar1, Lines1, Map1} = insert_line(to_utf32(Line), Lines, Map, NextChar),
            CharText1 = <<CharText/binary, Char:32>>,
            {CharText1, NextChar1, Lines1, Map1};
        {Start, _} ->
            LineLength = Start - Idx + 1,
            <<_:Idx/binary, Line:LineLength/binary, _/binary>> = Text,
            {Char, NextChar1, Lines1, Map1} = insert_line(to_utf32(Line), Lines, Map, NextChar),
            CharText1 = <<CharText/binary, Char:32>>,
            lines_to_chars(Text, Idx + LineLength, CharText1, NextChar1, Lines1, Map1)
    end.


insert_line(Line, Lines, Map, NextChar) ->
    case Map of
        #{Line := Char} ->
            {Char, NextChar, Lines, Map};
        _ ->
            {NextChar, NextChar + 1, [Line | Lines], Map#{Line => NextChar}}
    end.

decode_lines(Diffs, Lines) when is_list(Lines) ->
    LinesTuple = list_to_tuple(Lines),
    decode_lines(Diffs, LinesTuple, []).

decode_lines([], _LinesTuple, Acc) ->
    lists:reverse(Acc);
decode_lines([{Op, Data} | Rest], LinesTuple, Acc) ->
    %% Each index is a 32-bit word; lines are already UTF-32 — just concatenate.
    Data1 = << <<(element(C + 1, LinesTuple))/binary>> || <<C:32>> <= Data >>,
    decode_lines(Rest, LinesTuple, [{Op, Data1} | Acc]).


% Find the 'middle snake' of a diff, split the problem in two
%%      and return the recursively constructed diff.
%%      See Myers 1986 paper: An O(ND) Difference Algorithm and Its Variations.
%%
%%    Args:
%%      text1: Old string to be diffed.
%%      text2: New string to be diffed.
%%      deadline: Time at which to bail if not yet complete.
%%
%%    Returns:
%%      Array of diff tuples.
%%    """
%% Public entry point — converts UTF-8 inputs to UTF-32, runs bisect, converts back.
diff_bisect(A, B) when is_binary(A) andalso is_binary(B) ->
    Diffs32 = diff_bisect32(to_utf32(A), to_utf32(B)),
    [{Op, to_utf8(D)} || {Op, D} <- Diffs32].

%% Internal bisect working entirely on UTF-32 binaries.
diff_bisect32(A, B) ->
    M = byte_size(A) div 4,
    N = byte_size(B) div 4,
    try compute_diff_bisect1(A, B, M, N) of
        no_overlap -> [{delete, A}, {insert, B}]
    catch
        throw:{overlap, X, Y} ->
            diff_bisect_split(A, B, X, Y)
    end.

compute_diff_bisect1(A, B, M, N) ->
    %% TODO, add deadline... 
    
    MaxD = ceil((M + N) / 2),

    VOffset = MaxD,
    VLength = 2 * MaxD,

    V1 = array:set(VOffset + 1, 0, array:new(VLength, [{default, -1}])),
    
    Delta = M - N,

    % If the total number of characters is odd, then the front path will
    % collide with the reverse path.
    Front = (Delta rem 2 =/= 0),

    %% {K1Start, K1End, K2Start, K2End, V1, V2}
    State = #bisect_state{v1=V1, v2=V1},

    %% Loops
    for(0, MaxD, fun(D, S1) ->
        %% Walk the front path one step
        S3 = for(-D + S1#bisect_state.k1start, D + 1 - S1#bisect_state.k1end, 2, fun(K1, S2) ->
            K1Offset = VOffset + K1,

            X1 = case K1 =:= -D
                      orelse (K1 =/= D
                              andalso (array:get(K1Offset-1, S2#bisect_state.v1) < array:get(K1Offset+1, S2#bisect_state.v1)))
                 of
                     true -> array:get(K1Offset + 1, S2#bisect_state.v1);
                     false -> array:get(K1Offset - 1, S2#bisect_state.v1) + 1
                 end,

            Y1 = X1 - K1,
            {X1_1, Y1_1} = match_front(X1, Y1, A, M, B, N),
            S2_1 = S2#bisect_state{v1=array:set(K1Offset, X1_1, S2#bisect_state.v1)},
 
            if 
                X1_1 > M -> 
                    % Ran off the right of the graph...
                    V = S2_1#bisect_state.k1end + 2,
                    {continue, S2_1#bisect_state{k1end=V}};
                Y1_1 > N ->
                    % Ran off the bottom of the graph...
                    V = S2_1#bisect_state.k1start + 2,
                    {continue, S2_1#bisect_state{k1start=V}};
                Front =:= true ->
                    K2Offset = VOffset + Delta - K1,
                    case K2Offset < 0 orelse K2Offset >= VLength of
                        true -> {continue, S2_1};
                        false ->
                            V2AtOffset = array:get(K2Offset, S2_1#bisect_state.v2),
                            case V2AtOffset =/= -1 of
                                true ->
                                    % Mirror x2 onto top-left coordinate system.
                                    X2 = M - V2AtOffset,
                                    if 
                                        X1_1 >= X2 ->
                                            % Overlap detected
                                            throw({overlap, X1_1, Y1_1});
                                        true ->
                                            {continue, S2_1}
                                    end;
                                false -> {continue, S2_1}
                            end
                    end;
                true -> {continue, S2_1}
            end
        end, S1),

        %% Walk the reverse path one step. (verdacht hetzelfde als het ding hierboven...)
        S5 = for(-D + S3#bisect_state.k2start, D + 1 - S3#bisect_state.k2end, 2, fun(K2, S4) ->
            K2Offset = VOffset + K2,
            X2 = case K2 =:= -D
                      orelse (K2 =/= D
                              andalso array:get(K2Offset-1, S4#bisect_state.v2) < array:get(K2Offset+1, S4#bisect_state.v2))
                 of
                     true -> array:get(K2Offset + 1, S4#bisect_state.v2);
                     false -> array:get(K2Offset - 1, S4#bisect_state.v2) + 1
                 end,

            Y2 = X2 - K2,

            {X2_1, Y2_1} = match_reverse(X2, Y2, A, M, B, N),
            S4_1 = S4#bisect_state{v2=array:set(K2Offset, X2_1, S4#bisect_state.v2)},

            if 
                X2_1 > M -> 
                    % Ran off the right of the graph...
                    V = S4_1#bisect_state.k2end + 2,
                    {continue, S4_1#bisect_state{k2end=V}};
                Y2_1 > N ->
                    % Ran off the bottom of the graph...
                    V = S4_1#bisect_state.k2start + 2,
                    {continue, S4_1#bisect_state{k2start=V}};
                Front =:= false ->
                    K1Offset = VOffset + Delta - K2,
                    case K1Offset < 0 orelse K1Offset >= VLength of
                        true -> {continue, S4_1};
                        false ->
                            V1AtOffset = array:get(K1Offset, S4_1#bisect_state.v1),
                            case V1AtOffset =/= -1 of
                                true ->
                                    X1 = V1AtOffset,
                                    Y1 = VOffset + X1 - K1Offset,
                                    if 
                                        % Mirror x2 onto top-left coordinate system.
                                        X1 >= M - X2_1 ->
                                            % Overlap detected
                                            throw({overlap, X1, Y1});
                                        true ->
                                            {continue, S4_1}
                                    end;
                                false -> {continue, S4_1}
                            end
                    end;
                true -> {continue, S4_1}
            end
        end, S3),
        {continue, S5}
    end, State),

    no_overlap.

% @doc Split A and B at the overlap point and recursively diff each half.
diff_bisect_split(A, B, X, Y) ->
    A1 = binary:part(A, 0, X * 4),
    A2 = binary:part(B, 0, Y * 4),
    B1 = binary:part(A, X * 4, byte_size(A) - X * 4),
    B2 = binary:part(B, Y * 4, byte_size(B) - Y * 4),

    diff32(A1, A2, false) ++ diff32(B1, B2, false).

% @doc Convert the diffs into a pretty html report
pretty_html(Diffs) ->
    pretty_html(Diffs, []).

pretty_html([], Acc) ->
    lists:reverse(Acc);
pretty_html([{Op, Data} | T], Acc) ->
    Safe = html_escape(Data),
    HTML = case Op of
        insert ->
            [<<"<ins style='background:#e6ffe6;'>">>, Safe, <<"</ins>">>];
        delete ->
            [<<"<del style='background:#ffe6e6;'>">>, Safe, <<"</del>">>];
        equal ->
            [<<"<span>">>, Safe, <<"</span>">>]
    end,
    pretty_html(T, [HTML | Acc]).

-if(?OTP_RELEASE >= 27).
html_escape(B) when is_binary(B) ->
    binary:replace(B,
                   [<<"&">>, <<"<">>, <<">">>, <<"\"">>, <<"'">>],
                   fun (<<"&">>)   -> <<"&amp;">>;
                       (<<"<">>)   -> <<"&lt;">>;
                       (<<">">>)   -> <<"&gt;">>;
                       (<<"\"">>)  -> <<"&quot;">>;
                       (<<"'">>)   -> <<"&#39;">>
                   end,
                   [global]).
-else.
html_escape(B) when is_binary(B) ->
    lists:foldl(fun({From, To}, Acc) ->
                        binary:replace(Acc, From, To, [global])
                end,
                B,
                [
                 {<<"&">>,  <<"&amp;">>},
                 {<<"<">>,  <<"&lt;">>},
                 {<<">">>,  <<"&gt;">>},
                 {<<"\"">>, <<"&quot;">>},
                 {<<"'">>,  <<"&#39;">>}
                ]).
-endif.


% Above function can be replaced with this when OTP 27 is the lowest supported 
% @doc Compute the source text from a list of diffs.
source_text(Diffs) ->
    iolist_to_binary([Data || {Op, Data} <- Diffs, Op =/= insert]).

% @doc Compute the destination text from a list of diffs.
destination_text(Diffs) ->
    iolist_to_binary([Data || {Op, Data} <- Diffs, Op =/= delete]).
    
% @doc Compute the Levenshtein distance, the number of inserted, deleted or substituted characters.
levenshtein(Diffs) ->
    levenshtein(Diffs, 0, 0, 0).

levenshtein([], Insertions, Deletions, Levenshtein) ->
    Levenshtein + max(Insertions, Deletions);
levenshtein([{insert, Data}|T], Insertions, Deletions, Levenshtein) ->
    levenshtein(T, Insertions+text_size(Data), Deletions, Levenshtein);
levenshtein([{delete, Data}|T], Insertions, Deletions, Levenshtein) ->
    levenshtein(T, Insertions, Deletions+text_size(Data), Levenshtein);
levenshtein([{equal, _Data}|T], Insertions, Deletions, Levenshtein) ->
    levenshtein(T, 0, 0, Levenshtein+max(Insertions, Deletions)).


%@ @doc Cleanup diffs. 
% Remove empty operations, merge equal opearations, edits before equal operation and common prefix operations.
%
-spec cleanup_merge(diffs()) -> diffs().
cleanup_merge(Diffs) ->
    Diffs32 = [{Op, to_utf32(D)} || {Op, D} <- Diffs],
    [{Op, to_utf8(D)} || {Op, D} <- cleanup_merge32(Diffs32)].

%% Internal cleanup_merge operating on UTF-32 diffs.
cleanup_merge32(Diffs) ->
    Diffs1 = cleanup_merge32(Diffs, []),
    canonicalize_edits(Diffs1, []).

%% Done
cleanup_merge32([], Acc) ->
    lists:reverse(Acc);
%% Remove operations without data.
cleanup_merge32([{_Op, <<>>}|T], Acc) ->
    cleanup_merge32(T, Acc);
%% Merge data from equal operations
cleanup_merge32([{Op2, Data2}|T], [{Op1, Data1}|Acc]) when Op1 =:= Op2 ->
    cleanup_merge32(T, [{Op1, <<Data1/binary, Data2/binary>>}|Acc]);
%% Cleanup edits before equal operation
cleanup_merge32([{Op1, Data1}|T], [{Op2, _}=I, {Op3, Data3}|Acc]) when Op1 =/= Op2 andalso Op1 =:= Op3 andalso Op2 =/= equal andalso Op3 =/= equal ->
    cleanup_merge32(T, [I, {Op3, <<Data3/binary, Data1/binary>>}|Acc]);
%% Check if Op1Data and Op2Data have common prefixes.
cleanup_merge32([{equal, E1}|T], [{Op1, Op1Data}, {Op2, Op2Data}, {equal, E2}|Acc]) when Op1 =/= Op2 andalso Op1 =/= equal andalso Op2 =/= equal ->
    {Prefix, Op1DataD, Op2DataD, Suffix} = split_pre_and_suffix(Op1Data, Op2Data),
    cleanup_merge32(T, [{equal, <<Suffix/binary, E1/binary>>},
        {Op1, Op1DataD}, {Op2, Op2DataD}, {equal, <<E2/binary, Prefix/binary>>}|Acc]);
%% Check for slide left and slide right edits
cleanup_merge32([{equal, E1}=H|T], [{Op, I}, {equal, E2}|AccTail]=Acc) when Op =:= insert orelse Op =:= delete ->
    case is_suffix(E2, I) of
        false ->
            case is_prefix(E1, I) of
                false ->
                    cleanup_merge32(T, [H|Acc]);
                true ->
                    P = size(E1),
                    <<_:P/binary, Post/binary>> = I,
                    cleanup_merge32([{equal, <<E2/binary, E1/binary>>}, {Op, <<Post/binary, E1/binary>>}|T], AccTail)
            end;
        true ->
            R = size(I) - size(E2),
            <<Pre:R/binary, Post/binary>> = I,
            cleanup_merge32([{Op, <<E2/binary, Pre/binary>>}, {equal, <<Post/binary, E1/binary>>}|T], AccTail)
    end;
cleanup_merge32([H|T], Acc) ->
    cleanup_merge32(T, [H|Acc]).

canonicalize_edits([{insert, I}, {delete, D} | T], Acc) ->
    canonicalize_edits(T, [{insert, I}, {delete, D} | Acc]);
canonicalize_edits([H | T], Acc) ->
    canonicalize_edits(T, [H | Acc]);
canonicalize_edits([], Acc) ->
    lists:reverse(Acc).

% @doc Do semantic cleanup of diffs
%
-spec cleanup_semantic(diffs()) -> diffs().
cleanup_semantic(Diffs) ->
    Diffs32 = [{Op, to_utf32(D)} || {Op, D} <- Diffs],
    [{Op, to_utf8(D)} || {Op, D} <- cleanup_semantic32(Diffs32)].

%% Internal semantic cleanup operating on UTF-32 diffs.
cleanup_semantic32(Diffs) ->
    Diffs1 = cleanup_semantic_breakpoints(Diffs),
    Diffs2 = cleanup_merge32(Diffs1),
    Diffs3 = cleanup_semantic_lossless(Diffs2),
    cleanup_semantic_overlaps(Diffs3).

cleanup_semantic_breakpoints(Diffs) ->
    case find_breakpoint(Diffs, [], 0, 0, 0, 0, undefined) of
        {found, NewDiffs} -> cleanup_semantic_breakpoints(NewDiffs);
        not_found -> Diffs
    end.

find_breakpoint([], _Acc, _LI1, _LD1, _LI2, _LD2, _LE) ->
    not_found;
find_breakpoint([{equal, Data} | T], Acc, _LI1, _LD1, LI2, LD2, _LE) ->
    find_breakpoint(T, [{equal, Data} | Acc], LI2, LD2, 0, 0, Data);
find_breakpoint([{insert, Data} | T], Acc, LI1, LD1, LI2, LD2, LE) ->
    NewLI2 = LI2 + text_size32(Data),
    case is_breakpoint(LE, LI1, LD1, NewLI2, LD2) of
        true -> {found, apply_breakpoint(LE, Acc, [{insert, Data} | T])};
        false -> find_breakpoint(T, [{insert, Data} | Acc], LI1, LD1, NewLI2, LD2, LE)
    end;
find_breakpoint([{delete, Data} | T], Acc, LI1, LD1, LI2, LD2, LE) ->
    NewLD2 = LD2 + text_size32(Data),
    case is_breakpoint(LE, LI1, LD1, LI2, NewLD2) of
        true -> {found, apply_breakpoint(LE, Acc, [{delete, Data} | T])};
        false -> find_breakpoint(T, [{delete, Data} | Acc], LI1, LD1, LI2, NewLD2, LE)
    end.

is_breakpoint(undefined, _, _, _, _) -> false;
is_breakpoint(LE, LI1, LD1, LI2, LD2) ->
    LEN = text_size32(LE),
    LEN =< max(LI1, LD1) andalso LEN =< max(LI2, LD2).

apply_breakpoint(LE, Acc, T) ->
    replace_equality(LE, Acc, T).

replace_equality(LE, [{equal, LE} | T_Acc], T) ->
    lists:reverse(T_Acc) ++ [{delete, LE}, {insert, LE} | T];
replace_equality(LE, [H | T_Acc], T) ->
    replace_equality(LE, T_Acc, [H | T]).

cleanup_semantic_lossless(Diffs) ->
    cleanup_semantic_lossless(Diffs, []).

cleanup_semantic_lossless([{equal, E1}, {Op, Edit}, {equal, E2} | T], Acc) when ?IS_INS_OR_DEL(Op) ->
    {NewE1, NewEdit, NewE2} = slide_edit(E1, Edit, E2),
    case NewE1 of
        <<>> ->
            cleanup_semantic_lossless(lists:reverse(Acc, [{Op, NewEdit}, {equal, NewE2} | T]), []);
        _ ->
            case NewE2 of
                <<>> ->
                    cleanup_semantic_lossless(lists:reverse(Acc, [{equal, NewE1}, {Op, NewEdit} | T]), []);
                _ ->
                    cleanup_semantic_lossless([{Op, NewEdit}, {equal, NewE2} | T], [{equal, NewE1} | Acc])
            end
    end;
cleanup_semantic_lossless([H | T], Acc) ->
    cleanup_semantic_lossless(T, [H | Acc]);
cleanup_semantic_lossless([], Acc) ->
    lists:reverse(Acc).

slide_edit(E1, Edit, E2) ->
    Suffix = common_suffix(E1, Edit),
    {E1_1, Edit_1, E2_1} = case Suffix of
        <<>> -> {E1, Edit, E2};
        _ ->
            SLen = size(Suffix),
            { binary:part(E1, 0, size(E1) - SLen),
              <<Suffix/binary, (binary:part(Edit, 0, size(Edit) - SLen))/binary>>,
              <<Suffix/binary, E2/binary>> }
    end,
    find_best_slide(E1_1, Edit_1, E2_1).

find_best_slide(E1, Edit, E2) ->
    Score = cleanup_semantic_score(E1, Edit) + cleanup_semantic_score(Edit, E2),
    find_best_slide(E1, Edit, E2, Score, E1, Edit, E2).

find_best_slide(E1, Edit, E2, BestScore, BestE1, BestEdit, BestE2) ->
    case can_slide_right(Edit, E2) of
        {true, Char, RestEdit, RestE2} ->
            NewE1 = <<E1/binary, Char/binary>>,
            NewEdit = <<RestEdit/binary, Char/binary>>,
            NewE2 = RestE2,
            NewScore = cleanup_semantic_score(NewE1, NewEdit) + cleanup_semantic_score(NewEdit, NewE2),
            if
                NewScore >= BestScore ->
                    find_best_slide(NewE1, NewEdit, NewE2, NewScore, NewE1, NewEdit, NewE2);
                true ->
                    find_best_slide(NewE1, NewEdit, NewE2, BestScore, BestE1, BestEdit, BestE2)
            end;
        false ->
            {BestE1, BestEdit, BestE2}
    end.

%% In UTF-32 each codepoint is exactly 4 bytes — no pattern matching on variable-width needed.
can_slide_right(<<Char:32, RestEdit/binary>>, <<Char:32, RestE2/binary>>) ->
    {true, <<Char:32>>, RestEdit, RestE2};
can_slide_right(_, _) ->
    false.

cleanup_semantic_score(<<>>, _) -> 6;
cleanup_semantic_score(_, <<>>) -> 6;
cleanup_semantic_score(One, Two) ->
    Char1 = last_char(One),
    Char2 = first_char(Two),
    NonAlphaNumeric1 = is_non_alphanumeric(Char1),
    NonAlphaNumeric2 = is_non_alphanumeric(Char2),
    Whitespace1 = NonAlphaNumeric1 andalso is_whitespace(Char1),
    Whitespace2 = NonAlphaNumeric2 andalso is_whitespace(Char2),
    LineBreak1 = Whitespace1 andalso is_linebreak(Char1),
    LineBreak2 = Whitespace2 andalso is_linebreak(Char2),
    BlankLine1 = LineBreak1 andalso is_blankline_end(One),
    BlankLine2 = LineBreak2 andalso is_blankline_start(Two),
    if
        BlankLine1 orelse BlankLine2 -> 5;
        LineBreak1 orelse LineBreak2 -> 4;
        NonAlphaNumeric1 andalso (not Whitespace1) andalso Whitespace2 -> 3;
        Whitespace1 orelse Whitespace2 -> 2;
        NonAlphaNumeric1 orelse NonAlphaNumeric2 -> 1;
        true -> 0
    end.

cleanup_semantic_overlaps(Diffs) ->
    cleanup_semantic_overlaps(Diffs, []).

cleanup_semantic_overlaps([{delete, Del}, {insert, Ins} | T], Acc) ->
    Overlap1 = common_overlap(Del, Ins),
    Overlap2 = common_overlap(Ins, Del),
    TDel = text_size32(Del),
    TIns = text_size32(Ins),
    if
        Overlap1 >= Overlap2 ->
            if
                Overlap1 * 2 >= TDel orelse Overlap1 * 2 >= TIns ->
                    Common = binary:part(Ins, 0, Overlap1 * 4),
                    NewDel = binary:part(Del, 0, (TDel - Overlap1) * 4),
                    NewIns = binary:part(Ins, Overlap1 * 4, (TIns - Overlap1) * 4),
                    cleanup_semantic_overlaps([{insert, NewIns} | T], [{equal, Common}, {delete, NewDel} | Acc]);
                true ->
                    cleanup_semantic_overlaps([{insert, Ins} | T], [{delete, Del} | Acc])
            end;
        true ->
            if
                Overlap2 * 2 >= TIns orelse Overlap2 * 2 >= TDel ->
                    Common = binary:part(Ins, (TIns - Overlap2) * 4, Overlap2 * 4),
                    NewIns = binary:part(Ins, 0, (TIns - Overlap2) * 4),
                    NewDel = binary:part(Del, Overlap2 * 4, (TDel - Overlap2) * 4),
                    cleanup_semantic_overlaps([{delete, NewDel} | T], [{equal, Common}, {insert, NewIns} | Acc]);
                true ->
                    cleanup_semantic_overlaps([{insert, Ins} | T], [{delete, Del} | Acc])
            end
    end;
cleanup_semantic_overlaps([H | T], Acc) ->
    cleanup_semantic_overlaps(T, [H | Acc]);
cleanup_semantic_overlaps([], Acc) ->
    lists:reverse(Acc).

%% In UTF-32 every codepoint is exactly 4 bytes, so all byte/codepoint conversions
%% are simple multiplications and binary:part calls.

%% @doc Return the first Len codepoints of Bin as a binary.
substring_start(Bin, Len) ->
    binary:part(Bin, 0, Len * 4).

%% @doc Return the last Len codepoints of Bin as a binary.
substring_end(Bin, Len) ->
    TotalLen = text_size32(Bin),
    case TotalLen =< Len of
        true -> Bin;
        false -> binary:part(Bin, (TotalLen - Len) * 4, Len * 4)
    end.

common_overlap(<<>>, _) -> 0;
common_overlap(_, <<>>) -> 0;
common_overlap(Text1, Text2) ->
    T1Len = text_size32(Text1),
    T2Len = text_size32(Text2),
    {T1, T2, TMin} = if
        T1Len > T2Len -> {substring_end(Text1, T2Len), Text2, T2Len};
        T1Len < T2Len -> {Text1, substring_start(Text2, T1Len), T1Len};
        true -> {Text1, Text2, T1Len}
    end,
    case T1 =:= T2 of
        true -> TMin;
        false -> common_overlap_loop(T1, T2, TMin, 0, 1)
    end.

common_overlap_loop(T1, T2, TMin, Best, Length) when Length =< TMin ->
    Pattern = substring_end(T1, Length),
    case binary:match(T2, Pattern) of
        nomatch -> Best;
        {FoundByteOffset, _} ->
            %% In UTF-32, byte offset maps directly to codepoint count.
            FoundCharCount = FoundByteOffset div 4,
            NewLength = Length + FoundCharCount,
            if
                NewLength > TMin -> Best;
                true ->
                    case substring_end(T1, NewLength) =:= substring_start(T2, NewLength) of
                        true ->
                            common_overlap_loop(T1, T2, TMin, NewLength, NewLength + 1);
                        false ->
                            common_overlap_loop(T1, T2, TMin, Best, NewLength + 1)
                    end
            end
    end;
common_overlap_loop(_T1, _T2, _TMin, Best, _Length) ->
    Best.

%% In UTF-32 the first and last codepoints are always at fixed byte offsets.
first_char(<<C:32, _/binary>>) -> C;
first_char(_) -> undefined.

last_char(<<>>) -> undefined;
last_char(Bin) ->
    Size = byte_size(Bin),
    <<_:(Size-4)/binary, C:32>> = Bin,
    C.

is_non_alphanumeric(undefined) -> true;
is_non_alphanumeric(C) ->
    not ((C >= $a andalso C =< $z) orelse
         (C >= $A andalso C =< $Z) orelse
         (C >= $0 andalso C =< $9)).

is_whitespace(undefined) -> false;
is_whitespace(C) ->
    case C of
        $\s -> true;
        $\t -> true;
        $\n -> true;
        $\r -> true;
        $\f -> true;
        $\v -> true;
        _ -> false
    end.

is_linebreak(C) ->
    C =:= $\n orelse C =:= $\r.

%% In UTF-32 each codepoint is 4 bytes, so newline patterns are fixed-width.
is_blankline_end(Bin) when byte_size(Bin) >= 8 ->
    Size = byte_size(Bin),
    case Bin of
        <<_:(Size-8)/binary,  $\n:32, $\n:32>>       -> true;
        <<_:(Size-12)/binary, $\n:32, $\r:32, $\n:32>> -> true;
        _ -> false
    end;
is_blankline_end(_) -> false.

is_blankline_start(Bin) when byte_size(Bin) >= 8 ->
    case Bin of
        <<$\n:32, $\n:32, _/binary>>             -> true;
        <<$\n:32, $\r:32, $\n:32, _/binary>>     -> true;
        <<$\r:32, $\n:32, $\n:32, _/binary>>     -> true;
        <<$\r:32, $\n:32, $\r:32, $\n:32, _/binary>> -> true;
        _ -> false
    end;
is_blankline_start(_) -> false.

% @doc Do efficiency cleanup of diffs.
%
-spec cleanup_efficiency(diffs()) -> diffs().
cleanup_efficiency(Diffs) ->
    cleanup_efficiency(Diffs, 4).

-spec cleanup_efficiency(diffs(), pos_integer()) -> diffs().
cleanup_efficiency(Diffs, EditCost) ->
    Diffs32 = [{Op, to_utf32(D)} || {Op, D} <- Diffs],
    [{Op, to_utf8(D)} || {Op, D} <- cleanup_efficiency32(Diffs32, EditCost)].

%% Internal efficiency cleanup operating on UTF-32 diffs.
cleanup_efficiency32(Diffs) ->
    cleanup_efficiency32(Diffs, 4).

cleanup_efficiency32(Diffs, EditCost) ->
    cleanup_efficiency32(Diffs, false, EditCost, []).

%% Done.
cleanup_efficiency32([], Changed, _EditCost, Acc) ->
    Diffs = lists:reverse(Acc),
    case Changed of
        false -> Diffs;
        true -> cleanup_merge32(Diffs)
    end;
%% Any equality which is surrounded on both sides by an insertion and deletion need less then 
%% EditCost characters for it to be advantageous to split.
cleanup_efficiency32([{O1, _}=A, {equal, XY}=E, {O2, _}=B | T], Changed, EditCost, Acc) when 
        O1 =/= O2 andalso ?IS_INS_OR_DEL(O1) andalso ?IS_INS_OR_DEL(O2) ->
    case text_smaller_than(XY, EditCost) of
        true ->
            Del = {delete, XY},
            Ins = {insert, XY},
            cleanup_efficiency32([Ins, B | T], true, EditCost, [Del, A | Acc]);
        false ->
            cleanup_efficiency32([B | T], Changed, EditCost, [E, A | Acc])
    end;
%% Any equality which is surrounded on one side by an existing insertion and deletion and on the 
%% other side by an existing insertion or deletion needs less than half C characters long for it 
%% to be advantageous to split.
cleanup_efficiency32([{O1, _}=A, {O2, _}=B, {equal, X}=E, {O3, _}=C | T], Changed, EditCost, Acc) when
    O1 =/= O2 andalso ?IS_INS_OR_DEL(O1) andalso ?IS_INS_OR_DEL(O2) andalso ?IS_INS_OR_DEL(O3) ->
    case text_smaller_than(X, EditCost div 2 + 1) of
        true ->
            Del = {delete, X},
            Ins = {insert, X},
            cleanup_efficiency32([Ins, C | T], true, EditCost, [Del, B, A | Acc]);
        false ->
            cleanup_efficiency32([B, E, C | T], Changed, EditCost, [A | Acc])
    end;
cleanup_efficiency32([H | T], Changed, EditCost, Acc) ->
    cleanup_efficiency32(T, Changed, EditCost, [H | Acc]).


% @doc create a patch from a list of diffs
make_patch(Diffs) when is_list(Diffs) ->
    %% Reconstruct the source-text from the diffs.
    make_patch(Diffs, source_text(Diffs)).

% @doc create a patch from the source and destination texts
make_patch(SourceText, DestinationText) when is_binary(SourceText) andalso is_binary(DestinationText) ->
    Diffs = diff(SourceText, DestinationText),
    Diffs1 = cleanup_semantic(Diffs),
    Diffs2 = cleanup_efficiency(Diffs1),
    make_patch(Diffs2, SourceText);

% @doc Creata a patch from a list of diffs and the source text.
make_patch(Diffs, SourceText) when is_list(Diffs) andalso is_binary(SourceText) ->
    make_patch(Diffs, SourceText, SourceText, 0, 0, [#patch{}]).

make_patch([], _PrePatchText, _PostPatchText, _Count1, _Count2, [Patch|Rest]=Patches) ->
    case Patch#patch.diffs of
        [] -> lists:reverse(Rest);
        _ -> lists:reverse(Patches)
    end;
    
make_patch([{insert, Data}=D|T], PrePatchText, PostPatchText, Count1, Count2, [Patch|Rest]) ->
    Diffs = [D|Patch#patch.diffs],
    Size = size(Data),

    L = Patch#patch.length2 + Size,
    P = Patch#patch{diffs=Diffs, length2=L},

    %% Insert the text into the postpatch text.
    <<Pre:Count2/binary, Post/binary>> = PostPatchText,
    NewPostPatchText = <<Pre/binary, Data/binary, Post/binary>>,

    make_patch(T, PrePatchText, NewPostPatchText, Count1, Count2+Size, [P|Rest]);

make_patch([{delete, Data}=D|T], PrePatchText, PostPatchText, Count1, Count2, [Patch|Rest]) ->
    Diffs = [D|Patch#patch.diffs],
    Size = size(Data),

    L = Patch#patch.length1 + Size,
    P = Patch#patch{diffs=Diffs, length1=L},

    %% Remove the piece of text.
    <<Pre:Count2/binary, _:Size/binary, Post/binary>> = PostPatchText,
    NewPostPatchText = <<Pre/binary, Post/binary>>,
    
    make_patch(T, PrePatchText, NewPostPatchText, Count1+Size, Count2, [P|Rest]);

make_patch([{equal, Data}|T], PrePatchText, PostPatchText, Count1, Count2, [Patch|Rest]) ->
    Diffs = Patch#patch.diffs,
    Size = size(Data),

    case Size >= 2 * ?PATCH_MARGIN of
        true ->
            case Diffs of
                [] ->
                    throw(not_yet);
                _ ->
                    % Time for a new patch.
                    throw(not_yet)
            end;
        false ->
            throw(not_yet)
    end,

    L1 = Patch#patch.length1 + Size,
    L2 = Patch#patch.length2 + Size,
    
    P = Patch#patch{diffs=Diffs, length1=L1, length2=L2},
        
    make_patch(T, PrePatchText, PostPatchText, Count1+Size, Count2+Size, [P|Rest]).

    
% @doc Returns true iff Pattern is a unique match inside Text.
unique_match(Pattern, Text) ->
    TextSize = size(Text),
    case binary:match(Text, Pattern) of
        nomatch -> 
            error(nomatch);
        {Start, Length} when Start + 1 + Length < TextSize ->
            %% We have a match, and we can search..
            case binary:match(Text, Pattern, [{scope, {Start+1, TextSize-Start-1}}]) of
                nomatch -> true;
                {_, _} -> false
            end;
        {_, _} ->
            true
    end.


%%
%% Helpers
%%

% @doc Return true iff A is a prefix of B
is_prefix(A, B) when size(A) > size(B) ->
    false;
is_prefix(A, B) ->
    size(A) =:= binary:longest_common_prefix([A,B]).

% @doc Return true iff A is a suffix of B
is_suffix(A, B) when size(A) > size(B) ->
    false;
is_suffix(A, B) ->
    size(A) =:= binary:longest_common_suffix([A, B]).

%
match_front(X1, Y1, A32, M, B32, N) when X1 < M andalso Y1 < N ->
    APart = binary:part(A32, X1 * 4, (M - X1) * 4),
    BPart = binary:part(B32, Y1 * 4, (N - Y1) * 4),
    Steps = binary:longest_common_prefix([APart, BPart]) div 4,
    {X1 + Steps, Y1 + Steps};
match_front(X1, Y1, _, _, _, _) ->
    {X1, Y1}.

%
match_reverse(X2, Y2, A32, M, B32, N) when X2 < M andalso Y2 < N ->
    APart = binary:part(A32, 0, (M - X2) * 4),
    BPart = binary:part(B32, 0, (N - Y2) * 4),
    Steps = binary:longest_common_suffix([APart, BPart]) div 4,
    {X2 + Steps, Y2 + Steps};
match_reverse(X2, Y2, _, _, _, _) ->
    {X2, Y2}.


%% Implementation of the for statement
for(From, To, Fun, State) ->
    for(From, To, 1, Fun, State).

-spec for(integer(), integer(), integer(), for_fun(), term()) -> term().
for(From, To, _Step, _Fun, State) when From >= To ->
    State;
for(From, To, Step, Fun, State) ->
    case Fun(From, State) of
        {continue, S1} -> for(From + Step, To, Step, Fun, S1);
        {break, S1} -> S1
    end.

split_pre_and_suffix(Text1, Text2) ->
    Prefix = common_prefix(Text1, Text2),
    PrefixLen = size(Prefix),

    <<_:PrefixLen/binary, TailText1/binary>> = Text1,
    <<_:PrefixLen/binary, TailText2/binary>> = Text2,

    Suffix = common_suffix(TailText1, TailText2),
    SuffixLen = size(Suffix),

    MiddleText1 = binary:part(TailText1, 0, size(TailText1) - SuffixLen), 
    MiddleText2 = binary:part(TailText2, 0, size(TailText2) - SuffixLen), 

    {Prefix, MiddleText1, MiddleText2, Suffix}.

    
% @doc Return the common prefix of Text1 and Text2. Works on UTF-32 — always codepoint-aligned.
common_prefix(Text1, Text2) ->
    Length = binary:longest_common_prefix([Text1, Text2]),
    %% Round down to 4-byte boundary (should already be aligned for valid UTF-32).
    binary:part(Text1, 0, (Length div 4) * 4).

% @doc Return the common suffix of Text1 and Text2. Works on UTF-32 — always codepoint-aligned.
common_suffix(Text1, Text2) ->
    Length = binary:longest_common_suffix([Text1, Text2]),
    binary:part(Text1, byte_size(Text1), -((Length div 4) * 4)).


% @doc Count the number of codepoints in a UTF-8 binary.
% @deprecated Use text_size32/1 internally. This public function may be removed in a future version.
-spec text_size(unicode:unicode_binary()) -> non_neg_integer().
text_size(Text) when is_binary(Text) ->
    byte_size(to_utf32(Text)) div 4.

% @doc Count the number of codepoints in a UTF-32 binary. O(1).
text_size32(Text) when is_binary(Text) ->
    byte_size(Text) div 4.

% @doc Return true iff Text has fewer than Size codepoints. O(1) for UTF-32.
text_smaller_than(_, 0) ->
    false;
text_smaller_than(Text, Size) ->
    byte_size(Text) < Size * 4.

%%
%% UTF-32 boundary helpers
%%

% @doc Convert a UTF-8 binary to UTF-32, crashing on invalid input.
to_utf32(Bin) ->
    case unicode:characters_to_binary(Bin, utf8, utf32) of
        Out when is_binary(Out) ->
            Out;
        {error, _, _} ->
            error(badarg);
        {incomplete, _, _} ->
            error(badarg)
    end.

% @doc Convert a UTF-32 binary to UTF-8, crashing on invalid input.
to_utf8(Bin) ->
    case unicode:characters_to_binary(Bin, utf32, utf8) of
        Out when is_binary(Out) ->
            Out;
        {error, _, _} ->
            error(badarg);
        {incomplete, _, _} ->
            error(badarg)
    end.

%%
%% Tests
%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").

for_test() ->
    ?assertEqual(9, for(0, 10, fun(I, _N) -> {continue, I} end, undefined)),
    ?assertEqual(0, for(0, 10, fun(I, _N) -> {break, I} end, undefined)),
    ok.

diff_utf8_test() ->
    ?assertEqual([{equal, <<208,174, 208,189, 208,184, 208,186, 208,190, 208,180>>}], 
        diff(<<208,174,208,189,208,184,208,186,208,190,208,180>>, 
	     <<208,174,208,189,208,184,208,186,208,190,208,180>>)),

    ?assertEqual([{insert, <<208,174,208,189,208,184,208,186,208,190,208,180>>}], 
        diff(<<>>, <<208,174,208,189,208,184,208,186,208,190,208,180>>)),
    ?assertEqual([{delete, <<208,174,208,189,208,184,208,186,208,190,208,180>>}], 
        diff(<<208,174,208,189,208,184,208,186,208,190,208,180>>, <<>>)),

    ?assertEqual([{equal, <<229/utf8>>},
                  {delete, <<228/utf8>>},
                  {equal, <<246/utf8, 251/utf8>>}], 
         diff(<<229/utf8, 228/utf8, 246/utf8, 251/utf8>>, 
              <<229/utf8, 246/utf8, 251/utf8>>)),

    ok.

diff_bisect_test() ->
    ?assertEqual([{equal,<<"fruit flies ">>},
                  {delete,<<"lik">>},
                  {equal,<<"e">>},
                  {insert,<<"at">>},
                  {equal,<<" a banana">>}], diff_bisect(<<"fruit flies like a banana">>, 
                                                        <<"fruit flies eat a banana">>)),

    ?assertEqual([{delete,<<"c">>},
                  {insert,<<"m">>},
                  {equal,<<"a">>},
                  {delete,<<"t">>},
                  {insert,<<"p">>}],
                  diff_bisect(<<"cat">>, <<"map">>)), 

    ?assertEqual([{equal,<<"cat ">>},
                  {insert,<<"mouse dog sheep ">>},
                  {insert,<<"monkey chicken ">>},
                  {equal,<<"zebra">>}
                 ], diff_bisect(<<"cat zebra">>, <<"cat mouse dog sheep monkey chicken zebra">>)), 

    ?assertEqual([{equal, <<"text">>}],
                 diff_bisect(<<"text">>, <<"text">>)),

    ok.

%% half_match operates on UTF-32 internally; wrap inputs/outputs for testing.
half_match_utf8(A, B) ->
    case half_match(to_utf32(A), to_utf32(B)) of
        undefined -> undefined;
        {half_match, A1, A2, B1, B2, C} ->
            {half_match, to_utf8(A1), to_utf8(A2), to_utf8(B1), to_utf8(B2), to_utf8(C)}
    end.

half_match_test() ->
    ?assertEqual(undefined, half_match_utf8(<<"1234567890">>, <<"abcdef">>)), ?assertEqual(undefined, half_match_utf8(<<"12345">>, <<"23">>)),

    %% Single Match
    ?assertEqual({half_match, <<"12">>, <<"90">>, <<"a">>, <<"z">>, <<"345678">>}, half_match_utf8(<<"1234567890">>, <<"a345678z">>)),
    ?assertEqual({half_match, <<"a">>, <<"z">>, <<"12">>, <<"90">>, <<"345678">>}, 
        half_match_utf8(<<"a345678z">>, <<"1234567890">>)),
    ?assertEqual({half_match, <<"abc">>, <<"z">>, <<"1234">>, <<"0">>, <<"56789">>}, 
        half_match_utf8(<<"abc56789z">>, <<"1234567890">>)),
    ?assertEqual({half_match, <<"a">>, <<"xyz">>, <<"1">>, <<"7890">>, <<"23456">>}, 
        half_match_utf8(<<"a23456xyz">>, <<"1234567890">>)),

    %% Multiple Matches
    ?assertEqual({half_match, <<"12123">>, <<"123121">>, <<"a">>, <<"z">>, <<"1234123451234">>}, 
        half_match_utf8(<<"121231234123451234123121">>, <<"a1234123451234z">>)),

    ?assertEqual({half_match, <<"">>, <<"-=-=-=-=-=">>, <<"x">>, <<"">>, <<"x-=-=-=-=-=-=-=">>}, 
        half_match_utf8(<<"x-=-=-=-=-=-=-=-=-=-=-=-=">>, <<"xx-=-=-=-=-=-=-=">>)),

    ?assertEqual({half_match, <<"-=-=-=-=-=">>, <<"">>, <<"">>, <<"y">>, <<"-=-=-=-=-=-=-=y">>}, 
        half_match_utf8(<<"-=-=-=-=-=-=-=-=-=-=-=-=y">>, <<"-=-=-=-=-=-=-=yy">>)),

    ?assertEqual({half_match, <<"qHillo">>, <<"w">>, <<"x">>, <<"Hulloy">>, <<"HelloHe">>}, 
        half_match_utf8(<<"qHilloHelloHew">>, <<"xHelloHeHulloy">>)),

    ?assertEqual({half_match, <<"qHillo"/utf8>>, <<"w"/utf8>>, <<"x"/utf8>>, <<"eHull💯y"/utf8>>, <<"🐶🐱🐭🐹🐰H❤️"/utf8>>}, 
        half_match_utf8(<<"qHillo🐶🐱🐭🐹🐰H❤️w"/utf8>>, <<"x🐶🐱🐭🐹🐰H❤️eHull💯y"/utf8>>)),

    %% Unicode: é is 2 UTF-8 bytes but 1 codepoint (4 UTF-32 bytes).
    %% With the old bug, size(Long) div 4 gave the wrong seed position
    %% because byte_size in UTF-32 ≠ codepoint_count for multi-byte UTF-8 chars.
    %% Long = éééééééééé (10 chars), Short = a + éééééééé + z (10 chars).
    %% half_match should find the 8-char common section of é's.
    E = <<233/utf8>>,
    ULong = binary:copy(E, 10),
    UShort = <<"a", (binary:copy(E, 8))/binary, "z">>,
    UDiff = diff(ULong, UShort),
    ?assertEqual(ULong, source_text(UDiff)),
    ?assertEqual(UShort, destination_text(UDiff)),
    %% The 8-char run of é must appear as a single equal op.
    Equal8 = binary:copy(E, 8),
    ?assert(lists:member({equal, Equal8}, UDiff)),

    ok.

%% common_prefix/suffix operate on UTF-32; wrap for testing.
common_prefix_test() ->
    Prefix = fun(A, B) -> to_utf8(common_prefix(to_utf32(A), to_utf32(B))) end,

    ?assertEqual(<<>>, Prefix(<<"Text">>, <<"Next">>)),
    ?assertEqual(<<"T">>, Prefix(<<"Text">>, <<"Tax">>)),
    ?assertEqual(<<"text">>, Prefix(<<"text">>, <<"text">>)),

    ?assertEqual(<<"test🟡"/utf8>>, Prefix(<<"test🟡123"/utf8>>, <<"test🟡456"/utf8>>)),
    ?assertEqual(<<"test">>, Prefix(<<"test🟢123"/utf8>>, <<"test🟡123"/utf8>>)),
    ?assertEqual(<<"test">>, Prefix(<<"test🟡123"/utf8>>, <<"test🟢123"/utf8>>)),
    ?assertEqual(<<"test">>, Prefix(<<"test🟡123"/utf8>>, <<"test🔵123"/utf8>>)),
    ?assertEqual(<<"test">>, Prefix(<<"test🔵123"/utf8>>, <<"test🟡123"/utf8>>)),
    ?assertEqual(<<"test">>, Prefix(<<"test🟡123"/utf8>>, <<"test⚫️123"/utf8>>)),
    ?assertEqual(<<"test">>, Prefix(<<"test⚫️123"/utf8>>, <<"test🟡123"/utf8>>)),

    ok.

common_suffix_test() ->
    Suffix = fun(A, B) -> to_utf8(common_suffix(to_utf32(A), to_utf32(B))) end,

    ?assertEqual(<<"ext">>, Suffix(<<"Text">>, <<"Next">>)),
    ?assertEqual(<<>>, Suffix(<<"Text">>, <<"Tax">>)),
    ?assertEqual(<<"text">>, Suffix(<<"text">>, <<"text">>)),
    ok.

%% split_pre_and_suffix operates on UTF-32; wrap for testing.
split_pre_and_suffix_test() ->
    Split = fun(A, B) ->
        {P, M1, M2, S} = split_pre_and_suffix(to_utf32(A), to_utf32(B)),
        {to_utf8(P), to_utf8(M1), to_utf8(M2), to_utf8(S)}
    end,

    ?assertEqual({<<>>, <<>>, <<>>, <<>>}, Split(<<>>, <<>>)),
    ?assertEqual({<<>>, <<"a">>, <<"b">>, <<>>}, Split(<<"a">>, <<"b">>)),
    ?assertEqual({<<"a">>, <<"b">>, <<"c">>, <<"d">>}, Split(<<"abd">>, <<"acd">>)),
    ?assertEqual({<<"aa">>, <<"bb">>, <<"cc">>, <<"dd">>}, Split(<<"aabbdd">>, <<"aaccdd">>)),
    ?assertEqual({<<"aa">>, <<"bb">>, <<"c">>, <<"dd">>}, Split(<<"aabbdd">>, <<"aacdd">>)),
    ?assertEqual({<<"cat ">>, <<>>, <<"mouse dog ">>, <<>>},
                 Split(<<"cat ">>, <<"cat mouse dog ">>)),
    ok.

unique_match_test() ->
    ?assertEqual(true, unique_match(<<"a">>, <<"abc">>)),
    ?assertEqual(true, unique_match(<<"b">>, <<"abc">>)),
    ?assertEqual(true, unique_match(<<"c">>, <<"abc">>)),
    ?assertEqual(false, unique_match(<<"ab">>, <<"abab">>)),
    ok.

text_smaller_than_test() ->
    %% text_smaller_than now works on UTF-32 binaries.
    ?assertEqual(true,  text_smaller_than(to_utf32(<<>>), 5)),
    ?assertEqual(true,  text_smaller_than(to_utf32(<<>>), 1)),
    ?assertEqual(false, text_smaller_than(to_utf32(<<>>), 0)),
    ?assertEqual(false, text_smaller_than(to_utf32(<<"abc">>), 0)),
    ?assertEqual(false, text_smaller_than(to_utf32(<<"abc">>), 1)),
    ?assertEqual(true,  text_smaller_than(to_utf32(<<"abc">>), 4)),

    %% Multi-byte UTF-8 characters each become exactly 4 bytes in UTF-32.
    Utf32 = to_utf32(<<1046/utf8, 1011/utf8, 1022/utf8, 127/utf8>>),
    ?assertEqual(true,  text_smaller_than(Utf32, 5)),
    ?assertEqual(false, text_smaller_than(Utf32, 4)),

    ok.

lines_to_chars_test() ->
    %% lines_to_chars takes UTF-32 input, returns UTF-32 index sequences and UTF-32 lines.
    {C1, C2, Lines} = lines_to_chars(to_utf32(<<>>), to_utf32(<<>>)),
    ?assertEqual(<<>>, C1),
    ?assertEqual(<<>>, C2),
    ?assertEqual([], Lines),

    {C3, C4, Lines2} = lines_to_chars(to_utf32(<<"hello\nworld\n">>), to_utf32(<<"hello\nmaas\n">>)),
    %% Lines are stored as UTF-32 binaries.
    ?assertEqual([to_utf32(<<"hello\n">>), to_utf32(<<"world\n">>), to_utf32(<<"maas\n">>)], Lines2),
    ?assertEqual(<<0:32, 1:32>>, C3),
    ?assertEqual(<<0:32, 2:32>>, C4),

    ok.

diff_linemode_test() ->
    ?assertEqual([{equal, <<"hello\n">>}, {delete, <<"world\n">>}, {insert, <<"maas\n">>}], 
        diff_linemode(<<"hello\nworld\n">>, <<"hello\nmaas\n">>)),

    ok.

diff_options_test() ->
    A = <<"cat">>,
    B = <<"map">>,

    %% No options — same as diff/2.
    ?assertEqual(diff(A, B), diff(A, B, [])),

    %% no_linemode: result is structurally equivalent (same source/dest text).
    NoLinemode = diff(A, B, [no_linemode]),
    ?assertEqual(source_text(diff(A, B)),      source_text(NoLinemode)),
    ?assertEqual(destination_text(diff(A, B)), destination_text(NoLinemode)),

    %% semantic option applies cleanup_semantic to the raw diff.
    ?assertEqual(cleanup_semantic(diff(A, B)), diff(A, B, [semantic])),

    %% efficiency option applies cleanup_efficiency to the raw diff.
    ?assertEqual(cleanup_efficiency(diff(A, B)), diff(A, B, [efficiency])),

    %% {efficiency, Cost} applies cleanup_efficiency/2 with the given cost.
    ?assertEqual(cleanup_efficiency(diff(A, B), 2), diff(A, B, [{efficiency, 2}])),

    %% Both: semantic first, then efficiency.
    ?assertEqual(
        cleanup_efficiency(cleanup_semantic(diff(A, B))),
        diff(A, B, [semantic, efficiency])),

    %% Order of options in list does not affect cleanup order.
    ?assertEqual(
        diff(A, B, [semantic, efficiency]),
        diff(A, B, [efficiency, semantic])),

    ok.

seed_test() ->
    %% 1. Empty binary: no codepoints, seed is empty.
    ?assertEqual({0, <<>>}, seed(<<>>, 0)),

    %% 2. Binary shorter than 4 codepoints (3 codepoints): 3 div 4 = 0, seed is empty.
    Short3 = to_utf32(<<"abc">>),
    ?assertEqual({0, <<>>}, seed(Short3, 0)),

    %% 3. Exactly 4 codepoints, Start=0: seed is 1 codepoint (the first one).
    Exact4 = to_utf32(<<"abcd">>),
    ?assertEqual({0, to_utf32(<<"a">>)}, seed(Exact4, 0)),

    %% 4. 8 codepoints, Start=0: seed is 2 codepoints starting at offset 0.
    Long8 = to_utf32(<<"12345678">>),
    ?assertEqual({0, to_utf32(<<"12">>)}, seed(Long8, 0)),

    %% 5. 16 codepoints, Start=8 (byte offset = 2 codepoints in):
    %%    seed is 4 codepoints; returned Start equals 8 and seed bytes are the correct slice.
    Long16 = to_utf32(<<"abcdefghijklmnop">>),
    {S5, Seed5} = seed(Long16, 8),
    ?assertEqual(8, S5),
    ?assertEqual(to_utf32(<<"cdef">>), Seed5),

    %% 6. ASCII text round-trip: "1234567890" (10 chars), seed at quarter-way offset.
    Ascii10 = to_utf32(<<"1234567890">>),
    %% TotalCodepoints=10, SeedCodepoints=2; Start=0 (quarter-way = 0 for simplicity).
    {_, SeedAscii} = seed(Ascii10, 0),
    ?assertEqual(<<"12">>, to_utf8(SeedAscii)),

    %% 7. Multi-byte codepoint alignment: 10 Greek letters (2 UTF-8 bytes each, 4 UTF-32 bytes each).
    Greek10 = to_utf32(<<"αβγδεζηθικ"/utf8>>),
    {Start7, Seed7} = seed(Greek10, 0),
    %% Returned Start is 0.
    ?assertEqual(0, Start7),
    %% Seed is 4-byte-aligned.
    ?assertEqual(0, byte_size(Seed7) rem 4),
    %% Seed length = (10 div 4) * 4 = 8 bytes = 2 codepoints.
    ?assertEqual((10 div 4) * 4, byte_size(Seed7)),
    %% Seed decodes back to the first 2 Greek letters.
    ?assertEqual(<<"αβ"/utf8>>, to_utf8(Seed7)),

    %% 8. Emoji (4-byte UTF-8 codepoints): 10 emoji, seed is first 2.
    Emoji10 = to_utf32(<<"🐶🐱🐭🐹🐰🐨🐯🦁🐮🐷"/utf8>>),
    {_, SeedEmoji} = seed(Emoji10, 0),
    %% Seed length = (10 div 4) * 4 = 8 bytes = 2 codepoints.
    ?assertEqual((10 div 4) * 4, byte_size(SeedEmoji)),
    %% Seed decodes back to the first 2 emoji.
    ?assertEqual(<<"🐶🐱"/utf8>>, to_utf8(SeedEmoji)),

    %% 9. Seed start offset preserved: non-zero Start is returned unchanged.
    Long12 = to_utf32(<<"abcdefghijkl">>),
    {Start9, _} = seed(Long12, 8),
    ?assertEqual(8, Start9),

    %% 10. Seed is a contiguous slice of Long: binary:part(Long, Start, byte_size(Seed)) =:= Seed.
    Long20 = to_utf32(<<"abcdefghijklmnopqrst">>),
    {Start10, Seed10} = seed(Long20, 8),
    ?assertEqual(Seed10, binary:part(Long20, Start10, byte_size(Seed10))),

    ok.

-endif.
