-module(faulty_worker).
-behaviour(gen_server).

-export([start_link/1, init/1, terminate/2, handle_call/3, handle_cast/2, handle_continue/2]).

start_link(Ets) ->
    gen_server:start_link(?MODULE, Ets, []).

init(Ets)->
    case ets:lookup(Ets, start) of
        [{_, yes, N}] -> 
            ets:insert(Ets, {start, no, invert_n(N)}),
            {ok, nil, {continue, {maybe_crash, N}}};
        [{_, no, N}] -> 
            ets:insert(Ets, {start, yes, N}),
            {error, bad_run}
    end.

terminate(_Reason, _)->
    ok.

handle_continue({maybe_crash, yes}, _) -> {stop, error, nil};
handle_continue({maybe_crash, _}, _) -> {noreply, nil}.


handle_call(test, _, State)->
    {reply, ok, State}.

handle_cast(_, State)->
    {noreply, State}.

invert_n(yes) -> no;
invert_n(no) -> yes. 
