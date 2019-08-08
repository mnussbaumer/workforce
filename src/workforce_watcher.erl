-module(workforce_watcher).
-behaviour(gen_server).

-include_lib("kernel/include/logger.hrl").

-include("workforce_shared.hrl").

-export([start_link/1, init/1, terminate/2, handle_continue/2, handle_call/3, handle_info/2, handle_cast/2]).

-import(workforce_supervisor, [workforce_config/0]).

-record(state, {
                worker = nil :: {atom(), atom(), [any()]} | nil,
                monitors = #{} :: map()
               }
       ).

-spec start_link(Config :: workforce_config()) -> {ok, pid()} | {error, term()}.
start_link(#{watcher_name := Name} = Config) ->
    gen_server:start_link(Name, ?MODULE, Config, []).

-spec init(Config :: workforce_config()) -> {ok, #state{}}.
init(#{worker := {_,_,_} = Worker})->
    process_flag(trap_exit, true),
    {ok, #state{worker = Worker}}.

-spec terminate(term(), #state{}) -> any().
terminate(_reason, #state{monitors = Monitors})->
    decomission(Monitors).

-spec decomission(map()) -> any().
decomission(Monitors)->
    Fun = fun(Pid, _, _) -> exit(Pid, shutdown) end,
    maps:fold(Fun, nil, Monitors).


handle_continue({start_worker, Requester, Ref}, #state{worker = {M, F, A}, monitors = Monitors} = State)->
    case apply(M, F, A) of
        {ok, Pid} ->
            link(Pid),
            N_monitors = maps:put(Pid, true, Monitors),
            self() ! {started, Requester, Pid, Ref},
            {noreply, State#state{monitors = N_monitors}};
        _Error ->
            Requester ! {failed_start, Ref},
            {noreply, State}
    end.


handle_call(get_workers, _, #state{monitors = Monitors} = State) ->
    {reply, maps:keys(Monitors), State};

handle_call(_, _, State) -> {noreply, State}.


handle_info({start_worker, Pid, Ref}, State) ->
    {noreply, State, {continue, {start_worker, Pid, Ref}}};

handle_info({started, Requester, Worker, _}, #state{monitors = Monitors} = State) when is_map_key(Worker, Monitors) ->
    Requester ! {started, Worker},
    {noreply, State};

handle_info({started, Requester, _, Ref}, State) ->
    Requester ! {failed_start, Ref},
    {noreply, State};

handle_info({'EXIT', Pid, _Reason}, #state{monitors = Monitors} = State) when is_map_key(Pid, Monitors) ->
    {_, N_monitors} = maps:take(Pid, Monitors),
    {noreply, State#state{monitors = N_monitors}};


handle_info(_, State) -> {noreply, State}.


handle_cast({decomissioned, Pid}, State) -> 
    exit(Pid, shutdown),
    {noreply, State}.
