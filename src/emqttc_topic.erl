%%%-----------------------------------------------------------------------------
%%% Copyright (c) 2012-2016 eMQTT.IO, All Rights Reserved.
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in all
%%% copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%%% SOFTWARE.
%%%-----------------------------------------------------------------------------
%%% @doc
%%% emqttc topic handler.
%%%
%%% @end
%%%-----------------------------------------------------------------------------

-module(emqttc_topic).

-author("Feng Lee <feng@emqtt.io>").

-import(lists, [reverse/1]).

%% API
-export([type/1, match/2, validate/1, triples/1, words/1]).

-define(MAX_TOPIC_LEN, 65535).

%%------------------------------------------------------------------------------
%% @doc Topic Type: direct or wildcard
%% @end
%%%-----------------------------------------------------------------------------
-spec type(binary()) -> direct | wildcard.
type(Topic) when is_binary(Topic) ->
    type2(words(Topic)).

type2([]) ->
    direct;
type2(['#'|_]) ->
    wildcard;
type2(['+'|_]) ->
    wildcard;
type2([_H |T]) ->
    type2(T).

%%------------------------------------------------------------------------------
%% @doc Match Topic name with filter.
%% @end
%%------------------------------------------------------------------------------
-spec match(binary(), binary()) -> boolean().
match(Name, Filter) when is_binary(Name) and is_binary(Filter) ->
    match(words(Name), words(Filter));
match([], []) ->
    true;
match([H|T1], [H|T2]) ->
    match(T1, T2);
match([<<$$, _/binary>>|_], ['+'|_]) ->
    false;
match([_H|T1], ['+'|T2]) ->
    match(T1, T2);
match([<<$$, _/binary>>|_], ['#']) ->
    false;
match(_, ['#']) ->
    true;
match([_H1|_], [_H2|_]) ->
    false;
match([_H1|_], []) ->
    false;
match([], [_H|_T2]) ->
    false.

%%------------------------------------------------------------------------------
%% @doc Validate Topic name and filter.
%% @end
%%------------------------------------------------------------------------------
-spec validate({name | filter, binary()}) -> boolean().
validate({_, <<>>}) ->
    false;
validate({_, Topic}) when is_binary(Topic) and (size(Topic) > ?MAX_TOPIC_LEN) ->
    false;
validate({filter, Topic}) when is_binary(Topic) ->
    validate2(words(Topic));
validate({name, Topic}) when is_binary(Topic) ->
    Words = words(Topic),
    validate2(Words) and (not include_wildcard(Words)).

validate2([]) ->
    true;
validate2(['#']) -> % end with '#'
    true;
validate2(['#'|Words]) when length(Words) > 0 ->
    false;
validate2([''|Words]) ->
    validate2(Words);
validate2(['+'|Words]) ->
    validate2(Words);
validate2([W|Words]) ->
    case validate3(W) of
        true -> validate2(Words);
        false -> false
    end.

validate3(<<>>) ->
    true;
validate3(<<C/utf8, _Rest/binary>>) when C == $#; C == $+; C == 0 ->
    false;
validate3(<<_/utf8, Rest/binary>>) ->
    validate3(Rest).

include_wildcard([])        -> false;
include_wildcard(['#'|_T])  -> true;
include_wildcard(['+'|_T])  -> true;
include_wildcard([ _ | T])  -> include_wildcard(T).

%%------------------------------------------------------------------------------
%% @doc Topic to Triples.
%% @end
%%------------------------------------------------------------------------------
triples(Topic) when is_binary(Topic) ->
    triples(words(Topic), root, []).

triples([], _Parent, Acc) ->
    reverse(Acc);

triples([W|Words], Parent, Acc) ->
    Node = join(Parent, W),
    triples(Words, Node, [{Parent, W, Node}|Acc]).

join(root, W) ->
    W;
join(Parent, W) ->
    <<(bin(Parent))/binary, $/, (bin(W))/binary>>.

bin('')  -> <<>>;
bin('+') -> <<"+">>;
bin('#') -> <<"#">>;
bin(Bin) when is_binary(Bin) -> Bin.

%%------------------------------------------------------------------------------
%% @doc Split Topic into Words.
%% @end
%%------------------------------------------------------------------------------
words(Topic) when is_binary(Topic) ->
    [word(W) || W <- binary:split(Topic, <<"/">>, [global])].

word(<<>>)    -> '';
word(<<"+">>) -> '+';
word(<<"#">>) -> '#';
word(Bin)     -> Bin.

