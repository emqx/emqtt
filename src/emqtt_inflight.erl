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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([ new/1
        , empty/1
        , insert/3
        , update/3
        , delete/2
        , size/1
        , maxsize/1
        , capacity/1
        , is_full/1
        , is_empty/1
        , limit/2
        , trim_overflow/1
        , foreach/2
        , map/2
        , to_retry_list/2
        ]).

-type(inflight() :: inflight(req())).

-type(inflight(Req) :: #{max_inflight := maximum() | {maximum(), _Limit :: maximum()},
                         sent := sent(Req),
                         seq := seq_no()
                        }).

-type(maximum() :: infinity | pos_integer()).

-type(sent(Req) :: #{id() => {seq_no(), Req}}).

-type(id() :: term()).

-type(seq_no() :: pos_integer()).

-type(req() :: term()).

-export_type([inflight/1, inflight/0]).

%%--------------------------------------------------------------------
%% APIs

-spec(new(infinity | pos_integer()) -> inflight()).
new(MaxInflight) ->
    #{max_inflight => MaxInflight, sent => #{}, seq => 1}.

-spec(empty(inflight()) -> inflight()).
empty(Inflight) ->
    Inflight#{sent := #{}, seq := 1}.

-spec(insert(id(), req(), inflight()) -> error | {ok, inflight()}).
insert(Id, Req, Inflight = #{max_inflight := MI, sent := Sent, seq := Seq}) ->
    case capacity(MI, Sent) of
        C when C =< 0 ->
            error;
        _ ->
            {ok, Inflight#{sent := maps:put(Id, {Seq, Req}, Sent),
                       seq := Seq + 1}}
    end.

-spec(update(id(), req(), inflight()) -> error | {ok, inflight()}).
update(Id, Req, Inflight = #{sent := Sent}) ->
    case maps:find(Id, Sent) of
        error -> error;
        {ok, {No, _OldReq}} ->
            {ok, Inflight#{sent := maps:put(Id, {No, Req}, Sent)}}
    end.

-spec(delete(id(), inflight()) -> error | {{value, req()}, inflight()}).
delete(Id, Inflight = #{sent := Sent}) ->
    case maps:take(Id, Sent) of
        error -> error;
        {{_, Req}, Sent1} ->
            {{value, Req}, maybe_reset_seq(Inflight#{sent := Sent1})}
    end.

-spec(size(inflight()) -> non_neg_integer()).
size(#{sent := Sent}) ->
    maps:size(Sent).

-spec(maxsize(inflight()) -> pos_integer() | infinity).
maxsize(#{max_inflight := MI}) ->
    effective_max_inflight(MI).

-spec(is_full(inflight()) -> boolean()).
is_full(Inflight) ->
    Capacity = capacity(Inflight),
    Capacity =/= infinity andalso Capacity =< 0.

-spec(limit(_Limit :: pos_integer() | infinity, inflight()) -> inflight()).
limit(Limit, Inflight = #{max_inflight := {MI, _LimitWas}}) ->
    Inflight#{max_inflight := {MI, Limit}};
limit(Limit, Inflight = #{max_inflight := MI}) ->
    Inflight#{max_inflight := {MI, Limit}}.

-spec(capacity(inflight()) -> integer()).
capacity(#{max_inflight := MI, sent := Sent}) ->
    capacity(MI, Sent).

capacity(infinity, _Sent) ->
    infinity;
capacity(MI, Sent) when is_tuple(MI) ->
    capacity(effective_max_inflight(MI), Sent);
capacity(Max, Sent) ->
    Max - maps:size(Sent).

effective_max_inflight({MI, Limit}) ->
    min(MI, Limit);
effective_max_inflight(MI) ->
    MI.

-spec(trim_overflow(inflight()) -> {_Overflow :: [{id(), req()}], inflight()}).
trim_overflow(Inflight = #{max_inflight := MI, sent := Sent}) ->
    case capacity(MI, Sent) of
        Negative when Negative < 0 ->
            {Overflow, Sent1} = trim_overflow(Sent, -Negative),
            {Overflow, Inflight#{sent := Sent1}};
        _ ->
            {[], Inflight}
    end.

trim_overflow(Sent, Overflow) ->
    Reqs = take_requests(maps:iterator(Sent), Overflow),
    Sent1 = lists:foldl(fun delete_request/2, Sent, Reqs),
    {Reqs, Sent1}.

delete_request({Id, _Req}, Sent) ->
    maps:remove(Id, Sent).

take_requests(_It, 0) ->
    [];
take_requests(It, N) ->
    case maps:next(It) of
        {Id, {_SeqNo, Req}, It1} ->
            [{Id, Req} | take_requests(It1, N - 1)];
        none ->
            []
    end.

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

-spec(map(F, inflight()) -> inflight() when
    F :: fun((id(), req()) -> {id(), req()})).
map(F, Inflight = #{sent := Sent}) ->
    Sent1 = maps:fold(
              fun(Id, {SeqNo, Req}, Acc) ->
                      {Id1, Req1} = F(Id, Req),
                      Acc#{Id1 => {SeqNo, Req1}}
              end, #{}, Sent),
    Inflight#{sent := Sent1}.

%% @doc Return a sorted list of Pred returned true
-spec(to_retry_list(Pred, inflight()) -> list({id(), req()}) when
    Pred :: fun((id(), req()) -> boolean())).
to_retry_list(Pred, #{sent := Sent}) ->
    Need = sort_sent(filter_sent(fun(Id, Req) -> Pred(Id, Req) end, Sent)),
    lists:map(fun({Id, {_SeqNo, Req}}) -> {Id, Req} end, Need).

%%--------------------------------------------------------------------
%% Internal funcs

filter_sent(F, Sent) ->
    maps:filter(fun(Id, {_SeqNo, Req}) -> F(Id, Req) end, Sent).

%% @doc sort with seq
sort_sent(Sent) ->
    Sort = fun({_Id1, {SeqNo1, _Req1}},
               {_Id2, {SeqNo2, _Req2}}) ->
                   SeqNo1 < SeqNo2
           end,
    lists:sort(Sort, maps:to_list(Sent)).

%% @doc avoid integer overflows
maybe_reset_seq(Inflight) ->
    case is_empty(Inflight) of
        true ->
            Inflight#{seq := 1};
        false ->
            Inflight
    end.

%%--------------------------------------------------------------------
%% tests

-ifdef(TEST).

insert_delete_test() ->
    Inflight = emqtt_inflight:new(2),
    {ok, Inflight1} = emqtt_inflight:insert(1, req1, Inflight),
    {ok, Inflight2} = emqtt_inflight:insert(2, req2, Inflight1),
    error = emqtt_inflight:insert(3, req3, Inflight2),
    error = emqtt_inflight:delete(3, Inflight),
    {{value, req2}, _} = emqtt_inflight:delete(2, Inflight2).

update_test() ->
    Inflight = emqtt_inflight:new(2),
    {ok, Inflight1} = emqtt_inflight:insert(1, req1, Inflight),
    error = emqtt_inflight:update(2, req2, Inflight1),

    {ok, Inflight11} = emqtt_inflight:update(1, req11, Inflight1),
    {{value, req11}, _} = emqtt_inflight:delete(1, Inflight11).

size_full_empty_test() ->
    Inflight = emqtt_inflight:new(1),
    0 = emqtt_inflight:size(Inflight),
    true = emqtt_inflight:is_empty(Inflight),
    false = emqtt_inflight:is_full(Inflight),

    {ok, Inflight1} = emqtt_inflight:insert(1, req1, Inflight),
    1 = emqtt_inflight:size(Inflight1),
    false = emqtt_inflight:is_empty(Inflight1),
    true = emqtt_inflight:is_full(Inflight1),

    false = emqtt_inflight:is_full(emqtt_inflight:new(infinity)),
    true = emqtt_inflight:is_empty(emqtt_inflight:new(infinity)).

limit_full_empty_test() ->
    Inflight = emqtt_inflight:new(10),
    0 = emqtt_inflight:size(Inflight),
    10 = emqtt_inflight:maxsize(Inflight),
    true = emqtt_inflight:is_empty(Inflight),
    false = emqtt_inflight:is_full(Inflight),

    {ok, Inflight1} = emqtt_inflight:insert(1, req1, Inflight),
    1 = emqtt_inflight:size(Inflight1),
    false = emqtt_inflight:is_empty(Inflight1),
    false = emqtt_inflight:is_full(Inflight1),
    
    Inflight2 = emqtt_inflight:limit(1, Inflight1),
    1 = emqtt_inflight:maxsize(Inflight2),
    false = emqtt_inflight:is_empty(Inflight2),
    true = emqtt_inflight:is_full(Inflight2),
    error = emqtt_inflight:insert(2, req2, Inflight2),
    
    Inflight3 = emqtt_inflight:limit(infinity, Inflight2),
    false = emqtt_inflight:is_full(Inflight3),
    {ok, Inflight4} = emqtt_inflight:insert(2, req2, Inflight3),
    8 = emqtt_inflight:capacity(Inflight4).

limit_trim_test() ->
    Inflight = emqtt_inflight:new(infinity),
    false = emqtt_inflight:is_full(Inflight),

    {ok, Inflight1} = emqtt_inflight:insert(1, req1, Inflight),
    {ok, Inflight2} = emqtt_inflight:insert(2, req2, Inflight1),
    {ok, Inflight3} = emqtt_inflight:insert(3, req3, Inflight2),
    {ok, Inflight4} = emqtt_inflight:insert(4, req4, Inflight3),
    Inflight5 = emqtt_inflight:limit(2, Inflight4),
    true = emqtt_inflight:is_full(Inflight5),
    -2 = emqtt_inflight:capacity(Inflight5),
    {Overflow, Inflight6} = emqtt_inflight:trim_overflow(Inflight5),
    [_, _] = Overflow,
    true = emqtt_inflight:is_full(Inflight6),
    0 = emqtt_inflight:capacity(Inflight6).

foreach_test() ->
    emqtt_inflight:foreach(
      fun(Id, Req) ->
        true = (Id =:= Req)
      end, inflight_example()).

map_test() ->
    Inflight1 = emqtt_inflight:map(
                  fun(Id, Req) -> {Id + 1, Req + 1} end,
                  inflight_example()
                 ),
    [{2, 2}, {3, 3}] = emqtt_inflight:to_retry_list(fun(_, _) -> true end, Inflight1).

retry_test() ->
    [{"sorted by insert sequence",
      [{1, 1}, {2, 2}] = emqtt_inflight:to_retry_list(
                           fun(Id, Req) -> Id =:= Req end,
                           inflight_example()
                          )
     },
     {"filter",
      [{2, 2}] = emqtt_inflight:to_retry_list(
                   fun(Id, _Req) -> Id =:= 2 end,
                   inflight_example())
     }].

reset_seq_test() ->
    Inflight = emqtt_inflight:new(infinity),
    #{seq := 1} = Inflight,

    {ok, Inflight1} = emqtt_inflight:insert(1, req1, Inflight),
    #{seq := 2} = Inflight1,

    {_, Inflight2} = emqtt_inflight:delete(1, Inflight1),

    %% reset seq to 1 once inflight is empty
    true = emqtt_inflight:is_empty(Inflight2),
    #{seq := 1} = Inflight2.

inflight_example() ->
    {ok, Inflight} = emqtt_inflight:insert(1, 1, emqtt_inflight:new(infinity)),
    {ok, Inflight1} = emqtt_inflight:insert(2, 2, Inflight),
    Inflight1.

-endif.
