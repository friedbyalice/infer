(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd

(** for the Restart scheduler: raise when a worker tries to analyze a procedure already being
    analyzed by another process *)
exception ProcnameAlreadyLocked of {dependency_filenames: string list}

(** for the work-stealing restart scheduler: raise when the scheduler decides to defer analysis of a
    callee by pushing the caller back to the per-worker queue and the callee as a new work item, so
    that other workers can steal the caller *)
exception WorkStealingReschedule

val is_not_restart_exception : exn -> bool
(** check if the exception passed is one of the exceptions defined above *)
