-module(workforce).
-behaviour(gen_statem).

%% types & constants

-include("workforce_shared.hrl").

-define(Rec2Map(Name, Record), 
        lists:foldl(fun({Index, Element}, Acc) -> Acc#{Element => element(Index, Record)} end,
        #{},
        lists:zip(lists:seq(2, (record_info(size, Name))), (record_info(fields, Name))))).

%% gen_statem internal data record

-record(q_pool, {
                 queue = queue:new() :: queue:queue(),
                 pool = queue:new() :: queue:queue(),

                 q_count = 0 :: non_neg_integer(),
                 p_count = 0 :: non_neg_integer(),

                 q_track = #{} :: map(),

                 active = 0 :: non_neg_integer(),
                 starting = 0 :: non_neg_integer(),

                 max_w = 10 :: pos_integer(),
                 default_w = 10 :: pos_integer(),
                 max_q = 10 :: integer(),

                 monitors = #{} :: map(),
                 checked_out = #{} :: map(),
                 in_transit = #{} :: map(),
                 requests_monitors = #{} :: map(),
                 
                 watcher = nil :: pid() | nil,
                 ets = nil :: reference() | undefined,
                 
                 overloaded = 0 :: 0 | 1,
                 hibernate_when_free = false :: boolean(),

                 shrink_timeout = {5000, 10000} :: {non_neg_integer(), non_neg_integer()} | non_neg_integer()
                }).

%% exports
%% API

-export([

         checkout/1,
         checkout/2,
         checkout/3,
         
         remote_checkout/1,
         remote_checkout/2,
         remote_checkout/3,
         
         async_checkout/1,
         async_checkout/2,
         async_checkout/3,
         async_cancel/2,
         async_confirm/2,
         
         checkin/2,
         
         state_as_map/1
]).

%% INTERNAL

-export([start_link/1]).
-export([init/1, callback_mode/0, handle_event/4]).

%TYPES

-export_type([
              name/0,
              workforce_config/0,
              checkout_error/0,
              checkout_resp/0,
              remote_resp/0
]).

state_as_map(Pid) ->
    {State, Q_pool} = sys:get_state(Pid),
    maps:put(state, State, ?Rec2Map(q_pool, Q_pool)).

%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% API
                         
-spec checkout(Pid_or_name :: name())-> Resp :: checkout_resp().
-spec checkout(Pid_or_name :: name(), Timeout :: timeout())-> Resp :: checkout_resp().
-spec checkout(Pid_or_name :: name(), Timeout :: timeout(), ForceEnqueue :: boolean())-> Resp :: checkout_resp().

checkout(Pid) -> checkout(Pid, 5000, false).

checkout(Pid, Timeout) -> checkout(Pid, Timeout, false).

checkout(Pid, Timeout, false) when is_pid(Pid), node(Pid) =:= node() -> 
    case ets:lookup(?ETS_NAME, Pid) of
        [{_, 0}] -> do_checkout(Pid, Timeout, false); 
        _ -> {error, overloaded}
    end;

checkout(Pid, Timeout, ForceEnqueue) when is_pid(Pid) ->
    do_checkout(Pid, Timeout, ForceEnqueue);

checkout(Name, Timeout, ForceEnqueue) -> 
    case get_pid(Name) of
        undefined -> {error, {no_such_pool, Name}};
        Pid -> checkout(Pid, Timeout, ForceEnqueue)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% remote checkout
%%%%%% because a network might go down when a regular checkout is made, it could mean the receive was never acknowledged by the pooler, and the `after` cancelation message that wraps that checkout wouldn't arrive either - which doesn't happen locally since it's guaranteed to always run, meaning the checked out pid would be kept as checked out, and there wouldn't be any monitoring over the remote requester either, so when issuing checkouts non-locally its advisable to use this form of checkout. This request also bypasses the pre-check for overload, since that relies on an ETS on the VM running the pooler and doesn't allow enqueuing. It will pick between local and remote checkouts depending on if it's in the same node as the workforce server, so can be used in all places if the requests may or may not come from the same node. To force it to always choose the remote pathway, use the 3 arity form specifying force as the third parameter, e.g. remote_checkout(Pid_or_Name, Timeout, force). 

