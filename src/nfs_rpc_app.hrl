-record(nfs_rpc_app_arg, {
          ref          :: any(),
          acceptor_num :: pos_integer(),
          trans_opts   :: list(proplists:property()),
          prg_num      :: pos_integer(),
          prg_name     :: atom(),
          prg_vsns     :: list(atom()),
          vsn_lo       :: pos_integer(),
          vsn_hi       :: pos_integer(),
          use_pmap     :: boolean(),
          mod          :: module(),
          init_args    :: list(),
          state        :: any()
         }).
