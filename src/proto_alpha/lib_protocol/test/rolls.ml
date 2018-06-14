(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Proto_alpha
open Alpha_context

let account_pair = function
  | [a1; a2] -> (a1, a2)
  | _ -> assert false

let wrap e = Lwt.return (Alpha_environment.wrap_error e)
let traverse_rolls ctxt head =
  let rec loop acc roll =
    Storage.Roll.Successor.get_option ctxt roll >>= wrap >>=? function
    | None -> return (List.rev acc)
    | Some next -> loop (next :: acc) next in
  loop [head] head

let get_rolls ctxt delegate =
  Storage.Roll.Delegate_roll_list.get_option ctxt delegate >>= wrap >>=? function
  | None -> return []
  | Some head_roll -> traverse_rolls ctxt head_roll

let check_rolls b (account:Account.t) =
  Context.get_constants (B b) >>=? fun constants ->
  Context.Delegate.info (B b) account.pkh >>=? fun { staking_balance } ->
  let token_per_roll = constants.parametric.tokens_per_roll in
  let expected_rolls = Int64.div (Tez.to_mutez staking_balance) (Tez.to_mutez token_per_roll) in
  Raw_context.prepare b.context
    ~level:b.header.shell.level
    ~timestamp:b.header.shell.timestamp
    ~fitness:b.header.shell.fitness >>= wrap >>=? fun ctxt ->
  get_rolls ctxt account.pkh >>=? fun rolls ->
  Assert.equal_int ~loc:__LOC__ (List.length rolls) (Int64.to_int expected_rolls)

let check_no_rolls (b : Block.t) (account:Account.t) =
  Raw_context.prepare b.context
    ~level:b.header.shell.level
    ~timestamp:b.header.shell.timestamp
    ~fitness:b.header.shell.fitness >>= wrap >>=? fun ctxt ->
  get_rolls ctxt account.pkh >>=? fun rolls ->
  Assert.equal_int ~loc:__LOC__ (List.length rolls) 0

let simple_staking_rights () =
  Context.init 2 >>=? fun (b,accounts) ->
  let (a1, a2) = account_pair accounts in

  Context.Contract.balance (B b) a1 >>=? fun balance ->
  Context.Contract.manager (B b) a1 >>=? fun m1 ->

  Context.Delegate.info (B b) m1.pkh >>=? fun info ->
  Assert.equal_tez ~loc:__LOC__ balance info.staking_balance >>=? fun () ->
  check_rolls b m1

let simple_staking_rights_after_baking () =
  Context.init 2 >>=? fun (b,accounts) ->
  let (a1, a2) = account_pair accounts in

  Context.Contract.balance (B b) a1 >>=? fun balance ->
  Context.Contract.manager (B b) a1 >>=? fun m1 ->
  Context.Contract.manager (B b) a2 >>=? fun m2 ->

  Block.bake_n ~policy:(By_account m2.pkh) 5 b >>=? fun b ->

  Context.Delegate.info (B b) m1.pkh >>=? fun info ->
  Assert.equal_tez ~loc:__LOC__ balance info.staking_balance >>=? fun () ->
  check_rolls b m1 >>=? fun () ->
  check_rolls b m2

let frozen_deposit (info:Context.Delegate.info) =
  Cycle.Map.fold (fun _ { Delegate.deposit } acc ->
      Test_tez.Tez.(deposit + acc))
    info.frozen_balance_by_cycle Tez.zero

let check_activate_staking_balance ~loc ~deactivated b (a, (m:Account.t)) =
  Context.Delegate.info (B b) m.pkh >>=? fun info ->
  Assert.equal_bool ~loc info.deactivated deactivated >>=? fun () ->
  Context.Contract.balance (B b) a >>=? fun balance ->
  let deposit = frozen_deposit info in
  Assert.equal_tez ~loc Test_tez.Tez.(balance + deposit) info.staking_balance

let run_until_deactivation () =
  Context.init ~preserved_cycles:2 2 >>=? fun (b,accounts) ->
  let (a1, a2) = account_pair accounts in

  Context.Contract.balance (B b) a1 >>=? fun balance_start ->
  Context.Contract.manager (B b) a1 >>=? fun m1 ->
  Context.Contract.manager (B b) a2 >>=? fun m2 ->

  check_activate_staking_balance ~loc:__LOC__ ~deactivated:false b (a1,m1) >>=? fun () ->

  Context.Delegate.info (B b) m1.pkh >>=? fun info ->
  Block.bake_until_cycle ~policy:(By_account m2.pkh) info.grace_period b >>=? fun b ->

  check_activate_staking_balance ~loc:__LOC__ ~deactivated:false b (a1,m1) >>=? fun () ->

  Block.bake_until_cycle_end ~policy:(By_account m2.pkh) b >>=? fun b ->

  check_activate_staking_balance ~loc:__LOC__ ~deactivated:true b (a1,m1) >>=? fun () ->
  return (b, ((a1, m1), balance_start), (a2, m2))

let deactivation_then_bake () =
  run_until_deactivation () >>=?
  fun (b, ((deactivated_contract, deactivated_account) as deactivated, _start_balance),
       (a2, m2)) ->

  Block.bake ~policy:(By_account deactivated_account.pkh) b >>=? fun b ->

  check_activate_staking_balance ~loc:__LOC__ ~deactivated:false b deactivated >>=? fun () ->
  check_rolls b deactivated_account

let deactivation_then_self_delegation () =
  run_until_deactivation () >>=?
  fun (b, ((deactivated_contract, deactivated_account) as deactivated, start_balance),
       (a2, m2)) ->

  Op.delegation (B b) deactivated_contract (Some deactivated_account.pkh) >>=? fun self_delegation ->

  Block.bake ~policy:(By_account m2.pkh) b ~operation:self_delegation >>=? fun b ->

  check_activate_staking_balance ~loc:__LOC__ ~deactivated:false b deactivated >>=? fun () ->
  Context.Contract.balance (B b) deactivated_contract >>=? fun balance ->
  Assert.equal_tez ~loc:__LOC__ start_balance balance >>=? fun () ->
  check_rolls b deactivated_account


let delegation () =
  Context.init 2 >>=? fun (b,accounts) ->
  let (a1, a2) = account_pair accounts in
  let m3 = Account.new_account () in
  Account.add_account m3;

  Context.Contract.balance (B b) a1 >>=? fun balance ->
  Context.Contract.manager (B b) a1 >>=? fun m1 ->
  Context.Contract.manager (B b) a2 >>=? fun m2 ->
  let a3 = Contract.implicit_contract m3.pkh in

  Context.Contract.delegate_opt (B b) a1 >>=? fun delegate ->
  begin
    match delegate with
    | None -> assert false
    | Some pkh ->
        assert (Signature.Public_key_hash.equal pkh m1.pkh)
  end;

  Op.transaction (B b) a1 a3 balance >>=? fun transact ->

  Block.bake ~policy:(By_account m2.pkh) b ~operation:transact >>=? fun b ->

  Context.Contract.delegate_opt (B b) a3 >>=? fun delegate ->
  begin
    match delegate with
    | None -> ()
    | Some _ -> assert false
  end;
  check_no_rolls b m3 >>=? fun () ->

  Op.delegation (B b) a3 (Some m3.pkh) >>=? fun delegation ->
  Block.bake ~policy:(By_account m2.pkh) b ~operation:delegation >>=? fun b ->

  Context.Contract.delegate_opt (B b) a3 >>=? fun delegate ->
  begin
    match delegate with
    | None -> assert false
    | Some pkh ->
        assert (Signature.Public_key_hash.equal pkh m3.pkh)
  end;
  check_activate_staking_balance ~loc:__LOC__ ~deactivated:false b (a3,m3) >>=? fun () ->
  check_rolls b m3 >>=? fun () ->
  check_rolls b m1

let tests = [
  Test.tztest "simple staking rights" `Quick (simple_staking_rights) ;
  Test.tztest "simple staking rights after baking" `Quick (simple_staking_rights_after_baking) ;
  Test.tztest "deactivation then bake" `Quick (deactivation_then_bake) ;
  Test.tztest "deactivation then self delegation" `Quick (deactivation_then_self_delegation) ;
  Test.tztest "delegation" `Quick (delegation) ;
]
