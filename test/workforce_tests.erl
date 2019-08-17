-module(workforce_tests).

%-ifdef(EUNIT).
-include_lib("eunit/include/eunit.hrl").
%-endif.

-include("workforce_shared.hrl").

-define(SUP_NAME, {local, test_sup}).
-define(POOL_NAME, {local, test_pool}).
-define(WATCHER_NAME, {local, test_watcher}).
-define(WORKER, {test_worker, start_link, []}).
-define(DEFAULT_W, 2).
-define(MAX_W, 2).
-define(MAX_Q, 0).

-define(FAULTY_ETS, faulty_ets).
-define(FAULTY_WORKER, {faulty_worker, start_link, [?FAULTY_ETS]}).

-define(CONFIG, #{
                  sup_name => ?SUP_NAME,
                  pool_name => ?POOL_NAME,
                  watcher_name => ?WATCHER_NAME,
                  worker => ?WORKER,
                  default_workers => ?DEFAULT_W,
                  max_workers => ?MAX_W,
                  max_queue => ?MAX_Q
                  }
        ).

-define(STATEM_CONFIG_W_DEFAULTS,
        #{
          active := 2,
          checked_out := #{},
          default_w := 2,
          hibernate_when_free := false,
          in_transit := #{},
          max_q := 0,
          max_w := 2,
          overloaded := 0,
          p_count := 2,
          pool := {[_],[_]}, % cheating, queues are opaque
          q_count := 0,
          q_track := #{},
          queue := {[],[]}, % cheating, queues are opaque
          requests_monitors := #{},
          starting := 0
         }
       ).

workforce_test_() ->
    [
     {"Turn off logs", fun() -> logger:add_handler_filter(default, ?MODULE, {fun(_,_) -> stop end, nostate}) end},
     {foreach,
      fun() -> basic_setup(?CONFIG) end,
      tear_down(),
      [
       fun ensure_pool_started/1,
       fun ensure_basic_ops/1,
       fun ensure_timeouts/1,
       fun ensure_workers_return_on_requester_death/1,
       fun ensure_pool_recovers_on_worker_death_when_not_checked_out/1,
       fun ensure_remote_checkouts/1,
       fun ensure_async_checkouts/1,
       fun ensure_supervision_works/1,
       fun ensure_watcher_keeps_track/1
      ]
     },
     
     {foreach,
      fun() -> setup_and_checkout(?CONFIG) end,
      tear_down(),
      [
       fun ensure_requests_monitoring/1,
       fun ensure_waiting_queue/1,
       fun ensure_workers_are_not_placed_again_in_pool_if_dead_while_checked_out/1,
       fun ensure_down_messages_when_checking_out/1,
       fun ensure_remote_checkouts_overload/1,
       fun ensure_synchronous_checkins/1,
       fun ensure_multiple_checkins_dont_add_extra_workers/1,
       fun ensure_coverage_paths/1
      ]
     },
     {"Pool grows and shrinks", fun ensure_pool_grows_and_shrinks/0},
     {"Queueing Works", fun ensure_queue_works/0},
     {"Starting Supervisor with MFA Works", fun ensure_supervisor_starts_w_mfa/0},
     {"Faulty workers still get totally working", fun ensure_faulty_starts/0},
     {"Timers for extra worker removal are canceled no matter what", fun ensure_timers_cancel/0}
    ].


ensure_pool_started({_, Sup_pid, Watcher_pid, Pool_pid}) ->
    fun() ->
            ?assertMatch({ok, ?STATEM_CONFIG_W_DEFAULTS}, wait_state_ready(Pool_pid, [{active, ?DEFAULT_W}], 500)),
            ?assert(whereis(element(2, ?SUP_NAME)) =:= Sup_pid),
            ?assert(is_pid(Watcher_pid)),
            ?assert(is_pid(Pool_pid)),
            ?assert(ets:whereis(?ETS_NAME) =/= undefined),
            ?assertMatch([{_, 0}], ets:lookup(?ETS_NAME, Pool_pid))
    end.

