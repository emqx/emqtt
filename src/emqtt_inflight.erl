%%-------------------------------------------------------------------------
%% Copyright (c) 2022 EMQ Technologies Co., Ltd. All Rights Reserved.
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
%%-------------------------------------------------------------------------

-module(emqtt_inflight).

-include("emqtt.hrl").

-export([ new/1
        , insert/3
        , update/3
        , delete/2
        , size/1
        , is_full/1
        , is_empty/1
        , foreach/2
        , retry/2
        ]).

-type(inflight() :: inflight(req())).

-type(inflight(Req) :: #{max_inflight := pos_integer() | infinity,
                         sent := sent(Req),
                         seq := seq_no()
                        }).

-type(sent(Req) :: #{id() => {seq_no(), Req}}).

-type(id() :: term()).

-type(seq_no() :: pos_integer()).

-type(req() :: term()).

-export_type([inflight/1]).

%%--------------------------------------------------------------------
%% APIs

-spec(new(infinity | pos_integer()) -> inflight()).
new(MaxInflight) ->
    #{max_inflight => MaxInflight, sent => #{}, seq => 1}.

-spec(insert(id(), req(), inflight()) -> error | inflight()).
insert(Id, Req, Inflight = #{max_inflight := Max, sent := Sent, seq := Seq}) ->
    case maps:size(Sent) >= Max of
        true ->
            error;
        false ->
            Inflight#{sent := maps:put(Id, {Seq, Req}, Sent), seq  := Seq + 1}
    end.

-spec(update(id(), req(), inflight()) -> inflight()).
update(Id, Req, Inflight = #{sent := Sent}) ->
    case maps:find(Id, Sent) of
        error -> error;
        {ok, {No, _OldReq}} ->
            Inflight#{sent := maps:put(Id, {No, Req}, Sent)}
    end.

-spec(delete(id(), inflight()) -> inflight()).
delete(Id, Inflight = #{sent := Sent}) ->
    case maps:take(Id, Sent) of
        error -> error;
        {{_, Req}, Sent1} ->
            {Req, Inflight#{sent := Sent1}}
    end.

-spec(size(inflight()) -> non_neg_integer()).
size(#{sent := Sent}) ->
    maps:size(Sent).

-spec(is_full(inflight()) -> boolean()).
is_full(#{max_inflight := infinity}) ->
    false;
is_full(#{max_inflight := Max, sent := Sent}) ->
    maps:size(Sent) >= Max.

-spec(is_empty(inflight()) -> boolean()).
is_empty(#{sent := Sent}) ->
    maps:size(Sent) =< 0.


%% @doc first in first evaluate
-spec(foreach(F, inflight()) -> ok when
    F :: fun((id(), req()) -> ok)).
foreach(F, #{sent := Sent}) ->
    lists:foreach(
      fun({Id, {_SeqNo, Req}}) -> F(Id, Req) end,
      sort_sent(Sent)
     ).

%% @doc Return a sorted list of Pred returned true
-spec(retry(Pred, inflight()) -> list({id(), req()}) when
    Pred :: fun((id(), req()) -> boolean())).
retry(Pred, #{sent := Sent}) ->
    Need = sort_sent(filter_sent(fun(Id, Req) -> Pred(Id, Req) end, Sent)),
    lists:map(fun({Id, {_SeqNo, Req}}) -> {Id, Req} end, Need).

%%--------------------------------------------------------------------
%% Internal funcs

filter_sent(F, Sent) ->
    maps:filter(fun(Id, {_SeqNo, Req}) -> F(Id, Req) end, Sent).

%% @doc sort with seqno
sort_sent(Sent) ->
    Sort = fun({_Id1, {SeqNo1, _Req1}},
               {_Id2, {SeqNo2, _Req2}}) ->
                   SeqNo1 < SeqNo2
           end,
    lists:sort(Sort, maps:to_list(Sent)).
