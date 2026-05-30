(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

val setup : unit -> unit

val push_unanalyzed_callees : Procdesc.t -> unit
(** In work-stealing multicore mode, enumerates all static callees of [proc_desc] and pushes the
    sisters (all but the first unanalyzed callee) onto the current worker's LIFO deque. The first
    callee is handled inline by the normal on-demand analysis. Items pushed this way are eligible
    for stealing after 30 seconds. *)

val make :
     SourceFile.t list
  -> ( TaskSchedulerTypes.target
     , TaskSchedulerTypes.analysis_result
     , WorkerPoolState.worker_id )
     TaskGenerator.t

val with_lock :
  get_actives:(unit -> SpecializedProcname.t list) -> f:(unit -> 'a) -> Procname.t -> 'a
(** Run [f] after having taken a lock on the given [Procname.t] and unlock after. If the lock is
    already held by another worker, throw [RestartSchedulerException.ProcnameAlreadyLocked] so that
    the dependency can be sent to the scheduler process. Finally, account for time spent analysing
    each procedure as useful (finished analysis) or not (an exception was thrown, terminating
    analysis early). *)

val finish : TaskSchedulerTypes.analysis_result option -> 'a -> 'a option