ensure_basic_ops({_, _, _, Pool_pid})->
    fun() ->
            {ok, Worker1} = workforce:checkout(Pool_pid),
            ?assert(is_pid(Worker1)),
            {ok, Worker2} = workforce:checkout(Pool_pid),
            ?assert(is_pid(Worker2)),

            ?assertMatch({error, overloaded}, workforce:checkout(Pool_pid, 100, false)),
            ok = workforce:checkin(Pool_pid, Worker2),
            ok = workforce:checkin(Pool_pid, Worker1),
            ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 2}, {overloaded, 0}])),
            {ok, Worker2} = workforce:checkout(Pool_pid),
            {ok, Worker1} = workforce:checkout(Pool_pid),
            
            ?assertMatch({error, overloaded}, workforce:checkout(Pool_pid, 100, false)),
            ?assertMatch([{_, 1}], ets:lookup(?ETS_NAME, Pool_pid)),
            True_self = self(),
            Extra_pid = spawn(fun() ->
                                      {ok, N_pid} = workforce:checkout(Pool_pid, 5000, true),
                                      True_self ! {self(), ok, N_pid}
                              end),

            ok = workforce:checkin(Pool_pid, Worker1),
            receive
                {Extra_pid, ok, Worker1} -> 
                    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 1}, {overloaded, 0}])),
                    ?assertMatch([{_, 0}], ets:lookup(?ETS_NAME, Pool_pid))
            after
                 100 -> ?assert(false)
            end
    end.

ensure_timeouts({_, _, _, Pool_pid})->
    fun() ->
            ?assertMatch({ok, Worker1} when is_pid(Worker1), workforce:checkout(Pool_pid)),
            ?assertMatch({ok, Worker2} when is_pid(Worker2), workforce:checkout(Pool_pid)),
            ?assertMatch({error, timeout}, workforce:checkout(Pool_pid, 1, true))
    end.

