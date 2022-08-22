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
        , retry/3
        ]).

-type(inflight() :: #{emqtt:packet_id() => {seq_no(), inflight_publish()} | {seq_no(), inflight_pubrel()}}).

-type(inflight_publish() ::
      {publish,
       #mqtt_msg{},
       sent_at(),
       expire_at(),
       emqtt:mfas() | undefined
      }).

-type(inflight_pubrel() ::
      {pubrel,
       emqtt:packet_id(),
       sent_at(),
       expire_at()
      }).

-type(seq_no() :: pos_integer()).
-type(sent_at() :: non_neg_integer()). %% in millisecond
-type(expire_at() :: non_neg_integer() | infinity). %% in millisecond

-type(retry_func() :: fun(
                        (emqtt:packet_id(),
                         inflight_publish() | inflight_pubrel()
                        ) -> inflight_publish() | inflight_pubrel())).

-export_type([inflight/0, inflight_publish/0, inflight_pubrel/0,
              sent_at/0, expire_at/0, retry_func/0]).

%%--------------------------------------------------------------------
%% APIs

-spec(new(infinity | pos_integer()) -> inflight()).
new(MaxInflight) ->
    #{max_inflight => MaxInflight, sent => #{}, size => 0, seq => 1}.

insert(_Id, _Req, #{max_inflight := Max, size := Max}) ->
    error;
insert(Id, Req, Inflight = #{sent := Sent, size := Size, seq := Seq}) ->
    Inflight#{sent := maps:put(Id, {Seq, Req}, Sent),
              size := Size + 1,
              seq  := Seq + 1
             }.

update(_Id, _Req, #{max_inflight := Max, size := Max}) ->
    error;
update(Id, Req, Inflight = #{sent := Sent}) ->
    case maps:find(Id, Sent) of
        error -> error;
        {ok, {No, _OldReq}} ->
            Inflight#{sent := maps:put(Id, {No, Req}, Sent)}
    end.

delete(_Id, _Inflight = #{size := 0}) ->
    error;
delete(Id, Inflight = #{sent := Sent, size := Size}) ->
    case maps:take(Id, Sent) of
        error -> error;
        {{_, Req}, Sent1} ->
            {Req, Inflight#{sent := Sent1, size := Size - 1}}
    end.

size(#{size := Size}) ->
    Size.

is_full(#{max_inflight := infinity}) ->
    false;
is_full(#{max_inflight := Max, size := Size}) ->
    Max =:= Size.

is_empty(#{size := Size}) ->
    Size =< 0.

%% @doc first in first evaluate
foreach(_F, #{size := 0}) ->
    ok;
foreach(F, #{sent := Sent}) ->
    lists:foreach(
      fun({Id, {_SeqNo, Req}}) -> F(Id, Req) end,
      arrange_sent(Sent)
     ).

%% @doc eval RetryFunc if held time(ms) over HeldIntv
-spec(retry(pos_integer(), retry_func(), inflight())
      -> list(inflight_publish() | inflight_pubrel())).
retry(_HeldIntv, _RetryFun, Inflight = #{size := 0}) ->
    Inflight;
retry(HeldIntv, RetryFun, Inflight = #{sent := Sent}) ->
    Now = erlang:system_time(millisecond),
    Need = arrange_sent(
             filter_sent(
               fun(_Id, Req) -> (sent_at(Req) + HeldIntv) < Now end,
               Sent
              )),
    NSent = lists:foldl(
              fun({Id, {SeqNo, Req}}, SentAcc) ->
                      NReq = RetryFun(Id, Req),
                      maps:put(Id, {SeqNo, NReq}, SentAcc)
              end, Sent, Need),
    Inflight#{sent := NSent}.

%%--------------------------------------------------------------------
%% Internal funcs

filter_sent(F, Sent) ->
    maps:filter(fun(Id, {_SeqNo, Req}) -> F(Id, Req) end, Sent).

%% XXX: break opaque?
sent_at({publish, _Msg, SentAt, _ExpireAt, _Callback}) ->
    SentAt;
sent_at({pubrel, _PacketId, SentAt, _ExpireAt}) ->
    SentAt.

%% @doc arrange with seqno
arrange_sent(Sent) ->
    Sort = fun({_Id1, {SeqNo1, _Req1}},
               {_Id2, {SeqNo2, _Req2}}) ->
                   SeqNo1 < SeqNo2
           end,
    lists:sort(Sort, maps:to_list(Sent)).
