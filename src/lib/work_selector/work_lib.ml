open Core_kernel
open Currency

module Make (Inputs : Intf.Inputs_intf) = struct
  module Work_spec = Snark_work_lib.Work.Single.Spec

  let statement_pair = function
    | j, None ->
        (Work_spec.statement j, None)
    | j1, Some j2 ->
        (Work_spec.statement j1, Some (Work_spec.statement j2))

  module Job_status = struct
    type t = Assigned of Time.t

    let is_old (Assigned at_time) ~now ~reassignment_wait =
      let max_age = Time.Span.of_ms (Float.of_int reassignment_wait) in
      let delta = Time.diff now at_time in
      Time.Span.( > ) delta max_age
  end

  module State = struct
    module Seen_key = struct
      module T = struct
        type t =
          Transaction_snark.Statement.t * Transaction_snark.Statement.t option
        [@@deriving compare, sexp, to_yojson]
      end

      include T
      include Comparable.Make (T)
    end

    type t = {jobs_seen: Job_status.t Seen_key.Map.t; reassignment_wait: int}

    let init ~reassignment_wait =
      {jobs_seen= Seen_key.Map.empty; reassignment_wait}

    let remove_old_assignments {jobs_seen; reassignment_wait} ~logger =
      let now = Time.now () in
      Map.filteri jobs_seen ~f:(fun ~key:work ~data:status ->
          if Job_status.is_old status ~now ~reassignment_wait then (
            Logger.info logger ~module_:__MODULE__ ~location:__LOC__
              ~metadata:[("work", Seen_key.to_yojson work)]
              "Waited too long to get work for $work. Ready to be reassigned" ;
            Coda_metrics.(Counter.inc_one Snark_work.snark_work_timed_out_rpc) ;
            false )
          else true )

    let set t x =
      { t with
        jobs_seen=
          Map.set t.jobs_seen ~key:(statement_pair x)
            ~data:(Job_status.Assigned (Time.now ())) }
  end

  let pair_to_list = function j, Some j' -> [j; j'] | j, None -> [j]

  let does_not_have_better_fee ~snark_pool ~fee (statement1, maybe_statement_2)
      =
    let statements = pair_to_list (statement1, maybe_statement_2) in
    Option.value_map ~default:true
      (Inputs.Snark_pool.get_completed_work snark_pool statements)
      ~f:(fun priced_proof ->
        let competing_fee = Inputs.Transaction_snark_work.fee priced_proof in
        Fee.compare fee competing_fee < 0 )

  module For_tests = struct
    let to_pair = function
      | [x] ->
          (x, None)
      | [x1; x2] ->
          (x1, Some x2)
      | _ ->
          failwith "Should contain one or two elements"

    type statement = Transaction_snark.Statement.t

    let does_not_have_better_fee ~snark_pool ~fee works =
      does_not_have_better_fee ~snark_pool ~fee
        (statement_pair (to_pair works))
  end

  let get_expensive_work ~snark_pool ~fee jobs =
    List.filter jobs
      ~f:
        (Fn.compose (does_not_have_better_fee ~snark_pool ~fee) statement_pair)

  let all_works ~logger (staged_ledger : Inputs.Staged_ledger.t)
      (state : State.t) =
    let state = State.remove_old_assignments state ~logger in
    let all_jobs = Inputs.Staged_ledger.all_work_pairs_exn staged_ledger in
    let unseen_jobs =
      List.filter all_jobs ~f:(fun js ->
          not @@ Map.mem state (statement_pair js) )
    in
    unseen_jobs
end