-spec remote_checkout(Pid_or_name :: name())-> Resp :: remote_resp().
-spec remote_checkout(Pid_or_name :: name(), Timeout :: timeout())-> Resp :: remote_resp().
-spec remote_checkout(Pid_or_name :: name(), Timeout :: timeout(), force)-> Resp :: remote_resp(). 
remote_checkout(Name) -> remote_checkout(Name, 5000).

remote_checkout(Pid, Timeout)  when is_pid(Pid), node(Pid) =:= node() ->
    checkout(Pid, Timeout, false);

remote_checkout(Pid, Timeout) when is_pid(Pid) ->
    remote_checkout(Pid, Timeout, force);

remote_checkout(Name, Timeout) ->
    case get_pid(Name) of
        undefined -> {error, {no_such_pool, Name}};
        Pid -> remote_checkout(Pid, Timeout)
    end.

remote_checkout(Pid, Timeout, force) when is_pid(Pid) ->
    gen_statem:call(Pid, checkout, {dirty_timeout, Timeout});

remote_checkout(Name, Timeout, force)  ->
    case get_pid(Name) of
        undefined -> {error, {no_such_pool, Name}};
        Pid -> remote_checkout(Pid, Timeout, force)
    end.


%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% Async Checkout
%%%%%% This is to be used from inside processes or OTP behaviours if you want to control the checkout process itself asynchronously and have it delivered to the process mailbox. It places a monitor on the workforce process and returns that monitor reference, so that you can match on the incoming messages. The possible messages you can receive are:
%%%%%% {Mref, overloaded}
%%%%%% {Mref, Pid} (when is_pid(Pid))
%%%%%% {Mref, enqueued} 
%%%%%% {'DOWN', Mref, _, Pid, Reason} (if the pool goes down before processing your request)
%%%%%% On an enqueued message you will then further receive either a successful {Mref, Pid} (when is_pid(Pid)) or {'DOWN', Mref, _, Pid, Reason} if the pool goes down while in transit.
%%%%%% You will only receive an enqueued message either if you force adding the request to the queue or if you configured the pool to have a waiting queue > 0 (or unbound) and there was space in the queue, otherwise you will only receive one of overloaded, a pid or a down message.
%%%%%% You need to aknowledge the receptance of the checkout after receiving the worker pid.
%%%%%% Due to it being asynchronous you might still receive a checkout after you cancel the request, in this case you should checkin the pid back yourself or with will be out of the pool until the caller dies.

-spec async_checkout(Pid_or_name :: name())-> async_checkout_resp().
-spec async_checkout(Pid_or_name :: name(), ForceEnqueue :: boolean())-> async_checkout_resp().
-spec async_checkout(Pid_or_name :: name(), ForceEnqueue :: boolean(), force) -> async_checkout_resp().
async_checkout(Pid) ->
    async_checkout(Pid, false).

async_checkout(Pid, false) when is_pid(Pid), node(Pid) =:= node() ->
    case ets:lookup(?ETS_NAME, Pid) of
        [{_, 0}] -> async_checkout(Pid, false, force);
        _ ->
            Mref = make_ref(),
            self() ! {Mref, overloaded},
            Mref
    end;

async_checkout(Pid, ForceEnqueue) when is_pid(Pid) -> async_checkout(Pid, ForceEnqueue, force);
    
async_checkout(Name, ForceEnqueue) ->
    case get_pid(Name) of
        undefined -> {error, {no_such_pool, Name}};
        Pid -> async_checkout(Pid, ForceEnqueue)
    end.

async_checkout(Pid, ForceEnqueue, force) when is_pid(Pid) ->
    Mref = monitor(process, Pid),
    Pid ! {checkout, {self(), Mref}, ForceEnqueue},
    Mref;

async_checkout(Name, ForceEnqueue, force)->
    case get_pid(Name) of
        undefined -> {error, {no_such_pool, Name}};
        Pid -> async_checkout(Pid, ForceEnqueue, force)
    end.

%%%%%% async confirm

-spec async_confirm(Pid_or_name :: name(), Mref :: reference())-> ok | {error, no_such_pool()}.
async_confirm(Pid, Mref) when is_pid(Pid) ->
    Pid ! {received, {self(), Mref}};

async_confirm(Name, Mref) ->
    case get_pid(Name) of
        undefined -> {error, {no_such_pool, Name}};
        Pid -> async_confirm(Pid, Mref)
    end.

