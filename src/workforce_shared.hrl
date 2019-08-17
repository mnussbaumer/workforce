-define(ETS_NAME, '$workforce_ets').
-define(ETS_HOLDER, '$workforce_ets_holder').

-define(DEFAULT_CONFIG,
        #{
          sup_name => {local, workforce_supervisor},
          watcher_name => {local, workforce_watcher},
          pool_name => {local, workforce},
          worker => nil,
          default_workers => 10,
          max_workers => 10,
          max_queue => 0,
          hibernate_when_free => false,
          shrink_timeout => {2000, 7000}
         }).

-type name() :: 
        Name :: (atom() | pid()) |
        {Name :: atom(), node()} |
        {local, Name :: atom()} |
        {global, GlobalName :: any()} |
        {via, Module :: atom(), ViaName :: any()}.

-type workforce_config() :: 
        #{
          worker := {atom(), atom(), [any()]} | nil,
          sup_name := name(),
          watcher_name := name(),
          pool_name := name(),
          default_workers := pos_integer(),
          max_workers := pos_integer(),
          max_queue := integer(),
          hibernate_when_free := boolean(),
          shrink_timeout := {non_neg_integer(), non_neg_integer()} | non_neg_integer()
         }.

-type no_such_pool() :: {Error :: no_such_pool, Name :: term()}.

-type checkout_error() :: 
        Error :: (overloaded | timeout) |
        no_such_pool() |
        {Error :: pool_down, Reason :: term()}.

-type async_checkout_resp() :: reference() | no_such_pool().

-type checkout_resp() :: {ok, pid()} | {error, checkout_error()}.
-type remote_resp() :: checkout_resp() | no_return().
