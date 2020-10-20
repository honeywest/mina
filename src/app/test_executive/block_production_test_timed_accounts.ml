open Integration_test_lib
open Core_kernel

module Make (Engine : Engine_intf) = struct
  open Engine

  (* TODO: find a way to avoid this type alias (first class module signatures restrictions make this tricky) *)
  type network = Network.t

  type log_engine = Log_engine.t

  let block_producer_balance = "1000"

  let config =
    let open Test_config in
    let open Test_config.Block_producer in
    let open Currency in
    let balance = Balance.of_int 100_000_000_000 in
    (*Should fully vest by slot = 7 provided blocks are produced from slot 1*)
    let timing : Coda_base.Account_timing.t =
      Timed
        { initial_minimum_balance= balance
        ; cliff_time= Coda_numbers.Global_slot.of_int 4
        ; vesting_period= Coda_numbers.Global_slot.of_int 2
        ; vesting_increment= Amount.of_int 50_000_000_000 }
    in
    {default with block_producers= [{balance= block_producer_balance; timing}]}

  let expected_balance blocks ~slots init_balance ~slots_with_locked_tokens
      ~(constraint_constants : Genesis_constants.Constraint_constants.t) =
    let open Currency in
    let normal_coinbase = constraint_constants.coinbase_amount in
    let scale_exn amt i = Option.value_exn (Amount.scale amt i) in
    let supercharged_coinbase =
      scale_exn constraint_constants.coinbase_amount
        constraint_constants.supercharged_coinbase_factor
    in
    (*Using slot number to determine if there are any locked token because some slots might be empty due to node initialization time*)
    let supercharged_coinbase_blocks =
      max 0 (slots - slots_with_locked_tokens)
    in
    let normal_coinbase_blocks = blocks - supercharged_coinbase_blocks in
    (* init balance +
                (normal_coinbase * slots_with_locked_tokens) +
                (supercharged_coinbase * remaining slots))*)
    Balance.add_amount
      ( Balance.add_amount init_balance
          (scale_exn normal_coinbase normal_coinbase_blocks)
      |> Option.value_exn )
      (scale_exn supercharged_coinbase supercharged_coinbase_blocks)
    |> Option.value_exn

  let run network log_engine =
    let open Network in
    let open Malleable_error.Let_syntax in
    let block_producer = List.nth_exn network.Network.block_producers 0 in
    let%bind () = Log_engine.wait_for_init block_producer log_engine in
    let%bind ( `Blocks_produced blocks_produced
             , `Slots_passed slots
             , `Snarked_ledgers_generated _snarked_ledger_generated ) =
      Log_engine.wait_for ~blocks:8 ~snarked_ledgers_generated:1
        ~timeout:(`Slots 30) log_engine
    in
    let logger = Logger.create () in
    [%log info] "blocks produced %d slots passed %d" blocks_produced slots ;
    let expected_balance =
      expected_balance blocks_produced ~slots
        (Currency.Balance.of_formatted_string block_producer_balance)
        ~slots_with_locked_tokens:7
        ~constraint_constants:network.constraint_constants
    in
    let pk =
      (List.hd_exn network.keypairs).public_key
      |> Signature_lib.Public_key.compress
    in
    let%map balance =
      Node.get_balance ~logger
        ~account_id:Coda_base.(Account_id.create pk Token_id.default)
        block_producer
    in
    [%test_eq: Currency.Balance.t] balance expected_balance ;
    [%log info] "Block producer test with locked accounts completed"
end