%%%%%% async cancel

-spec async_cancel(Pid_or_name :: name(), Mref :: reference())-> ok | {error, no_such_pool()}.
async_cancel(Pid, Mref) when is_pid(Pid) ->
    Pid ! {cancel, {self(), Mref}},
    demonitor(Mref, [flush]);

async_cancel(Name, Mref) ->
    case get_pid(Name) of
        undefined -> {error, {no_such_pool, Name}};
        Pid -> async_cancel(Pid, Mref)
    end.

%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% Check-in

-spec checkin(Pid_or_name :: name(), Worker :: pid())-> Resp :: ok | {Error :: no_such_pool, What :: term()}.
checkin(Pid, Worker) when is_pid(Pid) ->
    gen_statem:cast(Pid, {checkin, Worker});

checkin(Name, Worker) ->
    case get_pid(Name) of
        undefined -> {error, {no_such_pool, Name}};
        Pid -> gen_statem:cast(Pid, {checkin, Worker})
    end.
    

%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% PRIVATE

-spec start_link(Config :: workforce_config())->  {ok, pid()} | {error, term()}.
start_link(#{pool_name := Name} = Config)->
    gen_statem:start_link(Name, ?MODULE, Config, []).

-spec get_pid(Name :: name() | pid())-> Pid :: pid() | undefined.
get_pid(Pid) when is_pid(Pid) -> Pid;
get_pid(Name) when is_atom(Name) -> whereis(Name);
get_pid({local, Name}) -> whereis(Name);
get_pid({global, Name}) ->  global:whereis_name(Name);
get_pid({via, Mod, Name}) -> Mod:whereis_name(Name).

-spec do_checkout(Pid :: pid(), Timeout :: timeout(), ForceEnqueue :: boolean()) -> checkout_resp().
-spec do_checkout(Pid :: pid(), ForceEnqueue :: boolean(), Monitor_ref :: reference(), Timer_ref :: reference() | false) -> checkout_resp().
do_checkout(Pid, Timeout, ForceEnqueue) ->
    Mref = monitor(process, Pid),
    Tref = case is_integer(Timeout) of
               true -> erlang:send_after(Timeout, self(), {Mref, timeout});
               _ -> false
           end,
    
    do_checkout(Pid, ForceEnqueue, Mref, Tref).

do_checkout(Pid, ForceEnqueue, Mref, Tref) ->
    Pid ! {checkout, {self(), Mref}, ForceEnqueue},
    try
        receive
            {Mref, overloaded} -> {error, overloaded};
            {Mref, enqueued} -> await_final(Pid, Mref);
            {Mref, timeout} -> {error, timeout};
            {Mref, Worker_pid} ->
                Pid ! {received, {self(), Mref}},
                {ok, Worker_pid};
            {'DOWN', Mref, _, Pid, Reason} -> {error, {pool_down, Reason}}
        end
    after
        Pid ! {cancel, {self(), Mref}},
        demonitor(Mref, [flush]),
        case Tref of
            false -> noop;
            _ -> erlang:cancel_timer(Tref, [{async, true}, {info, false}])
        end
    end.
               
-spec await_final(Pid :: pid(), Monitor_ref :: reference())-> Resp :: checkout_resp(). 
await_final(Pid, Mref) ->
    receive
        {Mref, timeout} -> {error, timeout};
        {Mref, Worker_pid} ->
            Pid ! {received, {self(), Mref}},
            {ok, Worker_pid};
        {'DOWN', Mref, _, Pid, Reason} -> {error, {pool_down, Reason}}
    end.
             

%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% INTERNAL

callback_mode() -> handle_event_function.

-spec init(Config :: workforce_config())-> {ok, atom(), #q_pool{}, [{next_event, internal, start_worker}]}.
init(#{
       watcher_name := Watcher,
       default_workers := Default_w,
       max_workers := Max_w,
       max_queue := Max_q,
       pool_name := Pool,
       hibernate_when_free := Hibernate,
       shrink_timeout := St
      }) ->
    
    Watcher_pid = get_pid(Watcher),
    
    Ets_ref = ets:whereis(?ETS_NAME),
    case ets:lookup(Ets_ref, Pool) of
        [] -> ok;
        [{_, Old_pid}] -> ets:delete(Ets_ref, Old_pid)
    end,

    ets:insert(Ets_ref, {self(), 0}),
    ets:insert(Ets_ref, {Pool, self()}),                                       
    
    CTX = #q_pool{
             max_w = Max_w,
             default_w = Default_w,
             max_q = Max_q,
             watcher = Watcher_pid,
             ets = Ets_ref,
             hibernate_when_free = Hibernate,
             shrink_timeout = St
            },
    
    {ok, starting, CTX, [{next_event, internal, start_worker}]}.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% request worker events

