%%%-------------------------------------------------------------------
%% @doc sasl public API
%% @end
%%%-------------------------------------------------------------------

-module(emqtt_sasl).

-export([ check/1
        , supported/0]).

check(EnhancedAuthState = #{method := <<"SCRAM-SHA-1">>,
                    params := Params,
                    stage := initialized}) ->
    Data = esasl:apply(<<"SCRAM-SHA-1">>, Params),
    AuthContext = maps:merge(Params, #{client_first => Data}),
    {ok, Data, maps:merge(EnhancedAuthState, #{stage => continue,
                                       context => AuthContext})};

check(EnhancedAuthState = #{method := <<"SCRAM-SHA-1">>,
                    stage := continue,
                    latest_server_data := ServerAuthData,
                    context := AuthContext}) ->
    case  esasl:check_server_data(<<"SCRAM-SHA-1">>, ServerAuthData, AuthContext) of
        {continue, Data, NAuthContext} ->
            {ok, Data, maps:merge(EnhancedAuthState, #{stage => continue, context => NAuthContext})};
        {ok, <<>>, _} ->
            {ok, maps:merge(EnhancedAuthState, #{stage => initialized, context => #{}})}
    end;

check(_EnhancedAuthState) ->
    {error, authentication_failed}.

supported() ->
    [<<"SCRAM-SHA-1">>].