ensure_workers_return_on_requester_death({_, _, _, Pool_pid})->
    fun() ->
            True_self = self(),
            Requester = spawn(fun()->
                                      {ok, Pid1} = workforce:checkout(Pool_pid),
                                      {ok, Pid2} = workforce:checkout(Pool_pid),
                                      True_self ! {self(), ok, Pid1, Pid2},
                                      receive
                                          exit -> ok
                                      end
                              end),
            receive
                {Requester, ok, Pid1, Pid2} ->
                    {ok, #{checked_out := Cout, requests_monitors := Req_ms, pool := P}} = wait_state_ready(Pool_pid, [{p_count, 0}]),
                    #{Pid1 := {Requester, Ref1}, Pid2 := {Requester, Ref2}} = Cout,
                    ?assertMatch(#{Requester := [{Pid2, {Requester, Ref2}, _}, {Pid1, {Requester, Ref1}, _}]}, Req_ms),
                    ?assert(queue:len(P) == 0),

                    Requester ! exit,
                    {ok, #{checked_out := Cout2, requests_monitors := Req_ms2, pool := P2}} = wait_state_ready(Pool_pid, [{p_count, 2}]),
                    ?assert(queue:len(P2) == 2),
                    ?assert(queue:member(Pid1, P2)),
                    ?assert(queue:member(Pid2, P2)),
                    ?assert(Cout2 =:= #{}),
                    ?assert(Req_ms2 =:= #{})
            end
    end.

ensure_pool_recovers_on_worker_death_when_not_checked_out({_, _, Watcher_pid, Pool_pid})->
    fun() ->
            {ok, #{pool := P}} = wait_state_ready(Pool_pid, [{p_count, 2}]),
            {{value, Worker1}, P1} = queue:out(P),
            {{value, Worker2}, _} = queue:out(P1),

            gen_server:cast(Watcher_pid, {decomissioned, Worker1}),
            gen_server:cast(Watcher_pid, {decomissioned, Worker2}),
            {ok, #{pool := P2, monitors := Mons}} = wait_state_ready(Pool_pid, [{p_count, 2}, {monitors, fun(Ms)-> not is_map_key(Worker1, Ms) and not is_map_key(Worker2, Ms) end}]),
            ?assert(queue:len(P2) == 2),
            ?assert(not queue:member(Worker1, P2)),
            ?assert(not queue:member(Worker2, P2)),
            ?assert(not is_map_key(Worker1, Mons)),
            ?assert(not is_map_key(Worker2, Mons)),
            {{value, N_worker1}, P3} = queue:out(P2),
            {{value, N_worker2}, _} = queue:out(P3),

            ?assert(is_map_key(N_worker1, Mons)),
            ?assert(is_map_key(N_worker2, Mons))
    end.

ensure_remote_checkouts({_, _, _, Pool_pid})->
    fun() ->
            Extra = spawn(
                     fun() ->
                             receive
                                 start ->
                                     {ok, Pid} = workforce:remote_checkout(Pool_pid, 10, force),
                                     ok = workforce:checkin(Pool_pid, Pid),
                                     ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 2}, {overloaded, 0}])),
                                     {ok, Pid2} = workforce:remote_checkout(Pool_pid),
                                     workforce:checkin(Pool_pid, Pid2)
                             end
                     end),
            
            erlang:trace_pattern(send, [
                                        {[Pool_pid, {'$gen_call', {Extra, '_'}, checkout}],[],[]},
                                        {['_', {checkout, {Extra, '_'}, '_'}], [], []}
                                       ], []),
            erlang:trace(Extra, true, [send]),
            
            Extra ! start,
            receive {trace, _, send, {'$gen_call', {Extra, _}, checkout}, Pool_pid} -> ok
            after 100 -> ?assert(false)
            end,
            
            % the second checkout was made without force and since the pool is local it should bypass the gen_state:call and do instead the regular checkout
            receive {trace, _, send, {checkout, {Extra, _}, false}, Pool_pid} -> ok
            after 100 -> ?assert(false)
            end,
            erlang:trace(Extra, false, [send])
    end.


ensure_async_checkouts({_, _, _, Pool_pid}) ->
    fun() ->
            Mref = workforce:async_checkout(Pool_pid),
            ?assert(is_reference(Mref)),
            Pid1 = receive {Mref, Pid_internal} when is_pid(Pid_internal) ->
                          ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 1}, {in_transit, fun(It)-> is_map_key({self(), Mref}, It) end}])),
                          workforce:async_confirm(Pool_pid, Mref),
                          ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 1}, {in_transit, #{}}])),
                          Pid_internal
                  after 100 -> 
                          ?assert(false),
                          false
                              
                  end,

            ?assert(is_pid(Pid1)),

            Mref2 = workforce:async_checkout(Pool_pid),
            ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 0}])),
            receive {Mref2, Pid2} when is_pid(Pid2) ->
                    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{in_transit, fun(It)-> is_map_key({self(), Mref2}, It) end}])),
                    workforce:async_cancel(Pool_pid, Mref2),
                    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 1}, {in_transit, #{}}]))
            after 100 -> ?assert(false)
            end,
            
            Mref3 = workforce:async_checkout(Pool_pid),
            receive {Mref3, Pid3} when is_pid(Pid3) ->
                    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 0}, {in_transit, fun(It)-> is_map_key({self(), Mref3}, It) end}])),
                    workforce:async_confirm(Pool_pid, Mref3),
                    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 0}, {in_transit, #{}}]))
            after 100 -> ?assert(false)
            end,   

            Mref4 = workforce:async_checkout(Pool_pid, false, force),
            receive {Mref4, overloaded} -> ok
            after 100 -> ?assert(false)
            end,
            
            Mref5 = workforce:async_checkout(Pool_pid, true, force),
            receive {Mref5, enqueued} -> ok
            after 100 -> ?assert(false)
            end,

            workforce:checkin(Pool_pid, Pid1),
            receive {Mref5, Pid1} -> ok
            after 100 -> ?assert(false)
            end
    end.

ensure_supervision_works({_, Sup_pid, Watcher_pid, Pool_pid}) ->
    fun() ->
            {ok, #{pool := P}} = wait_state_ready(Pool_pid, [{p_count, 2}]),
            exit(Pool_pid, kill),
            ?assertMatch(true, wait_until(fun() -> is_pid(whereis(element(2, ?POOL_NAME))) end)),
            timer:sleep(1),
            N_pid = whereis(element(2, ?POOL_NAME)),
            {ok, #{pool := N_p}} = wait_state_ready(N_pid, [{p_count, 2}]),
            {{value, Worker1}, P2} = queue:out(P),
            {{value, Worker2}, _} = queue:out(P2),
            {{value, N_worker1}, N_p2} = queue:out(N_p),
            {{value, N_worker2}, _} = queue:out(N_p2),
            ?assert(not lists:member(Worker1, [N_worker1, N_worker2]) and not lists:member(Worker2, [N_worker1, N_worker2])),
            ?assert(not is_process_alive(Worker1)),
            ?assert(not is_process_alive(Worker2)),
            ?assert(whereis(element(2, ?WATCHER_NAME)) =/= Watcher_pid),
            ?assert(whereis(element(2, ?SUP_NAME)) =:= Sup_pid)
    end.

ensure_watcher_keeps_track({#{default_workers := Def_w}, _, Watcher_pid, Pool_pid})->
    fun() ->
            Workers = gen_server:call(Watcher_pid, get_workers),
            ?assert(length(Workers) =:= Def_w),
            lists:map(fun(Worker) -> exit(Worker, kill) end, Workers),
            ?assertMatch({ok, _}, wait_state_ready(
                                    Pool_pid,
                                    [
                                     {active, Def_w},
                                     {monitors, fun(Ms) ->
                                                        not lists:any(fun(W) -> is_map_key(W, Ms) end, Workers) end}
                                    ]
                                   )
                        ),
            Workers2 = gen_server:call(Watcher_pid, get_workers),
            ?assert(length(Workers2) =:= Def_w)
    end.



ensure_requests_monitoring({{_, _, _, Pool_pid}, {Req_pid, Worker1, Worker2}})->
    fun() ->
            {ok, #{requests_monitors := Mons}} = wait_state_ready(Pool_pid, [{q_count, 0}, {p_count, 0}]),
            Request_list = maps:get(Req_pid, Mons),
            ?assert(lists:all(
                      fun({Pid, {R_pid, _}, _Mref})-> (R_pid =:= Req_pid) and ((Pid =:= Worker1) or (Pid =:= Worker2)) end,
                      Request_list
                     )
                   ),
            ok = workforce:checkin(Pool_pid, Worker1),
            ?assertMatch(
               {ok, #{requests_monitors := #{Req_pid := [{Worker2, {Req_pid, _}, _}]}}},
               wait_state_ready(Pool_pid, [{q_count, 0}, {p_count, 1}])
              ),
            ok = workforce:checkin(Pool_pid, Worker2),
            ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, 2}, {requests_monitors, #{}}]))
                
    end.

ensure_waiting_queue({{_, _, _, Pool_pid}, {Req_pid, Worker1, Worker2}})->
    fun() ->
            True_self = self(),
            ?assertMatch({error, timeout}, workforce:checkout(Pool_pid, 1, true)),
            ?assertMatch({error, timeout}, workforce:checkout(Pool_pid, 1, true)),

            Extra3 = spawn(fun() ->
                                  {ok, N_Pid} = workforce:checkout(Pool_pid, infinity, true),
                                   True_self ! {self(), ok, N_Pid},
                                   receive
                                       exit -> workforce:checkin(N_Pid)
                                   end
                           end),

            {ok, #{queue := Q}} = wait_state_ready(Pool_pid, [{q_count, 1}]),
            % to make it speedy gonzalez we never filter the queue when enqueued requests are canceled (although ofc we still decrease the q_count field by one), since that can be a significant bottleneck, instead we mark the same `From` that is in the queue as being canceled on the q_track map, by changing its value from 0 to 1, when an actual dequeueing happens we remove items from the queue until we find one that wasn't canceled. So at this point, even though the first 2 requests have been canceled by timeout, they're still in the "queue" list
            ?assert(queue:len(Q) == 3),
            ok = workforce:checkin(Pool_pid, Worker1),

            receive
                {Extra3, ok, Worker1} ->
                    % here we actually check that the queue is now totally empty, because there was a checkin when the q_count was > 0, there was also a dequeue event, which should clean up the queue up to that event, meaning the two "canceled" requests were also correctly removed from the "queue" queue and everything works as advertised
                    {ok, #{requests_monitors := Req_ms}} = wait_state_ready(Pool_pid, [{p_count, 0}, {q_count, 0}, {queue, fun queue:is_empty/1}]),
                    ?assertMatch(#{Req_pid := [{Worker2, {Req_pid, _}, _}], Extra3 := [{Worker1, {Extra3, _}, _}]}, Req_ms)    
            end
    end.

ensure_workers_are_not_placed_again_in_pool_if_dead_while_checked_out({{_, _, Watcher_pid, Pool_pid}, {_, Worker1, _Worker2}})->
    fun() ->
            wait_state_ready(Pool_pid, [{p_count, 0}]),
            gen_server:cast(Watcher_pid, {decomissioned, Worker1}),
            {ok, #{pool := P, monitors := Mons}} = wait_state_ready(Pool_pid, [{p_count, 1}]),
            ?assert(not queue:member(Worker1, P)),
            ?assert(not is_map_key(Worker1, Mons)),

            ok = workforce:checkin(Pool_pid, Worker1),
            ?assert(message_queue_is_n(Pool_pid, 0)),
            {ok, #{pool := P2, monitors := Mons2}} = wait_state_ready(Pool_pid, [{p_count, 1}]),
            ?assert(not queue:member(Worker1, P2)),
            ?assert(not is_map_key(Worker1, Mons2)),
            ?assert(maps:size(Mons2) =:= 2)
    end.

ensure_down_messages_when_checking_out({{_, _, _Watcher_pid, Pool_pid}, {_, _Worker1, _Worker2}}) ->
    fun() ->
            True_self = self(),
            Extra1 = spawn(fun() ->
                                   ?assertMatch({error, {pool_down, _}}, workforce:checkout(Pool_pid, 5000, true)),
                                   True_self ! {self(), pool_down}
                            end
                           ),

            Mref = workforce:async_checkout(Pool_pid, true),
            exit(Pool_pid, shutdown),
            receive {Extra1, pool_down} -> ?assert(true)
            after 10 -> ?assert(false)
            end,
            
            receive {'DOWN', Mref, _, _Pool_Pid, _} -> ?assert(true)
            after 10 -> ?assert(false)
            end
    end.

ensure_remote_checkouts_overload({{_, _, _Watcher_pid, Pool_pid}, {_, Worker1, _Worker2}}) ->
    fun() ->
            ok = workforce:checkin(Pool_pid, Worker1),
            {ok, Worker1} = workforce:remote_checkout(Pool_pid, 100, force),
            {ok, #{ets := Ets}} = wait_state_ready(Pool_pid, [{overloaded, 1}]),
            ?assertMatch([{Pool_pid, 1}], ets:lookup(Ets, Pool_pid))
    end.

ensure_synchronous_checkins({{_, _, _, Pool_pid}, {_, Worker1, Worker2}}) ->
    fun()->
            ok = workforce:synchronous_checkin(Pool_pid, Worker1),
            {ok, _} = wait_state_ready(Pool_pid, [{p_count, 1}]),
            ok = workforce:synchronous_checkin(Pool_pid, Worker2),
            {ok, #{pool := P}} = wait_state_ready(Pool_pid, [{p_count, 2}]),
            ?assert(queue:member(Worker1, P) and queue:member(Worker2, P))
    end.

ensure_multiple_checkins_dont_add_extra_workers({{_, _, _Watcher_pid, Pool_pid}, {_, Worker1, Worker2}}) ->
    fun()->
            ok = workforce:synchronous_checkin(Pool_pid, Worker1),
            {ok, _} = wait_state_ready(Pool_pid, [{p_count, 1}]),
            ok = workforce:synchronous_checkin(Pool_pid, Worker2),
            {ok, _} = wait_state_ready(Pool_pid, [{p_count, 2}]),
            ok = workforce:synchronous_checkin(Pool_pid, Worker2),
            ok = workforce:synchronous_checkin(Pool_pid, Worker1),
            {ok, Worker1} = workforce:checkout(Pool_pid),
            {ok, _} = wait_state_ready(Pool_pid, [{p_count, 1}])
    end.

ensure_coverage_paths({{_, _, _, _}, {_, Worker1, Worker2}})->
    fun() ->
            ?assertMatch({error, overloaded}, workforce:checkout(?POOL_NAME)),
            ?assertMatch({error, {no_such_pool, inexistent}}, workforce:checkout(inexistent)),
            Mref = workforce:async_checkout(?POOL_NAME),
            receive 
                {Mref, overloaded} -> ?assert(true)
            after
                10 -> ?assert(false)
            end,
            Mref2 = workforce:async_checkout(?POOL_NAME, false, force),
            receive 
                {Mref2, overloaded} -> ?assert(true)
            after
                10 -> ?assert(false)
            end,
            
            ?assertMatch({error, overloaded}, workforce:remote_checkout(?POOL_NAME)),
            ?assertMatch({error, overloaded}, workforce:remote_checkout(?POOL_NAME, 5000, force)),
            ?assertMatch({error, {no_such_pool, inexistent}}, workforce:remote_checkout(inexistent)),
            ?assertMatch({error, {no_such_pool, inexistent}}, workforce:remote_checkout(inexistent, 5000, force)),
            ?assertMatch({error, {no_such_pool, inexistent}}, workforce:async_checkout(inexistent)),
            ?assertMatch({error, {no_such_pool, inexistent}}, workforce:async_checkout(inexistent, false, force)),
            
            Mref3 = workforce:async_checkout(?POOL_NAME, true),
            ok = workforce:checkin(?POOL_NAME, Worker1),
            receive {Mref3, Worker1} -> ok
            after 10 -> ?assert(false)
            end,
            
            ?assertMatch({error, {no_such_pool, inexistent}}, workforce:async_confirm(inexistent, Mref3)),
            workforce:async_confirm(?POOL_NAME, Mref3),
            demonitor(Mref3, [flush]),
            ?assertMatch({error, {no_such_pool, inexistent}}, workforce:checkin(inexistent, Mref3)),
            
            ok = workforce:checkin(?POOL_NAME, Worker1),
            Mref4 = workforce:async_checkout(?POOL_NAME, true),
            receive {Mref4, Worker1} -> ok
            after 10 -> ?assert(false == yes)
            end,                    
            
            ?assertMatch({error, {no_such_pool, inexistent}}, workforce:async_cancel(inexistent, Mref4)),
            workforce:async_cancel(?POOL_NAME, Mref4),
            ok = workforce:synchronous_checkin(?POOL_NAME, Worker2)
    end.

ensure_pool_grows_and_shrinks()->
    {
     #{default_workers := 5 = Def_w, max_workers := 10 = Max_w},
     Sup_pid,
     _,
     Pool_pid
    } = basic_setup(maps:merge(?CONFIG, #{default_workers => 5, max_workers => 10, shrink_timeout => 1})),
    
    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{p_count, Def_w}, {active, Def_w}])),
    
    All_checked_out = lists:map(
                        fun(_) ->
                                {ok, Pid} = workforce:checkout(Pool_pid),
                                Pid
                        end, 
                        lists:duplicate(Max_w, nil)
                       ),
    
    {ok, #{monitors := Ms}} = wait_state_ready(Pool_pid, [{p_count, 0}, {active, Max_w}]),
    ?assert(maps:size(Ms) =:= Max_w),
    All_pids_monitored = maps:keys(Ms),
    ?assert(lists:all(fun(Pid) -> lists:member(Pid, All_pids_monitored) end, All_checked_out)),
    
    % rule for decomissioning workers is Active > Default AND Free_Pool_count > (Default / 5)
    Needed_checkins_for_1_kill = ceil(Def_w / 5 + 1),
    
    {To_checkin, Remaining} = lists:split(Needed_checkins_for_1_kill, All_checked_out),
    lists:map(fun(Pid)-> workforce:checkin(Pool_pid, Pid) end, To_checkin),
    
    {ok, #{monitors := Ms2}} = wait_state_ready(Pool_pid, [{active, Max_w - 1}]),
    ?assert(maps:size(Ms2) =:= Max_w - 1),
    
    lists:map(fun(Pid) -> workforce:checkin(Pool_pid, Pid) end, Remaining),
    
    {ok, #{monitors := Ms3}} = wait_state_ready(Pool_pid, [{p_count, Def_w}, {active, Def_w}]),
    ?assert(maps:size(Ms3) =:= Def_w),
    
    Decomissioned = All_checked_out -- maps:keys(Ms3),
    ?assert(length(Decomissioned) =:= Max_w - Def_w),
    
    lists:map(fun(Pid) ->
                      case lists:member(Pid, Decomissioned) of
                          true -> ?assert(wait_until(fun() -> not is_process_alive(Pid) end));
                          false -> ?assert(is_process_alive(Pid))
                      end
              end,
              All_checked_out
             ),

    do_tear_down(Sup_pid).

ensure_queue_works()->    
    {
     #{default_workers := 2 = _Def_w, max_workers := 3 = _Max_w, max_queue := 1 = _Max_q},
     Sup_pid,
     _,
     Pool_pid
    } = basic_setup(maps:merge(?CONFIG, #{default_workers => 2, max_workers => 3, max_queue => 1})),
    
    {ok, Worker1} = workforce:checkout(Pool_pid),
    {ok, _Worker2} = workforce:checkout(Pool_pid),
    {ok, _Worker3} = workforce:checkout(Pool_pid),
    {error, timeout} = workforce:checkout(Pool_pid, 10),
    
    True_self = self(),
    Extra_1 = spawn(fun() ->
                            {ok, Pid} = workforce:checkout(Pool_pid),
                            True_self ! {self(), ok, Pid},
                            receive
                                exit -> ok
                            end
                    end),

    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{q_count, 1}])),
    {error, overloaded} = workforce:checkout(Pool_pid, 10),

    ok = workforce:checkin(Pool_pid, Worker1),
    receive
        {Extra_1, ok, Worker1} -> 
            ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{q_count, 0}, {overloaded, 0}])),
            ?assertMatch({error, timeout}, workforce:checkout(Pool_pid, 10))
    after
        10 -> ?assert(false)
    end,

    do_tear_down(Sup_pid).

ensure_supervisor_starts_w_mfa()->
    {ok, Sup_pid} = workforce_supervisor:start_link(?WORKER),
    #{
      watcher_name := Watcher,
      pool_name := Pool,
      default_workers := Def_w,
      max_workers := Max_w,
      max_queue := Max_q,
      hibernate_when_free := HWF,
      shrink_timeout := St
     } = ?DEFAULT_CONFIG,
    
    Pool_pid = whereis(element(2, Pool)),
    ?assert(is_pid(Pool_pid)),

    ?assertMatch({ok, #{default_w := Def_w, max_w := Max_w, hibernate_when_free := HWF, shrink_timeout := St, max_q := Max_q}}, wait_state_ready(Pool_pid, [{default_w, Def_w}])),
    Watcher_pid = whereis(element(2, Watcher)),
    ?assert(is_pid(Watcher_pid)),
    
    % this part is just to test the paths of the ets holder on the supervisor
    unlink(Sup_pid),
    exit(Sup_pid, kill),
    wait_until(fun() -> not is_process_alive(Sup_pid) and not is_process_alive(Pool_pid) and not is_process_alive(Watcher_pid) end),
    {ok, Sup_pid2} = workforce_supervisor:start_link(?WORKER),
    Pool_pid_2 = whereis(element(2, Pool)),
    ?assert(is_pid(Pool_pid_2)),
    ?assertMatch({ok, #{default_w := Def_w, max_w := Max_w, hibernate_when_free := HWF, shrink_timeout := St, max_q := Max_q}}, wait_state_ready(Pool_pid_2, [{default_w, Def_w}])),
    
    do_tear_down(Sup_pid2).
    
ensure_faulty_starts() ->
    ets:new(?FAULTY_ETS, [public, named_table]),
    ets:insert(?FAULTY_ETS, {start, yes, no}),
    {ok, Sup_pid} = workforce_supervisor:start_link(?FAULTY_WORKER),
    #{default_workers := Def_w, pool_name := Pool} = ?DEFAULT_CONFIG,
    Pool_pid = whereis(element(2, Pool)),
    ?assertMatch({ok, #{default_w := Def_w}}, wait_state_ready(Pool_pid, [{default_w, Def_w}]), 500),
    do_tear_down(Sup_pid).

ensure_timers_cancel() ->
    Config = maps:merge(?CONFIG, #{default_workers => 0, max_workers => 1, shrink_timeout => 100, worker => ?WORKER}),
    {ok, Sup_pid} = workforce_supervisor:start_link(Config),
    Pool_pid = whereis(element(2, ?POOL_NAME)),

    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{default_w, 0}, {max_w, 1}, {active, 0}, {state, ready}])),

    erlang:trace_pattern({gen_statem, loop, 3}, [{['$1', '$2', '$3'], [], [{return_trace}]}], [local]),
    erlang:trace(Pool_pid, true, [call]),

    {ok, Worker1} = workforce:checkout(Pool_pid),
    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{active, 1}, {p_count, 0}])),

    receive {trace, Pool_pid, _, {_, _, [_, _, {state, _, _, {Timeouts, _}, _}]}} -> 
            ?assert(maps:size(Timeouts) =:= 1),
            exit(Worker1, kill),
            wait_until(fun() -> not is_process_alive(Worker1) end)
    after 100 -> ?assert(false)
    end,
    
    ?assertMatch({ok, _}, wait_state_ready(Pool_pid, [{active, 0}, {state, ready}])),
    ?assertMatch(true, 
                 wait_until(fun() ->
                                    receive {trace, Pool_pid, _, {_, _, [_, _, {state, _, _, {Timeouts2, _}, _}]}} -> 
                                            maps:size(Timeouts2) =:= 0

                                    after 200 -> false
                                    end
                            end, 200)
                ),

    do_tear_down(Sup_pid).
            
    

%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% Setups
%%%%%%%%%%%%%%%%%%%%%%%%

basic_setup(#{default_workers := D_w} = Config) ->
    {ok, Sup_pid} = workforce_supervisor:start_link(Config),
    Pool_pid = whereis(element(2, ?POOL_NAME)),
    Watcher_pid = whereis(element(2, ?WATCHER_NAME)),
    {ok, #{watcher := Watcher_pid}} = wait_state_ready(Pool_pid, [{active, D_w}], 500),
    {Config, Sup_pid, Watcher_pid, Pool_pid}.

setup_and_checkout(Config) ->
    {_, _, _, Pool_pid} = Start_tuple = basic_setup(Config),
    {ok, Worker1} = workforce:checkout(Pool_pid),
    {ok, Worker2} = workforce:checkout(Pool_pid),
    {Start_tuple, {self(), Worker1, Worker2}}.    

tear_down()->
  fun({_, Sup_pid, _, _}) -> do_tear_down(Sup_pid);
     ({{_, Sup_pid, _, _}, _}) -> do_tear_down(Sup_pid)
  end.

do_tear_down(Sup_pid) ->
    process_flag(trap_exit, true),
    exit(Sup_pid, shutdown),
    receive
        {'EXIT', Sup_pid, _} -> ?assert(true)
    after
        250 -> ?assert(false)
    end.



%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%% Helpers
%%%%%%%%%%%%%%%%%%%%%%%%

wait_state_ready(Pid, Key_vals) ->
    wait_state_ready(Pid, Key_vals, 100).

wait_state_ready(Pid, Key_vals, Timeout) ->
    Time = erlang:system_time(millisecond),
    wait_state_ready(Pid, Key_vals, Timeout, Time).
  
wait_state_ready(Pid, Key_vals, Timeout, Time) ->  
    case has_timed_out(Time, Timeout) of
        true -> false;
        _  -> 
            State = workforce:state_as_map(Pid),
            case lists:all(
                   fun
                       ({Key, Fun}) when is_function(Fun) -> 
                           #{Key := Val} = State,
                           Fun(Val);
                       ({Key, Val}) -> Val == maps:get(Key, State, '$nope')
                   end,
                   Key_vals
                  ) of

                true -> {ok, State};
                false ->  wait_state_ready(Pid, Key_vals, Timeout, Time)
            end
    end.

has_timed_out(Time, Timeout)->
    Time_now = erlang:system_time(millisecond),
    (Time_now - Time) > Timeout.


message_queue_is_n(Pid, N) ->
    message_queue_is_n(Pid, N, 100).

message_queue_is_n(Pid, N, Timeout) ->
    Time = erlang:system_time(millisecond),
    message_queue_is_n(Pid, N, Timeout, Time).

message_queue_is_n(Pid, N, Timeout, Time) ->
    case has_timed_out(Time, Timeout) of
        true -> false;
        false -> 
            case process_info(Pid, message_queue_len) of
                {message_queue_len, N} -> true;
                _ -> message_queue_is_n(Pid, N, Timeout, Time)
            end
    end.

wait_until(Fun) when is_function(Fun)->
    wait_until(Fun, 100).

wait_until(Fun, Timeout) ->
    Time = erlang:system_time(millisecond),
    wait_until(Fun, Timeout, Time).

wait_until(Fun, Timeout, Time)->
    case has_timed_out(Time, Timeout) of
        true -> false;
        false ->
            case Fun() of
                true ->  true;
                _ -> wait_until(Fun, Timeout, Time)
            end
    end.
                            
    