handle_event(internal, start_worker, _, #q_pool{active = A, default_w = Def, starting = S} = CTX) when (A + S) < Def ->
    {keep_state, request_worker(CTX), [{next_event, internal, start_worker}]};

handle_event(internal, start_worker, starting, CTX) -> {next_state, ready, CTX};

handle_event(internal, start_worker, _, #q_pool{q_count = Qc, active = A, max_w = Max, starting = S, shrink_timeout = St} = CTX) when Qc > 0, (A + S) < Max -> 
    Ref = make_ref(),
    {keep_state, request_worker(CTX, Ref), [{{timeout, {shrink, Ref}}, get_shrink(0, St), nil}]};

handle_event(internal, start_worker, _, _) -> 
    {keep_state_and_data, [{next_event, internal, dequeue}]};


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% add to queue events

handle_event(internal, {add_to_queue, From, _}, ready, #q_pool{active = A, starting = S, max_w = Max} = CTX) when (A + S) < Max -> 
    {keep_state, add_to_queue(CTX, From), [{next_event, internal, start_worker}]};

handle_event(internal, {add_to_queue, From, ForceEnqueue}, ready, #q_pool{q_count = Qc, max_q = Max} = CTX) when Qc < Max; Max < 0; ForceEnqueue =:= true ->
    {keep_state, add_to_queue(CTX, From), [{reply, From, enqueued}]};

handle_event(internal, {add_to_queue, From, _}, _, #q_pool{ets = Ets} = CTX) ->
    ets:insert(Ets, {self(), 1}),
    {keep_state, CTX#q_pool{overloaded = 1}, [{reply, From, overloaded}, {{timeout, overloaded}, 25, nil}]};


%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% dequeue events

handle_event(internal, dequeue, _, #q_pool{pool = P, p_count = Pc, queue = Q, q_count = Qc, checked_out = Cout, in_transit = It, q_track = Qt} = CTX) when Qc > 0, Pc > 0 ->
    
    {{value, From}, N_queue} = queue:out(Q),
    case maps:take(From, Qt) of
        % 1 means the client has canceled their request, so we just repeat this event, to get the next in queue
        {1, N_queue_track} -> 
            {keep_state, CTX#q_pool{queue = N_queue, q_track = N_queue_track}, [{next_event, internal, dequeue}]};
        {0, N_queue_track} ->
            {{value, Pid}, N_pool} = queue:out(P),
            
            N_cout = maps:put(Pid, From, Cout),
            N_it = maps:put(From, Pid, It),
            {
             keep_state,
             CTX#q_pool{
               pool = N_pool,
               p_count = Pc - 1,
               queue = N_queue,
               q_count = Qc - 1,
               q_track = N_queue_track,
               checked_out = N_cout,
               in_transit = N_it
              },
             [{reply, From, Pid}]
            }
    end;

handle_event(internal, dequeue, _, #q_pool{hibernate_when_free = true, q_count = 0, p_count = Pc, active = Pc}) ->
    {keep_state_and_data, [{hibernate, true}]};

handle_event(internal, dequeue, _, _) -> {keep_state_and_data, []};


%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% checkout events

handle_event(info, {checkout, From, false = _ForceEnqueue}, _, #q_pool{overloaded = 1}) -> 
    {keep_state_and_data, [{reply, From, overloaded}]};

handle_event(info, {checkout, From, _}, ready, #q_pool{pool = P, p_count = Pc, checked_out = Cout, in_transit = It} = CTX) when Pc > 0 ->

    {{value, Pid}, N_pool} = queue:out(P),

    N_cout = maps:put(Pid, From, Cout),
    N_it = maps:put(From, Pid, It),
    
    {
     keep_state,
     CTX#q_pool{
       pool = N_pool,
       p_count = Pc - 1,
       checked_out = N_cout,
       in_transit = N_it
      },
     [{reply, From, Pid}]
    };

handle_event(info, {checkout, From, ForceEnqueue}, ready, _) ->
    {keep_state_and_data, [{next_event, internal, {add_to_queue, From, ForceEnqueue}}]};

%%%%%% remote checkout

handle_event({call, From}, checkout, _, #q_pool{overloaded = 1}) ->
    {keep_state_and_data, [{reply, From, {error, overloaded}}]};

handle_event({call, {Req_pid, _} = From}, checkout, ready,  #q_pool{pool = P, p_count = Pc, checked_out = Cout, requests_monitors = Req_ms, ets = Ets} = CTX) when Pc > 0 ->

    Mref = monitor(process, Req_pid),
    {{value, Pid}, N_pool} = queue:out(P),

    N_cout = maps:put(Pid, From, Cout),
    Req_tuple = {Pid, From, Mref},
    N_req_ms = maps:update_with(
                 Req_pid,
                 fun(Existing) -> [Req_tuple | Existing] end,
                 [Req_tuple],
                 Req_ms
                ),
    N_pc = Pc - 1,

    Maybe_is_overloaded = case N_pc == 0 of
                              true -> 1;
                              false -> 0
                          end,
    Add_actions = case Maybe_is_overloaded of
                      1 -> 
                          ets:insert(Ets, {self(), 1}),
                          [{{timeout, overloaded}, 25, nil}];
                      0 -> []
                  end,
    
    {
     keep_state,
     CTX#q_pool{
       pool = N_pool,
       p_count = N_pc,
       checked_out = N_cout,
       requests_monitors = N_req_ms,
       overloaded = Maybe_is_overloaded
      },
     [{reply, From, {ok, Pid}} | Add_actions]
    };


%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% checkin events

handle_event(cast, {checkin, Pid}, _, #q_pool{checked_out = Cout} = CTX) when is_map_key(Pid, Cout) ->
    {next_state, ready, return_worker(CTX, Pid), [{next_event, internal, dequeue}]};

handle_event(cast, {checkin, _}, _, _) -> {keep_state_and_data, []};


%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% requester acks & cancel events

handle_event(info, {cancel, From}, _, #q_pool{pool = P, p_count = Pc, in_transit = It, checked_out = Cout} = CTX) when is_map_key(From, It) ->
    {Pid, N_it} = maps:take(From, It),
    {_, N_cout} = maps:take(Pid, Cout),
    N_pool = queue:in(Pid, P),

    N_CTX = CTX#q_pool{pool = N_pool, p_count = Pc + 1, in_transit = N_it, checked_out = N_cout},
    
    {keep_state, N_CTX, [{next_event, internal, dequeue}]};

handle_event(info, {cancel, From}, _, #q_pool{q_count = Qc, q_track = Qt} = CTX) when is_map_key(From, Qt) ->
    %% we do not take the user out of the actual queue in this step, because that would be very expensive with a big queue and results in it almost not being usable besides very specific situations, instead we change its mark to 1 in the queue track - this way when dequeuing, we can see they've been canceled and just repeat the dequeuing until we get a client that's actually waiting, which is very fast compared to traversing and filtering the queue everytime a cancelation is requested.
    N_queue_track = maps:put(From, 1, Qt),
    {keep_state, CTX#q_pool{q_count = Qc - 1, q_track = N_queue_track}, []};

handle_event(info, {cancel, _From}, _, _) -> {keep_state_and_data, []};

handle_event(info, {received, {Req_pid, _} = From}, _, #q_pool{in_transit = It, requests_monitors = Req_ms} = CTX) ->

    {Pid, N_it} = maps:take(From, It),
    Mref = monitor(process, Req_pid),
    Req_tuple = {Pid, From, Mref},
    N_req_ms = maps:update_with(
                 Req_pid,
                 fun(Existing) -> [Req_tuple | Existing] end,
                 [Req_tuple],
                 Req_ms
                ),

    {keep_state, CTX#q_pool{in_transit = N_it, requests_monitors = N_req_ms}, []};


%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% worker up/failed events

handle_event(info, {started, Worker}, ready, CTX) ->
    {keep_state, activate_worker(CTX, Worker), [{next_event, internal, dequeue}]};

handle_event(info, {failed_start, Ref}, _, #q_pool{starting = Starting} = CTX) ->
    {keep_state, CTX#q_pool{starting = Starting - 1}, [{{timeout, {shrink, Ref}}, infinity, nil}]};


%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% timer events

%%%%%% shrink the worker pool

handle_event({timeout, {shrink, _} = Sterm}, _, _, #q_pool{active = A, default_w = Def, monitors = Ms, p_count = Pc, pool = P, watcher = Watcher} = CTX) when A > Def, Pc > (Def / 5) ->
    
    {{value, Pid}, N_pool} = queue:out(P),
    {Ref, N_ms} = maps:take(Pid, Ms),
    
    demonitor(Ref, [flush]),
    gen_server:cast(Watcher, {decomissioned, Pid}),
    
    N_CTX = CTX#q_pool{active = A - 1, monitors = N_ms, pool = N_pool, p_count = Pc - 1},
    
    {keep_state, N_CTX, [{{timeout, Sterm}, infinity, nil}]};

handle_event({timeout, {shrink, _} = Sterm}, _, _, #q_pool{active = A, default_w = Def, starting = S}) when A + S =:= Def ->
    {keep_state_and_data, [{{timeout, Sterm}, infinity, nil}]};

handle_event({timeout, {shrink, _} = Sterm}, _, _, #q_pool{shrink_timeout = St}) ->
    {keep_state_and_data, [{{timeout, Sterm}, get_shrink(1, St), nil}]};

%%%%%% overloaded checks

handle_event({timeout, overloaded}, _, _, #q_pool{q_count = Qc, max_q = Mq, p_count = Pc, ets = Ets} = CTX) when Pc > 0, Qc == 0; Qc < Mq ->
    ets:insert(Ets, {self(), 0}),
    {keep_state, CTX#q_pool{overloaded = 0}, [{{timeout, overloaded}, infinity, nil}]};

handle_event({timeout, overloaded}, _, _, _) -> 
    {keep_state_and_data, [{{timeout, overloaded}, 25, nil}]};

%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% monitoring events

handle_event(info, {'DOWN', Ref, process, Pid, _}, _, #q_pool{checked_out = Cout} = CTX) when is_map_key(Pid, Cout) ->
    {keep_state, worker_down(Ref, Pid, CTX), [{next_event, internal, start_worker}]};

handle_event(info, {'DOWN', _, process, Pid, _}, _, #q_pool{requests_monitors = Req_ms} = CTX) when is_map_key(Pid, Req_ms) ->
    {keep_state, requester_down(Pid, CTX), [{next_event, internal, dequeue}]};

handle_event(info, {'DOWN', _, process, Pid, _}, _, #q_pool{monitors = Ms} = CTX) when is_map_key(Pid, Ms) ->
    {keep_state, drowned_in_pool(Pid, CTX), [{next_event, internal, start_worker}]};

%%%%%% catch_all
handle_event(info, Msg, _, _) -> 
    io:format("workforce unexpected msg received: ~p~n", [Msg]),
    {keep_state_and_data, []};
handle_event(_, _, _, _) -> {keep_state_and_data, []}.


%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% internal functions to prevent repetition in the handles

%%%%%% worker related

-spec request_worker(CTX :: #q_pool{})-> N_CTX :: #q_pool{}.
request_worker(CTX) -> request_worker(CTX, nil).
request_worker(#q_pool{starting = Starting, watcher = Watcher} = CTX, Ref) ->
    Watcher ! {start_worker, self(), Ref},
    CTX#q_pool{starting = Starting + 1}.


-spec activate_worker(CTX :: #q_pool{}, Pid :: pid())-> N_CTX :: #q_pool{}.
activate_worker(#q_pool{p_count = Pc, active = A, pool = P, monitors = Ms, starting = S} = CTX, W_pid) ->
    
    Mref = monitor(process, W_pid),
    N_ms = maps:put(W_pid, Mref, Ms),
    N_pool = queue:in(W_pid, P),
    
    CTX#q_pool{p_count = Pc + 1, pool = N_pool, monitors = N_ms, active = A + 1, starting = S - 1}.


-spec worker_down(Monitor_ref :: reference(), Pid :: pid(), CTX :: #q_pool{})-> N_CTX :: #q_pool{}.
worker_down(Ref, Pid, #q_pool{active = A, checked_out = Cout, monitors = Ms, in_transit = It, requests_monitors = Req_ms} = CTX) ->
    {Client_ref, N_cout} = maps:take(Pid, Cout),
    {Ref, N_ms} = maps:take(Pid, Ms),
    N_it = maps:remove(Client_ref, It),
    N_req_ms = remove_request_monitor(Client_ref, Req_ms),
    

    CTX#q_pool{checked_out = N_cout, monitors = N_ms, active = A - 1, in_transit = N_it, requests_monitors = N_req_ms}.


-spec drowned_in_pool(Pid :: pid(), CTX :: #q_pool{})-> N_CTX :: #q_pool{}.
drowned_in_pool(Pid, #q_pool{pool = P, p_count = Pc, active = A, monitors = Ms} = CTX) ->
    N_pool = queue:filter(fun
                              (Pid2) when Pid2 == Pid -> false;
                              (_) -> true
                          end, P),
    
    {_, N_ms} = maps:take(Pid, Ms),
    CTX#q_pool{pool = N_pool, p_count = Pc - 1, active = A - 1, monitors = N_ms}.
          

-spec requester_down(Requester_pid :: pid(), CTX :: #q_pool{})-> N_CTX :: #q_pool{}.
requester_down(Req_pid, #q_pool{pool = P, p_count = Pc, checked_out = Cout, requests_monitors = Req_ms} = CTX) ->
    {All_checked_out, N_req_ms} = maps:take(Req_pid, Req_ms),
    {N_cout, N_pool, Plus_count} = lists:foldl(
                          fun({W_pid, _From, Mref}, {Acc_cout, Acc_pool, Count}) ->
                                  demonitor(Mref, [flush]),
                                  {maps:remove(W_pid, Acc_cout), queue:in(W_pid, Acc_pool), Count + 1}
                          end,
                         {Cout, P, 0},
                         All_checked_out
                        ),
    
    CTX#q_pool{pool = N_pool, p_count = Pc + Plus_count, checked_out = N_cout, requests_monitors = N_req_ms}.

%%%%%% queue ops

-spec add_to_queue(CTX :: #q_pool{}, From :: {pid(), reference()})-> N_CTX :: #q_pool{}. 
add_to_queue(#q_pool{queue = Q, q_count = Qc, q_track = Qt} = CTX, From) ->
    N_queue = queue:in(From, Q),
    N_queue_track = maps:put(From, 0, Qt),
    CTX#q_pool{queue = N_queue, q_count = Qc + 1, q_track = N_queue_track}.

-spec return_worker(CTX :: #q_pool{}, Worker_pid :: pid())-> N_CTX :: #q_pool{}.
return_worker(#q_pool{pool = P, p_count = Pc, checked_out = Cout, requests_monitors = Req_ms} = CTX, Pid) ->
    N_pool = queue:in(Pid, P),
    {Client_ref, N_cout} = maps:take(Pid, Cout),
    N_req_ms = remove_request_monitor(Client_ref, Req_ms),

    CTX#q_pool{pool = N_pool, p_count = Pc + 1, checked_out = N_cout, requests_monitors = N_req_ms}.


-spec remove_request_monitor(From :: {pid(), reference()}, Req_monitors :: map()) -> map().
remove_request_monitor({Req_pid, _} = Client_ref, Req_ms) ->
    case maps:take(Req_pid, Req_ms) of
        {[{_, _, Mref}], N_req_ms2} ->
            demonitor(Mref, [flush]),
            N_req_ms2;
        {Many, N_req_ms2} ->
            case lists:partition(fun({_, From, _}) -> From == Client_ref end, Many) of
                {[{_, _, Mref}], Remaining} ->
                    demonitor(Mref, [flush]),
                    case Remaining of
                        [] -> N_req_ms2;
                        [_|_] -> maps:put(Req_pid, Remaining, N_req_ms2)                        
                    end;
                {[], [_|_] = Remaining} -> 
                    maps:put(Req_pid, Remaining, N_req_ms2)
            end
    end.


-spec get_shrink(Type :: 1 | 0, Shrink_timeouts :: {non_neg_integer(), non_neg_integer()} | non_neg_integer())-> non_neg_integer().
get_shrink(0, {St, _})-> St;
get_shrink(1, {_, St}) -> St;
get_shrink(_, St) -> St.
