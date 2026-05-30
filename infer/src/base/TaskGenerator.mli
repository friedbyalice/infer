(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)

open! IStd

type 'child_id for_child_info = {child_slot: int; child_id: 'child_id; is_first_update: bool}

(** abstraction for generating jobs *)
type ('work, 'result, 'child_id) t =
  { remaining_tasks: unit -> int
        (** number of tasks remaining to complete -- only used for reporting, so imprecision is not
            a bug *)
  ; is_empty: unit -> bool
        (** when should the main loop of the task manager stop expecting new tasks *)
  ; finished: result:'result option -> 'work -> unit
        (** Process pool calls [finished result:r x] when a worker finishes item [x]. [result] is
            [None] when the item was completed successfully and [Some pname] when it failed because
            it could not lock [pname]. This is only called if [next ()] has previously returned
            [Some x] and [x] was sent to a worker. *)
  ; next: 'child_id for_child_info -> 'work option
        (** [next ()] generates the next work item. If [is_empty ()] is true then [next ()] must
            return [None]. However, it is OK to for [next ()] to return [None] when [is_empty] is
            false. This corresponds to the case where there is more work to be done, but it is not
            schedulable until some already scheduled work is finished. *)
  ; push_work: 'child_id -> 'work -> unit
        (** [push_work child_id x] is called when a worker discovers a new work item [x] during
            analysis (e.g., a callee that needs to be analyzed). The scheduler should add [x] to the
            appropriate queue so that it can be picked up by any worker. *)
  ; steal: 'child_id for_child_info -> 'work option
        (** [steal child_info] is called when [next] returns [None] for an idle worker but the
            scheduler might have work queued on other workers. [steal] should try to take work from
            another worker's queue (FIFO end). Returns [None] if nothing available. *) }

val chain :
  ('work, 'result, 'child_id) t -> ('work, 'result, 'child_id) t -> ('work, 'result, 'child_id) t
(** chain two generators in order *)

val of_list :
  finish:('result option -> 'work -> 'work option) -> 'work list -> ('work, 'result, _) t
(** schedule tasks out of a concrete list *)

val finish_always_none : _ option -> _ -> _ option
