(**************************************************************************)
(*                                                                        *)
(*    Copyright (c) 2014 - 2018.                                          *)
(*    Dynamic Ledger Solutions, Inc. <contact@tezos.com>                  *)
(*                                                                        *)
(*    All rights reserved. No warranty, explicit or implicit, provided.   *)
(*                                                                        *)
(**************************************************************************)

open Misc

type error +=
  | Unknown of { oldest : Cycle_repr.t ;
                 cycle : Cycle_repr.t ;
                 latest : Cycle_repr.t } (* `Permanent *)

let () =
  register_error_kind
    `Permanent
    ~id:"seed.unknown_seed"
    ~title:"Unknown seed"
    ~description:"The requested seed is not available"
    ~pp:(fun ppf (oldest, cycle, latest) ->
        if Cycle_repr.(cycle < oldest) then
          Format.fprintf ppf
            "The seed for cycle %a has been cleared from the context \
            \ (oldest known seed is for cycle %a)"
            Cycle_repr.pp cycle
            Cycle_repr.pp oldest
        else
          Format.fprintf ppf
            "The seed for cycle %a has not been computed yet \
            \ (latest known seed is for cycle %a)"
            Cycle_repr.pp cycle
            Cycle_repr.pp latest)
    Data_encoding.(obj3
                     (req "oldest" Cycle_repr.encoding)
                     (req "requested" Cycle_repr.encoding)
                     (req "latest" Cycle_repr.encoding))
    (function
      | Unknown { oldest ; cycle ; latest } -> Some (oldest, cycle, latest)
      | _ -> None)
    (fun (oldest, cycle, latest) -> Unknown { oldest ; cycle ; latest })

let compute_for_cycle c ~revealed cycle =
  match Cycle_repr.pred cycle with
  | None -> assert false (* should not happen *)
  | Some previous_cycle ->
      let levels = Level_storage.levels_with_commitments_in_cycle c revealed in
      let combine (c, random_seed, unrevealed) level =
        Storage.Seed.Nonce.get c level >>=? function
        | Revealed nonce ->
            Storage.Seed.Nonce.delete c level >>=? fun c ->
            return (c, Seed_repr.nonce random_seed nonce, unrevealed)
        | Unrevealed u ->
            Storage.Seed.Nonce.delete c level >>=? fun c ->
            return (c, random_seed, u :: unrevealed)
      in
      Storage.Seed.For_cycle.get c previous_cycle >>=? fun seed ->
      fold_left_s combine (c, seed, []) levels >>=? fun (c, seed, unrevealed) ->
      Storage.Seed.For_cycle.init c cycle seed >>=? fun c ->
      return (c, unrevealed)

let for_cycle ctxt cycle =
  let preserved = Constants_storage.preserved_cycles ctxt in
  let current_level = Level_storage.current ctxt in
  let current_cycle = current_level.cycle in
  let latest =
    if Cycle_repr.(current_cycle = root) then
      Cycle_repr.add current_cycle (preserved + 1)
    else
      Cycle_repr.add current_cycle preserved in
  let oldest =
    match Cycle_repr.sub current_cycle preserved with
    | None -> Cycle_repr.root
    | Some oldest -> oldest in
  fail_unless Cycle_repr.(oldest <= cycle && cycle <= latest)
    (Unknown { oldest ; cycle ; latest }) >>=? fun () ->
  Storage.Seed.For_cycle.get ctxt cycle

let clear_cycle c cycle =
  Storage.Seed.For_cycle.delete c cycle

let init ctxt =
  let preserved = Constants_storage.preserved_cycles ctxt in
  List.fold_left2
    (fun ctxt c seed ->
       ctxt >>=? fun ctxt ->
       let cycle = Cycle_repr.of_int32_exn (Int32.of_int c) in
       Storage.Seed.For_cycle.init ctxt cycle seed)
    (return ctxt)
    (0 --> (preserved+1))
    (Seed_repr.initial_seeds (preserved+1))

let cycle_end ctxt last_cycle =
  let preserved = Constants_storage.preserved_cycles ctxt in
  begin
    match Cycle_repr.sub last_cycle preserved with
    | None -> return ctxt
    | Some cleared_cycle ->
        clear_cycle ctxt cleared_cycle
  end >>=? fun ctxt ->
  match Cycle_repr.pred last_cycle with
  | None -> return (ctxt, [])
  | Some revealed ->
      let inited_seed_cycle = Cycle_repr.add last_cycle (preserved+1) in
      compute_for_cycle ctxt ~revealed inited_seed_cycle

