(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
module L = Logging
open TaskSchedulerTypes
module Node = SpecializedProcname
module NodeSet = SpecializedProcname.Set

let read_procs_to_analyze () =
  Option.value_map ~default:NodeSet.empty Config.procs_to_analyze_index ~f:(fun index ->
      In_channel.read_all index |> Parsexp.Single.parse_string_exn |> NodeSet.t_of_sexp )


type target_with_dependency = {target: TaskSchedulerTypes.target; dependency_filenames: string list}

module FinalizerMap = Stdlib.Hashtbl.Make (struct
  type t = TaskSchedulerTypes.target [@@deriving equal, hash]
end)

(* ── Work-stealing data structures ─────────────────────────────────────── *)

(** A work item with its insertion timestamp, used to enforce the 30-second floor before
    stealing. *)
type timed_work = {target: TaskSchedulerTypes.target; birth: Time_ns.t}

(** Per-worker LIFO deques.  The owner pushes / pops the head (LIFO, depth-first).  Stealing
    takes the tail (FIFO, oldest). *)
let worker_deques : timed_work Concurrent.Deque.t array option ref = ref None

(** Minimum age in seconds before a work item is eligible for stealing. *)
let steal_age_floor = Time_ns.Span.of_int_sec 30

(* ── Helpers ───────────────────────────────────────────────────────────── *)

let child_slot_of_id (worker_id : WorkerPoolState.worker_id) =
  match worker_id with
  | Pid _ ->
      None
  | Domain slot ->
      Some slot

let get_current_worker_slot () =
  match WorkerPoolState.get_in_child () with
  | Some slot when slot >= 0 ->
      Some slot
  | _ ->
      None

(** Find the worker whose tail element is the oldest (and at least [steal_age_floor] old),
    returning [Some (slot, birth)] or [None]. *)
let find_best_victim deques =
  let n = Array.length deques in
  let now = Time_ns.now () in
  let best = ref None in
  for slot = 0 to n - 1 do
    match Concurrent.Deque.peek_front deques.(slot) with
    | Some work ->
        let birth = work.birth in
        if Time_ns.Span.( >= ) (Time_ns.diff now birth) steal_age_floor then (
          match !best with
          | None ->
              best := Some (slot, birth)
          | Some (_, prev_birth) ->
              if Time_ns.( < ) birth prev_birth then best := Some (slot, birth) )
    | None ->
        ()
  done ;
  !best

(* ── Task generator ────────────────────────────────────────────────────── *)

let of_queue ~jobs ready :
    ( TaskSchedulerTypes.target
    , TaskSchedulerTypes.analysis_result
    , WorkerPoolState.worker_id )
    TaskGenerator.t =
  let remaining = ref (Queue.length ready) in
  let remaining_tasks () = !remaining in
  let is_empty () = Int.equal !remaining 0 in
  let blocked = Queue.create () in
  let waiting_for_blocked_target = ref false in
  let finalizers = FinalizerMap.create 1 in
  let restart_count = ref 0 in
  let finished ~result target =
    FinalizerMap.find_opt finalizers target |> Option.iter ~f:ProcLocker.unlock_all ;
    FinalizerMap.remove finalizers target ;
    match result with
    | None | Some Ok ->
        decr remaining ;
        if is_empty () then (
          StatsLogging.log_count ~label:"analysis_restarts" ~value:!restart_count ;
          L.debug Analysis Quiet "restart count: %d@\n" !restart_count )
    | Some (RaceOn {dependency_filenames}) ->
        incr restart_count ;
        Queue.enqueue blocked {target; dependency_filenames}
    | Some (Reschedule _) ->
        Queue.enqueue ready target ;
        incr remaining
  in
  let dequeue_from_blocked worker_id =
    match Queue.peek blocked with
    | Some w when not !waiting_for_blocked_target ->
        let {target= bt; dependency_filenames} = w in
        ( match ProcLocker.lock_all worker_id dependency_filenames with
        | `LocksAcquired locks ->
            Queue.dequeue_exn blocked |> ignore ;
            FinalizerMap.add finalizers bt locks ;
            Some bt
        | `FailedToLockAll ->
            waiting_for_blocked_target := true ;
            None )
    | _ ->
        None
  in
  let next {TaskGenerator.child_id; child_slot; is_first_update} =
    if is_first_update then waiting_for_blocked_target := false ;
    (* 1. Own deque (LIFO) *)
    ( match !worker_deques with
    | Some deques when child_slot >= 0 && child_slot < Array.length deques -> (
      match Concurrent.Deque.pop deques.(child_slot) with
      | Some {target= t} ->
          Some t
      | None ->
          None )
    | _ ->
        None )
    |> fun own ->
    match own with
    | Some _ ->
        own
    | None -> (
      (* 2. Central ready queue *)
      match Queue.dequeue ready with
      | Some _ as res ->
          res
      | None -> (
        (* 3. Blocked queue *)
        match dequeue_from_blocked child_id with
        | Some _ as res ->
            res
        | None -> (
          (* 4. Steal from another worker (age-checked, oldest tail first) *)
          match !worker_deques with
          | Some deques -> (
            match find_best_victim deques with
            | Some (victim_slot, _birth) ->
                ( match Concurrent.Deque.steal deques.(victim_slot) with
                | Some {target= t} ->
                    Some t
                | None ->
                    None )
            | None ->
                None )
          | None ->
              None ) ) )
  in
  let push_work child_id work_item =
    let slot = child_slot_of_id child_id in
    let timed = {birth= Time_ns.now (); target= work_item} in
    ( match (!worker_deques, slot) with
    | Some deques, Some s when s >= 0 && s < Array.length deques ->
        Concurrent.Deque.push timed deques.(s)
    | _ ->
        Queue.enqueue ready work_item ) ;
    incr remaining
  in
  let steal _for_child_info = None in
  (* Allocate per-worker deques for work-stealing *)
  if jobs > 0 then
    worker_deques := Some (Array.init jobs ~f:(fun _ -> Concurrent.Deque.create ())) ;
  {remaining_tasks; is_empty; finished; next; push_work; steal}


let make sources =
  let target_count = ref 0 in
  let cons_procname_work acc ~specialization proc_name =
    incr target_count ;
    Procname {proc_name; specialization} :: acc
  in
  let procs_to_analyze_targets =
    NodeSet.fold
      (fun {Node.proc_name; specialization} acc -> cons_procname_work acc ~specialization proc_name)
      (read_procs_to_analyze ()) []
  in
  let pname_targets =
    List.fold sources ~init:procs_to_analyze_targets ~f:(fun init source ->
        SourceFiles.proc_names_of_source source
        |> List.fold ~init ~f:(cons_procname_work ~specialization:None) )
  in
  let make_file_work file =
    incr target_count ;
    TaskSchedulerTypes.File file
  in
  let file_targets = List.rev_map sources ~f:make_file_work in
  let queue = Queue.create ~capacity:!target_count () in
  let permute_and_enqueue targets =
    List.permute targets ~random_state:(Random.State.make (Array.create ~len:1 0))
    |> List.iter ~f:(fun target -> Queue.enqueue queue target)
  in
  permute_and_enqueue pname_targets ;
  permute_and_enqueue file_targets ;
  of_queue ~jobs:Config.jobs queue


let setup () = match Config.scheduler with Restart -> ProcLocker.setup () | _ -> ()

type locked_proc = {start: ExecutionDuration.counter; mutable callees_useful: ExecutionDuration.t}

let locked_procs = DLS.new_key Stack.create

let unlock ~after_exn pname =
  match Stack.pop @@ DLS.get locked_procs with
  | None ->
      L.internal_error "Trying to unlock %a but it does not appear to be locked.@\n" Procname.pp
        pname
  | Some {start; callees_useful} ->
      ( match Stack.top @@ DLS.get locked_procs with
      | Some caller ->
          caller.callees_useful <-
            ( if after_exn then ExecutionDuration.add caller.callees_useful callees_useful
              else ExecutionDuration.add_duration_since caller.callees_useful start )
      | None ->
          Stats.add_to_restart_scheduler_useful_time
            (if after_exn then callees_useful else ExecutionDuration.since start) ;
          Stats.add_to_restart_scheduler_total_time (ExecutionDuration.since start) ) ;
      ProcLocker.unlock pname


let with_lock ~get_actives ~f pname =
  match Config.scheduler with
  | Restart -> (
    match ProcLocker.try_lock pname with
    | `AlreadyLockedByUs ->
        f ()
    | `LockAcquired ->
        Stack.push (DLS.get locked_procs)
          {start= ExecutionDuration.counter (); callees_useful= ExecutionDuration.zero} ;
        let res =
          try f ()
          with exn ->
            IExn.reraise_after ~f:(fun () -> unlock ~after_exn:true pname) exn
        in
        unlock ~after_exn:false pname ;
        res
    | `LockedByAnotherProcess ->
        let dependency_filenames =
          Procname.to_filename pname
          :: ( get_actives ()
             |> List.map ~f:(fun {SpecializedProcname.proc_name} -> Procname.to_filename proc_name)
             )
        in
        raise (RestartSchedulerException.ProcnameAlreadyLocked {dependency_filenames}) )
  | _ ->
      f ()


let finish result task =
  match result with
  | None | Some Ok ->
      None
  | Some (RaceOn _) ->
      Some task
  | Some (Reschedule _) ->
      Some task


(* ── Callee pre-enumeration ────────────────────────────────────────────── *)

let push_unanalyzed_callees proc_desc =
  if Config.work_stealing && Config.multicore then
    let callees = Procdesc.get_static_callees proc_desc in
    let unanalyzed =
      List.filter_map callees ~f:(fun callee ->
          if Summary.OnDisk.get ~lazy_payloads:true AnalysisRequest.all callee |> Option.is_none
          then Some callee
          else None )
    in
    match (!worker_deques, get_current_worker_slot ()) with
    | Some deques, Some slot -> (
      match unanalyzed with
      | _first :: sisters ->
          let now = Time_ns.now () in
          List.iter sisters ~f:(fun callee ->
              let target = Procname {proc_name= callee; specialization= None} in
              Concurrent.Deque.push {birth= now; target} deques.(slot) )
      | [] ->
          () )
    | _ ->
        ()
